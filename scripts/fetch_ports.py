#!/usr/bin/env python3
"""
Builds assets/ports.tsv from two sources:

Primary — NGA World Port Index (WPI, Publication 150)
  Free US government publication covering ~4,000 commercial ports worldwide.
  Contains harbour size, VHF working channel, radio call sign, and many
  facility fields.  https://msi.nga.mil/Publications/WPI

Supplementary — GeoNames web service (https://secure.geonames.org)
  Covers smaller harbours, marinas, landings and anchorages not in the WPI.
  Requires a free GeoNames account with free web services enabled:
    1. Register:  https://www.geonames.org/login
    2. Enable:    https://www.geonames.org/manageaccount
       (tick "Free Web Services" and save)
    3. Run:  python scripts/fetch_ports.py --user YOUR_USERNAME

TSV columns (11):
  name, country, lat, lon, type, size, vhf, phone, call_sign, wpi_index, facilities

Usage:
  python scripts/fetch_ports.py [--user USERNAME] [--wpi-file WPI.zip] [--no-wpi] [--no-geonames]

Optional third source — OpenStreetMap via Overpass API
  Fills in inland marinas (lakes, rivers, canals) not covered by WPI or
  GeoNames, e.g. Poland's Mazury lake district or the Rhine/Elbe/Vistula
  river systems.  OSM marina nodes often include the actual VHF working
  channel via the "communication:vhf" tag.
  No registration required.
  Usage:  --countries PL,DE,FI,SE,NL,HU   (comma-separated ISO codes)
  "ALL" queries every country (slow, ~several hours):
          --countries ALL
"""
import argparse, csv, io, json, re, sys, time, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path


# ── Progress helper (shared by GeoNames and OSM loops) ───────────────────────

def _fmt_dur(s: float) -> str:
    if s < 60:   return f"{int(s)}s"
    if s < 3600: return f"{s / 60:.1f}m"
    return f"{s / 3600:.1f}h"


class _Progress:
    """Single-line progress bar with elapsed time and ETA written to stderr."""

    def __init__(self, total: int) -> None:
        self.total = total
        self.done  = 0
        self.start = time.monotonic()

    def update(self, n: int = 1, detail: str = "") -> None:
        self.done += n
        elapsed = time.monotonic() - self.start
        pct  = self.done / self.total * 100 if self.total else 0
        rate = self.done / elapsed if elapsed > 0.05 else 0
        eta  = (self.total - self.done) / rate if rate > 0 else 0
        det  = f"  {detail}" if detail else ""
        sys.stderr.write(
            f"\r  [{self.done}/{self.total}] {pct:5.1f}%  "
            f"elapsed {_fmt_dur(elapsed)}  ETA {_fmt_dur(eta)}{det}          "
        )
        sys.stderr.flush()

    def finish(self, msg: str = "") -> None:
        elapsed = time.monotonic() - self.start
        sys.stderr.write(
            f"\r  Done {self.done}/{self.total} in {_fmt_dur(elapsed)}.{' ' + msg if msg else ''}\n"
        )
        sys.stderr.flush()

OUT = Path(__file__).parent.parent / "assets" / "ports.tsv"

# ── HTTP helpers ──────────────────────────────────────────────────────────────

# NGA blocks the default Python-urllib user-agent with 403.
# A standard browser User-Agent string resolves this.
_BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "application/zip, application/octet-stream, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://msi.nga.mil/Publications/WPI",
}

def _get(url: str, *, headers: dict | None = None, timeout: int = 60) -> bytes | None:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} {e.reason}  ({url})", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  Error fetching {url}: {e}", file=sys.stderr)
        return None


# ── WPI ───────────────────────────────────────────────────────────────────────

# NGA WPI download URLs to try in order.  The key encodes a publication-ID
# (e.g. 16694312) that can change between WPI editions.  The script also
# queries the NGA publications API to discover the latest key automatically.
# If all attempts fail, download the ZIP manually from
#   https://msi.nga.mil/Publications/WPI
# and pass it with:  --wpi-file /path/to/WPI.zip
_WPI_URL_TEMPLATES = [
    "https://msi.nga.mil/api/publications/download?type=view&key={key}",
]
_WPI_KNOWN_KEYS = [
    "16694312/SFH00000/WPI.zip",  # WPI 2024 / recent editions
]
_NGA_PUBS_API = "https://msi.nga.mil/api/publications"

# Column candidates: each tuple lists all known spellings across WPI editions.
# The current "Complete Volume" CSV (UpdatedPub150.csv) uses verbose names like
# "Main Port Name", "Communications - VHF"; older/zipped editions used short
# names like "PORT_NAME", "COMM_VHF".  Both are normalised by _col().
# NOTE: the current WPI CSV (UpdatedPub150.csv) stores communications fields
# as Yes/No/Unknown flags only — actual VHF channels, phone numbers, and call
# signs are NOT present.  The columns below will therefore be empty for all
# WPI entries.  GeoNames supplement entries also lack this data.
# If you have a supplementary data source with actual channel/contact data,
# add it to ports.tsv manually or extend fetch_ports.py.
_VHF_COLS          = ("comm_vhf", "communications_vhf")      # not in current WPI CSV
_PHONE_COLS        = ("comm_phone", "comm_radio_tel")          # not in current WPI CSV
_CALLSIGN_COLS     = ("radio_call_sign", "call_sign")          # not in current WPI CSV
_SIZE_COLS         = ("harbor_size",)
_LAT_COLS          = ("latitude_dec", "latitude")
_LON_COLS          = ("longitude_dec", "longitude")
_NAME_COLS         = ("port_name", "main_port_name")
_COUNTRY_COLS      = ("country_code", "country")
_INDEX_COLS        = ("world_port_number", "world_port_index_number", "index_no")

# Navigation detail columns (new extended fields)
_HARBOR_TYPE_COLS     = ("harbor_type",)
_HARBOR_USE_COLS      = ("harbor_use",)
_SHELTER_COLS         = ("shelter_afforded", "shelter")
_TIDAL_RANGE_COLS     = ("tidal_range_m",)
_CHANNEL_DEPTH_COLS   = ("channel_depth_m",)
_MAX_VESSEL_LEN_COLS  = ("maximum_vessel_length_m",)
_CHART_COLS           = ("standard_nautical_chart",)
_NAVAREA_COLS         = ("navarea",)
_PUBLICATION_COLS     = ("sailing_direction_or_publication", "sailing_directions")
_PUB_LINK_COLS        = ("publication_link",)
_PILOT_COMPULSORY_COLS = ("pilotage_compulsory",)
_PILOT_AVAILABLE_COLS  = ("pilotage_available",)
_PILOT_ADVISABLE_COLS  = ("pilotage_advisable",)
_ENTRY_TIDE_COLS      = ("entrance_restriction_tide",)
_ENTRY_SWELL_COLS     = ("entrance_restriction_heavy_swell",)
_ENTRY_ICE_COLS       = ("entrance_restriction_ice",)
_ENTRY_OTHER_COLS     = ("entrance_restriction_other",)
_FIRST_PORT_COLS      = ("first_port_of_entry",)

# tag -> tuple of candidate column names (any edition spelling)
_FACILITY_COLS: dict[str, tuple] = {
    # Supplies
    "FUEL_OIL":   ("supplies_fuel_oil",    "fuel_oil"),
    "DIESEL":     ("supplies_diesel_oil",  "fuel_diesel",  "diesel"),
    "WATER":      ("supplies_potable_water", "water"),
    "PROVISIONS": ("supplies_provisions",  "provisions"),
    # Services
    "MEDICAL":    ("medical_facilities",),
    "DRY_DOCK":   ("dry_dock",),
    "MARINE_RLY": ("railway",              "marine_railway"),
    "TUGS":       ("tugs_assistance",      "tugs_assist"),
    "DEGAS":      ("degaussing",),
    # Communications availability (Yes/No flags — no actual channel/number data in WPI CSV)
    "VTS":        ("vessel_traffic_service",),
    "RADIO":      ("communications_radio",),
    "RADIOTELEPHONE": ("communications_radiotelephone",),
    "TEL":        ("communications_telephone",),
}


def _norm(s: str) -> str:
    """Normalise a column header to a lowercase_underscore slug."""
    return re.sub(r'[^a-z0-9]+', '_', s.lower()).strip('_')


def _col(header: list[str], candidates: tuple) -> int:
    """Return the index of the first matching candidate column, or -1."""
    h = [_norm(c) for c in header]
    for name in candidates:
        n = _norm(name)
        if n in h:
            return h.index(n)
    return -1


def _clean_vhf(raw: str) -> str:
    """Normalise WPI VHF field -> semicolon-separated channel numbers."""
    if not raw:
        return ""
    channels = re.findall(r'\b(\d{1,2})\b', raw)
    channels = [c for c in channels if 1 <= int(c) <= 88]
    return ";".join(dict.fromkeys(channels))



def _parse_wpi_csv_reader(header: list[str], reader) -> list[dict]:
    h_norm = [_norm(c) for c in header]

    ci = {k: _col(header, v) for k, v in {
        "name":         _NAME_COLS,
        "country":      _COUNTRY_COLS,
        "lat":          _LAT_COLS,
        "lon":          _LON_COLS,
        "size":         _SIZE_COLS,
        "vhf":          _VHF_COLS,
        "phone":        _PHONE_COLS,
        "sign":         _CALLSIGN_COLS,
        "index":        _INDEX_COLS,
        # Navigation detail fields
        "harbor_type":  _HARBOR_TYPE_COLS,
        "harbor_use":   _HARBOR_USE_COLS,
        "shelter":      _SHELTER_COLS,
        "tidal":        _TIDAL_RANGE_COLS,
        "ch_depth":     _CHANNEL_DEPTH_COLS,
        "max_len":      _MAX_VESSEL_LEN_COLS,
        "chart":        _CHART_COLS,
        "navarea":      _NAVAREA_COLS,
        "publication":  _PUBLICATION_COLS,
        "pub_link":     _PUB_LINK_COLS,
        "pilot_comp":   _PILOT_COMPULSORY_COLS,
        "pilot_avail":  _PILOT_AVAILABLE_COLS,
        "pilot_advis":  _PILOT_ADVISABLE_COLS,
        "entry_tide":   _ENTRY_TIDE_COLS,
        "entry_swell":  _ENTRY_SWELL_COLS,
        "entry_ice":    _ENTRY_ICE_COLS,
        "entry_other":  _ENTRY_OTHER_COLS,
        "first_port":   _FIRST_PORT_COLS,
    }.items()}

    # Columns that must exist for basic parsing to work.
    _REQUIRED = {"name", "lat", "lon", "country"}
    # Columns absent in the current WPI CSV (known limitation, not an error).
    _KNOWN_ABSENT = {"vhf", "phone", "sign"}

    found   = {k: v for k, v in ci.items() if v >= 0}
    missing = [k for k, v in ci.items() if v < 0]

    print(f"  Columns matched: {', '.join(sorted(found))}.")

    critical_missing = [k for k in missing if k in _REQUIRED]
    optional_missing = [k for k in missing if k not in _REQUIRED]

    if optional_missing:
        known   = [k for k in optional_missing if k in _KNOWN_ABSENT]
        unknown = [k for k in optional_missing if k not in _KNOWN_ABSENT]
        if known:
            print(f"  Note: {', '.join(known)} not present in this WPI CSV edition "
                  f"(data not available from this source).")
        if unknown:
            print(f"  WARNING — unexpected missing columns: {', '.join(unknown)}.",
                  file=sys.stderr)

    if critical_missing:
        print(f"  ERROR — required columns missing: {', '.join(critical_missing)}. "
              "Full header dump follows.", file=sys.stderr)
        for i, col in enumerate(header):
            print(f"    [{i:3d}] {col!r}  (normalised: {h_norm[i]!r})", file=sys.stderr)

    fac_cols = {tag: _col(header, cands) for tag, cands in _FACILITY_COLS.items()}

    rows = []
    for row in reader:
        def g(key: str) -> str:
            idx = ci.get(key, -1)
            return row[idx].strip() if 0 <= idx < len(row) else ""

        name = g("name")
        if not name:
            continue
        try:
            lat, lon = float(g("lat")), float(g("lon"))
        except ValueError:
            continue

        facilities = [
            tag for tag, idx in fac_cols.items()
            if idx >= 0 and idx < len(row)
            and row[idx].strip().upper() in ("Y", "YES", "1")
        ]

        # Pilotage — combine flags into a readable string
        pilotage_parts = []
        if g("pilot_comp").upper() in ("Y", "YES"): pilotage_parts.append("Compulsory")
        if g("pilot_avail").upper() in ("Y", "YES"): pilotage_parts.append("Available")
        if g("pilot_advis").upper() in ("Y", "YES"): pilotage_parts.append("Advisable")
        pilotage_str = ", ".join(pilotage_parts)

        # Entry restrictions — only keep ones that apply
        restrictions = []
        if g("entry_tide").upper()  in ("Y", "YES"): restrictions.append("Tide")
        if g("entry_swell").upper() in ("Y", "YES"): restrictions.append("Heavy Swell")
        if g("entry_ice").upper()   in ("Y", "YES"): restrictions.append("Ice")
        if g("entry_other").upper() in ("Y", "YES"): restrictions.append("Other")
        restrictions_str = ", ".join(restrictions)

        def gf(key: str) -> str:
            """Get float field as formatted string (empty if zero / unparseable)."""
            val = g(key)
            try:
                f = float(val)
                return "" if f == 0.0 else val
            except ValueError:
                return ""

        rows.append({
            "name":               name,
            "country":            (g("country") + "  ")[:2].upper().strip(),
            "lat":                lat,
            "lon":                lon,
            "type":               "PRT",
            "size":               g("size").upper(),
            "vhf":                _clean_vhf(g("vhf")),
            "phone":              g("phone"),
            "call_sign":          g("sign"),
            "wpi_index":          g("index"),
            "facilities":         "|".join(facilities),
            # Navigation detail fields (new cols 11-23)
            "harbor_type":        g("harbor_type"),
            "harbor_use":         g("harbor_use"),
            "shelter":            g("shelter").upper()[:1],  # E/G/F/P
            "tidal_range_m":      gf("tidal"),
            "channel_depth_m":    gf("ch_depth"),
            "max_vessel_length_m": gf("max_len"),
            "chart":              g("chart"),
            "navarea":            g("navarea"),
            "publication":        g("publication"),
            "publication_link":   g("pub_link"),
            "pilotage":           pilotage_str,
            "entry_restrictions": restrictions_str,
            "first_port_entry":   g("first_port").upper()[:1],  # Y/N
        })
    return rows


def _parse_wpi_file(data: bytes) -> list[dict]:
    """Parse WPI data — auto-detects ZIP vs plain CSV by magic bytes."""
    if data[:2] == b'PK':
        # ZIP archive — find the CSV inside
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            csv_name = next((n for n in zf.namelist() if n.lower().endswith(".csv")), None)
            if not csv_name:
                print("  No CSV found in WPI archive.  Files:", file=sys.stderr)
                for n in zf.namelist():
                    print(f"    {n}", file=sys.stderr)
                return []
            print(f"  Reading {csv_name} from ZIP…")
            with zf.open(csv_name) as f:
                wrapper = io.TextIOWrapper(f, encoding="utf-8-sig", errors="replace")
                reader = csv.reader(wrapper)
                header = next(reader)
                return _parse_wpi_csv_reader(header, reader)
    else:
        # Plain CSV (e.g. UpdatedPub150.csv downloaded directly from the NGA page)
        text = data.decode("utf-8-sig", errors="replace")
        reader = csv.reader(text.splitlines())
        header = next(reader)
        return _parse_wpi_csv_reader(header, reader)


def _wpi_urls_to_try() -> list[str]:
    """Return a list of WPI download URLs to attempt, newest-key first."""
    urls = [
        t.format(key=k)
        for t in _WPI_URL_TEMPLATES
        for k in _WPI_KNOWN_KEYS
    ]
    # Also try to discover the current key from the NGA publications API.
    raw = _get(_NGA_PUBS_API, headers=_BROWSER_HEADERS, timeout=15)
    if raw:
        try:
            listing = json.loads(raw)
            items = listing if isinstance(listing, list) else listing.get("publications", [])
            for item in items:
                title = str(item.get("title", "") + item.get("type", "")).upper()
                if "WPI" in title or "WORLD PORT INDEX" in title:
                    for field in ("downloadURL", "url", "fileUrl", "key", "file"):
                        val = item.get(field, "")
                        if val:
                            # If it looks like a key, build a full URL.
                            candidate = (
                                val if val.startswith("http")
                                else _WPI_URL_TEMPLATES[0].format(key=val)
                            )
                            if candidate not in urls:
                                urls.insert(0, candidate)  # prefer discovered URL
                    break
        except Exception:
            pass
    return urls


def fetch_wpi(override_file: str | None = None) -> list[dict]:
    if override_file:
        print(f"Loading WPI from local file: {override_file}")
        data = Path(override_file).read_bytes()
    else:
        print("Downloading WPI from NGA (~3 MB)…")
        data = None
        for url in _wpi_urls_to_try():
            data = _get(url, headers=_BROWSER_HEADERS)
            if data:
                break
        if data is None:
            print(
                "\n  WPI automatic download failed (NGA requires a browser session).\n"
                "\n  Manual steps:\n"
                "  1. Open https://msi.nga.mil/Publications/WPI in a web browser\n"
                "  2. Under 'Download Publication' -> click  Complete Volume\n"
                "     This downloads a file called  UpdatedPub150.csv  (~3 800 rows).\n"
                "     Do NOT download the PDF, Access database, or Shapefile options —\n"
                "     those are archived 2019 editions and will not parse.\n"
                "  3. Save UpdatedPub150.csv somewhere on your computer\n"
                "  4. Re-run:\n"
                "       python scripts\\fetch_ports.py --wpi-file \"C:\\path\\to\\UpdatedPub150.csv\"\n"
                "\n  The script will continue with GeoNames-only data for now.\n",
                file=sys.stderr,
            )
            return []

    rows = _parse_wpi_file(data)
    vhf_count = sum(1 for r in rows if r["vhf"])
    print(f"  {len(rows)} WPI ports loaded ({vhf_count} with VHF data).")
    return rows


# ── GeoNames supplement ───────────────────────────────────────────────────────

GEONAMES_API   = "https://secure.geonames.org/searchJSON"
GEONAMES_CODES = ["HBR", "MRNA", "LDNG", "ANCH"]  # PRT covered by WPI

# All ISO 3166-1 alpha-2 country codes.  Querying per country instead of
# globally solves two problems at once:
#   1. The free service's startRow cap (5 000) is never hit — even the most
#      harbour-dense nations have far fewer than 5 000 entries per code.
#   2. GeoNames' global MRNA search returns 0 results (a known quirk), but
#      per-country queries work correctly and find inland marinas like those
#      on Poland's Mazury lakes or Germany's Rhine/Elbe.
_ALL_COUNTRIES = [
    "AD","AE","AF","AG","AI","AL","AM","AO","AQ","AR","AS","AT","AU","AW","AX",
    "AZ","BA","BB","BD","BE","BF","BG","BH","BI","BJ","BL","BM","BN","BO","BQ",
    "BR","BS","BT","BW","BY","BZ","CA","CC","CD","CF","CG","CH","CI","CK","CL",
    "CM","CN","CO","CR","CU","CV","CW","CX","CY","CZ","DE","DJ","DK","DM","DO",
    "DZ","EC","EE","EG","EH","ER","ES","ET","FI","FJ","FK","FM","FO","FR","GA",
    "GB","GD","GE","GF","GG","GH","GI","GL","GM","GN","GP","GQ","GR","GT","GU",
    "GW","GY","HK","HN","HR","HT","HU","ID","IE","IL","IM","IN","IO","IQ","IR",
    "IS","IT","JE","JM","JO","JP","KE","KG","KH","KI","KM","KN","KP","KR","KW",
    "KY","KZ","LA","LB","LC","LI","LK","LR","LS","LT","LU","LV","LY","MA","MC",
    "MD","ME","MF","MG","MH","MK","ML","MM","MN","MO","MP","MQ","MR","MS","MT",
    "MU","MV","MW","MX","MY","MZ","NA","NC","NE","NF","NG","NI","NL","NO","NP",
    "NR","NU","NZ","OM","PA","PE","PF","PG","PH","PK","PL","PM","PN","PR","PS",
    "PT","PW","PY","QA","RE","RO","RS","RU","RW","SA","SB","SC","SD","SE","SG",
    "SH","SI","SK","SL","SM","SN","SO","SR","SS","ST","SV","SX","SY","SZ","TC",
    "TD","TG","TH","TJ","TK","TL","TM","TN","TO","TR","TT","TV","TW","TZ","UA",
    "UG","US","UY","UZ","VA","VC","VE","VG","VI","VN","VU","WF","WS","YE","YT",
    "ZA","ZM","ZW",
]

# Cache file — stores per (feature_code, country) results so an interrupted
# run can resume without re-querying already-fetched country/code pairs.
# Persistent cache — accumulates all fetched data across runs.
# Keys: "HBR:PL", "OSM:DE", etc.  Never auto-deleted; grows as you fetch more.
# Delete with --clean-cache or by removing the file manually.
_CACHE_FILE = Path(__file__).parent / ".ports_cache.json"


def _cache_load() -> dict:
    if _CACHE_FILE.exists():
        try:
            cache = json.loads(_CACHE_FILE.read_text(encoding="utf-8"))
            gn_done  = sum(1 for k, v in cache.items()
                           if ":" in k and not k.startswith("OSM:") and v.get("done"))
            osm_done = sum(1 for k, v in cache.items()
                           if k.startswith("OSM:") and v.get("done"))
            parts = []
            if gn_done:  parts.append(f"{gn_done} GeoNames pairs")
            if osm_done: parts.append(f"{osm_done} OSM countries")
            if parts:
                print(f"  Cache loaded: {', '.join(parts)} already fetched.")
            return cache
        except Exception:
            pass
    return {}


def _cache_save(cache: dict) -> None:
    _CACHE_FILE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


def _cache_clear() -> None:
    if _CACHE_FILE.exists():
        _CACHE_FILE.unlink()
        print("  Cache cleared.")


def collect_from_cache(cache: dict) -> list[dict]:
    """Return all completed rows from every source stored in the cache."""
    rows = []
    for val in cache.values():
        if val.get("done"):
            for r in val.get("rows", []):
                r_copy = dict(r)
                r_copy.pop("_gid", None)  # strip internal dedup key
                rows.append(r_copy)
    return rows


def _geonames_error(status: dict, context: str, user: str) -> bool:
    """Returns True if the error is fatal (abort all remaining queries)."""
    err_code = status.get("value")
    msg      = status.get("message", "")
    if err_code == 10:
        print(
            f"\n  GeoNames authentication failed for user '{user}'.\n"
            "  Most likely cause: free web services not yet enabled.\n"
            "  -> Go to https://www.geonames.org/manageaccount\n"
            "     tick 'Free Web Services' and click Save\n",
            file=sys.stderr,
        )
        return True
    elif err_code == 18:
        print(
            "\n  GeoNames daily quota exceeded.\n"
            "  Re-run tomorrow; cached progress will be reused automatically.\n"
            "  For higher limits: https://www.geonames.org/commercial-webservices.html\n",
            file=sys.stderr,
        )
        return True
    elif err_code == 19:
        print(f"\n  GeoNames blocked this IP: {msg}\n", file=sys.stderr)
        return True
    elif err_code == 25:
        # Per-country queries rarely hit this, but handle gracefully if they do.
        print(f"    Pagination cap for {context}; skipping remainder.")
        return False
    else:
        print(f"    GeoNames error {err_code} ({context}): {msg}", file=sys.stderr)
        return False


def _fetch_country_code(feat_code: str, country: str,
                        user: str, seen: set) -> tuple[list[dict], bool]:
    """
    Fetch all GeoNames entries for one (feat_code, country) pair.
    Returns (rows, fatal_error).
    """
    rows: list[dict] = []
    start = 0

    while True:
        url = (
            f"{GEONAMES_API}"
            f"?featureCode={feat_code}&country={country}"
            f"&maxRows=1000&startRow={start}"
            f"&username={user}&style=SHORT"
        )
        raw = _get(url, timeout=30)
        if raw is None:
            return rows, False  # HTTP error; not fatal, just skip this country

        data = json.loads(raw)
        if "status" in data:
            fatal = _geonames_error(data["status"], f"{feat_code}/{country}", user)
            return rows, fatal

        hits = data.get("geonames", [])
        if not hits:
            break

        for h in hits:
            gid = h.get("geonameId")
            if gid and gid not in seen:
                seen.add(gid)
                name = (h.get("asciiName") or h.get("name", "")).strip()
                if name:
                    rows.append({
                        "_gid":       gid,
                        "name":       name,
                        "country":    h.get("countryCode", country).strip(),
                        "lat":        float(h.get("lat", 0)),
                        "lon":        float(h.get("lng", 0)),
                        "type":       feat_code,
                        "size":       "",
                        "vhf":        "",
                        "phone":      "",
                        "call_sign":  "",
                        "wpi_index":  "",
                        "facilities": "",
                    })

        start += len(hits)
        if len(hits) < 1000:
            break  # last page
        time.sleep(0.2)

    return rows, False


def fetch_geonames(user: str, cache: dict,
                   countries: list[str] | None = None) -> None:
    """Fetch GeoNames harbour/marina data, updating cache in-place.
    Already-cached (country, code) pairs are skipped — safe to re-run.
    countries: restrict to these ISO codes; defaults to all countries."""
    target = countries if countries else _ALL_COUNTRIES
    seen : set[int] = set()

    # Pre-populate seen from existing cache to avoid cross-source duplicates.
    for key, val in cache.items():
        if val.get("done") and not key.startswith("OSM:"):
            for r in val.get("rows", []):
                seen.add(r.get("_gid", 0))

    total_pairs = len(GEONAMES_CODES) * len(target)
    done_pairs  = sum(1 for k, v in cache.items()
                      if ":" in k and not k.startswith("OSM:") and v.get("done")
                      and k.split(":", 1)[1] in target)
    scope_note = f" ({len(target)} countries)" if countries else " (all countries)"
    print(f"  {total_pairs} GeoNames country/code pairs{scope_note}: "
          f"{done_pairs} cached, {total_pairs - done_pairs} to fetch.")

    to_fetch = total_pairs - done_pairs
    prog = _Progress(to_fetch) if to_fetch > 0 else None

    pair_num = 0
    fetched_pairs = 0
    abort = False
    for feat_code in GEONAMES_CODES:
        if abort:
            break
        newly_fetched = 0

        for country in target:
            if abort:
                break

            pair_num += 1
            cache_key = f"{feat_code}:{country}"

            if cache.get(cache_key, {}).get("done"):
                continue  # already in cache, skip

            rows, fatal = _fetch_country_code(feat_code, country, user, seen)

            cache[cache_key] = {"done": not fatal, "rows": rows}
            newly_fetched += len(rows)
            fetched_pairs += 1

            if prog:
                prog.update(detail=f"{feat_code}:{country} +{len(rows)}")

            if fetched_pairs % 20 == 0:
                _cache_save(cache)  # flush periodically to limit Ctrl-C data loss

            if fatal:
                abort = True
                break

            if rows:
                time.sleep(0.3)  # only delay when data was returned

        _cache_save(cache)
        if newly_fetched:
            sys.stderr.write(f"\r  {feat_code}: {newly_fetched} new entries.          \n")
            sys.stderr.flush()

    if prog:
        prog.finish()


# ── OpenStreetMap supplement via Overpass API ─────────────────────────────────
#
# Covers inland marinas (lakes, rivers, canals) that WPI and GeoNames miss.
# OSM marina nodes often carry communication:vhf tags — the only free source
# that actually provides VHF working channels for small ports.
# No registration or API key required.

OVERPASS_API = "https://overpass-api.de/api/interpreter"

_OSM_CACHE_PREFIX = "OSM"


def _overpass_query(country_iso: str) -> str:
    """Overpass QL query: marinas + harbours in one country, with all tags."""
    return (
        f'[out:json][timeout:180];'
        f'area["ISO3166-1"="{country_iso}"]->.a;'
        f'('
        f'  node["leisure"="marina"](area.a);'
        f'  node["seamark:type"="harbour"](area.a);'
        f'  node["harbour"]["harbour"!="no"]["harbour"!="ferry"](area.a);'
        f'  way["leisure"="marina"](area.a);'
        f'  way["seamark:type"="harbour"](area.a);'
        f');'
        f'out center tags;'
    )


def _overpass(query: str, *, timeout: int = 180, max_retries: int = 4) -> bytes | None:
    """POST a query to the Overpass API with exponential back-off on 429 / 504.

    Overpass public instances enforce rate limits (429 Too Many Requests) and
    occasionally time out upstream (504 Gateway Timeout).  These are transient
    and retrying after a delay almost always succeeds.

    Non-transient errors (4xx except 429, 400 Bad Request, etc.) are returned
    immediately as None without retrying.
    """
    data = urllib.parse.urlencode({"data": query}).encode()
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept":       "application/json",
        "User-Agent":   "QTH-Dashboard-fetch-ports/1.0 (recreational navigation app)",
    }

    delay = 15  # initial backoff in seconds; doubles on each retry
    for attempt in range(max_retries + 1):
        req = urllib.request.Request(OVERPASS_API, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()

        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", errors="replace")[:300]
            except Exception:
                pass

            if e.code in (429, 503):
                # Rate-limited.  Respect the Retry-After header if present.
                retry_after = int(e.headers.get("Retry-After", delay))
                wait = max(delay, retry_after)
                if attempt < max_retries:
                    sys.stderr.write(
                        f"\n  Overpass HTTP {e.code} (rate limit). "
                        f"Waiting {wait}s before retry {attempt + 1}/{max_retries}…\n"
                    )
                    sys.stderr.flush()
                    time.sleep(wait)
                    delay = min(delay * 2, 120)
                else:
                    print(f"  Overpass HTTP {e.code}: max retries reached. {body}",
                          file=sys.stderr)
                    return None

            elif e.code in (504, 502, 500):
                # Gateway / server error — transient, worth retrying.
                if attempt < max_retries:
                    sys.stderr.write(
                        f"\n  Overpass HTTP {e.code} (timeout/server error). "
                        f"Waiting {delay}s before retry {attempt + 1}/{max_retries}…\n"
                    )
                    sys.stderr.flush()
                    time.sleep(delay)
                    delay = min(delay * 2, 120)
                else:
                    print(f"  Overpass HTTP {e.code}: max retries reached. {body}",
                          file=sys.stderr)
                    return None

            else:
                # 400 Bad Request, 401, 403, etc. — not transient, don't retry.
                print(f"  Overpass HTTP {e.code} {e.reason}. {body}", file=sys.stderr)
                return None

        except Exception as e:
            # Could be a socket timeout or DNS failure — usually transient.
            if attempt < max_retries:
                sys.stderr.write(
                    f"\n  Overpass error: {e}. "
                    f"Waiting {delay}s before retry {attempt + 1}/{max_retries}…\n"
                )
                sys.stderr.flush()
                time.sleep(delay)
                delay = min(delay * 2, 120)
            else:
                print(f"  Overpass error: {e} (max retries reached).", file=sys.stderr)
                return None

    return None  # unreachable, satisfies type checker


def _osm_vhf(tags: dict) -> str:
    raw = tags.get("communication:vhf", "") or tags.get("seamark:radio:frequency", "")
    return _clean_vhf(raw)


def fetch_osm(countries: list[str], cache: dict) -> None:
    """Query Overpass for marinas/harbours in each listed country.
    Already-cached countries are skipped — safe to re-run."""
    seen: set[tuple] = set()
    to_fetch = [c for c in countries
                if not cache.get(f"{_OSM_CACHE_PREFIX}:{c}", {}).get("done")]
    prog = _Progress(len(to_fetch)) if to_fetch else None
    fetched = 0

    for country in countries:
        cache_key = f"{_OSM_CACHE_PREFIX}:{country}"
        if cache.get(cache_key, {}).get("done"):
            continue

        fetched += 1
        if prog:
            prog.update(0, detail=f"querying {country}…")
        else:
            print(f"  OSM {country}: querying Overpass…")
        raw = _overpass(_overpass_query(country))
        if raw is None:
            continue

        try:
            data = json.loads(raw)
        except Exception as e:
            print(f"  OSM {country}: JSON parse error: {e}", file=sys.stderr)
            continue

        rows: list[dict] = []
        for el in data.get("elements", []):
            tags = el.get("tags", {})

            name = (tags.get("name:en") or tags.get("name") or
                    tags.get("seamark:name") or "").strip()
            if not name:
                continue

            if el["type"] == "node":
                lat, lon = el.get("lat"), el.get("lon")
            elif el["type"] == "way":
                c = el.get("center", {})
                lat, lon = c.get("lat"), c.get("lon")
            else:
                continue

            if lat is None or lon is None:
                continue

            key = (round(float(lat), 4), round(float(lon), 4))
            if key in seen:
                continue
            seen.add(key)

            feat_type = "MRNA" if tags.get("leisure") == "marina" else "HBR"

            rows.append({
                "name":       name,
                "country":    country,
                "lat":        float(lat),
                "lon":        float(lon),
                "type":       feat_type,
                "size":       "",
                "vhf":        _osm_vhf(tags),
                "phone":      (tags.get("phone") or tags.get("contact:phone") or "").strip(),
                "call_sign":  (tags.get("seamark:radio:callsign") or tags.get("callsign") or "").strip(),
                "wpi_index":  "",
                "facilities": "",
            })

        vhf_count = sum(1 for r in rows if r["vhf"])
        if prog:
            prog.update(detail=f"{country}: {len(rows)} entries")
        else:
            print(f"  OSM {country}: {len(rows)} entries ({vhf_count} with VHF).")

        cache[cache_key] = {"done": True, "rows": rows}
        _cache_save(cache)
        time.sleep(2.0)  # be polite; the retries in _overpass handle the rare 429

    if prog:
        total_rows = sum(len(v["rows"]) for k, v in cache.items()
                         if k.startswith(_OSM_CACHE_PREFIX + ":") and v.get("done"))
        prog.finish(f"{total_rows} total OSM entries.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Build assets/ports.tsv from NGA WPI, GeoNames, and/or OpenStreetMap."
    )
    ap.add_argument("--user", default="demo",
                    help="GeoNames username (register free at geonames.org)")
    ap.add_argument("--wpi-file", metavar="PATH",
                    help="Path to locally downloaded UpdatedPub150.csv or WPI.zip")
    ap.add_argument("--no-wpi",      action="store_true",
                    help="Exclude WPI data from output (does not affect cache)")
    ap.add_argument("--no-geonames", action="store_true",
                    help="Skip GeoNames API calls (cached GeoNames data still included in TSV)")
    ap.add_argument("--no-osm",      action="store_true",
                    help="Skip OSM Overpass API calls (cached OSM data still included in TSV)")
    ap.add_argument(
        "--countries", metavar="CC[,CC...]", default="",
        help=(
            "ISO country codes to fetch from both GeoNames and OSM (additive — adds to cache). "
            "Already-cached entries are skipped. 'ALL' = every country (~5 h for ALL+ALL). "
            "Examples: PL  or  PL,DE,FI,SE,NL  or  ALL. "
            "Combine with --no-geonames or --no-osm to restrict to one source."
        ),
    )
    ap.add_argument("--clean-cache", action="store_true",
                    help=(
                        "Delete all cached GeoNames and OSM data and start from scratch. "
                        "Use this if cached data is corrupt or you want a full re-fetch."
                    ))
    ap.add_argument("--rebuild-tsv", action="store_true",
                    help=(
                        "Regenerate ports.tsv from the existing cache without making "
                        "any new API calls.  Useful after --wpi-file changes."
                    ))
    args = ap.parse_args()

    # ── Handle --clean-cache first ────────────────────────────────────────────
    if args.clean_cache:
        _cache_clear()
        if args.rebuild_tsv or not any([args.wpi_file, not args.no_geonames,
                                        not args.no_osm, args.countries]):
            print("Cache cleared.  Re-run without --clean-cache to fetch data.")
            return

    # ── Load shared cache (persists between all runs) ─────────────────────────
    cache = _cache_load()

    # ── Resolve country list (shared by GeoNames and OSM) ─────────────────────
    countries: list[str] = []
    if args.countries:
        raw = args.countries.upper().strip()
        countries = list(_ALL_COUNTRIES) if raw == "ALL" else [
            c.strip() for c in raw.split(",") if c.strip()
        ]

    if args.user == "demo" and not args.no_geonames and not args.rebuild_tsv:
        print(
            "Note: using the 'demo' GeoNames account.\n"
            "  For complete coverage, register free at https://www.geonames.org/login\n"
            "  and re-run with --user YOUR_USERNAME\n"
        )

    # ── Fetch new data (skipped with --rebuild-tsv) ───────────────────────────
    if not args.rebuild_tsv:
        if not args.no_geonames:
            print("Fetching GeoNames supplement…")
            fetch_geonames(args.user, cache,
                           countries=countries if countries else None)

        if not args.no_osm and countries:
            print(f"Fetching OSM data for: {', '.join(countries)}")
            fetch_osm(countries, cache)

    # ── Collect rows from cache + fresh WPI parse ─────────────────────────────
    # The TSV is always built from the FULL cache so that incremental runs
    # (e.g. PL first, then DE, then ALL) accumulate correctly.
    all_rows: list[dict] = collect_from_cache(cache)

    if not args.no_wpi:
        wpi_rows = fetch_wpi(args.wpi_file)
        all_rows = wpi_rows + all_rows

    all_rows.sort(key=lambda r: (
        0 if r["type"] == "PRT" else {"HBR": 1, "MRNA": 2, "LDNG": 3, "ANCH": 4}.get(r["type"], 9),
        r["name"].lower()
    ))

    # ── Write TSV (24 columns) ────────────────────────────────────────────────
    _EMPTY_NAV = {  # defaults for GeoNames/OSM rows that lack navigation fields
        "harbor_type": "", "harbor_use": "", "shelter": "",
        "tidal_range_m": "", "channel_depth_m": "", "max_vessel_length_m": "",
        "chart": "", "navarea": "", "publication": "", "publication_link": "",
        "pilotage": "", "entry_restrictions": "", "first_port_entry": "",
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(
            "name\tcountry\tlat\tlon\ttype\tsize\tvhf\tphone\tcall_sign"
            "\twpi_index\tfacilities"
            "\tharbor_type\tharbor_use\tshelter"
            "\ttidal_range_m\tchannel_depth_m\tmax_vessel_length_m"
            "\tchart\tnavarea\tpublication\tpublication_link"
            "\tpilotage\tentry_restrictions\tfirst_port_entry\n"
        )
        def clean(s: str) -> str:
            return str(s).replace("\t", " ").replace("\n", " ")

        for r in all_rows:
            n = {**_EMPTY_NAV, **r}  # merge so GeoNames/OSM rows get empty nav fields
            f.write("\t".join([
                clean(n["name"]),
                clean(n["country"]),
                str(n["lat"]),
                str(n["lon"]),
                clean(n["type"]),
                clean(n["size"]),
                clean(n["vhf"]),
                clean(n["phone"]),
                clean(n["call_sign"]),
                clean(n["wpi_index"]),
                clean(n["facilities"]),
                clean(n["harbor_type"]),
                clean(n["harbor_use"]),
                clean(n["shelter"]),
                clean(n["tidal_range_m"]),
                clean(n["channel_depth_m"]),
                clean(n["max_vessel_length_m"]),
                clean(n["chart"]),
                clean(n["navarea"]),
                clean(n["publication"]),
                clean(n["publication_link"]),
                clean(n["pilotage"]),
                clean(n["entry_restrictions"]),
                clean(n["first_port_entry"]),
            ]) + "\n")

    # Cache is intentionally NOT cleared here — it persists for future runs.
    # Use --clean-cache to reset everything.

    wpi_total = sum(1 for r in all_rows if r["wpi_index"])
    gn_total  = sum(1 for r in all_rows
                    if not r["wpi_index"] and not r.get("_osm"))
    osm_total = len(all_rows) - wpi_total - gn_total
    vhf_total = sum(1 for r in all_rows if r["vhf"])
    print(f"\nSaved {len(all_rows)} ports -> {OUT}")
    print(f"  WPI:      {wpi_total:5d}")
    cached_gn = sum(1 for k, v in cache.items()
                    if ":" in k and not k.startswith("OSM:") and v.get("done"))
    cached_osm = sum(1 for k, v in cache.items()
                     if k.startswith("OSM:") and v.get("done"))
    if cached_gn:
        print(f"  GeoNames: {sum(len(v['rows']) for k,v in cache.items() if ':' in k and not k.startswith('OSM:') and v.get('done')):5d}  ({cached_gn} country/code pairs)")
    if cached_osm:
        print(f"  OSM:      {sum(len(v['rows']) for k,v in cache.items() if k.startswith('OSM:') and v.get('done')):5d}  ({cached_osm} countries)")
    print(f"  VHF data: {vhf_total:5d} ports")
    print(f"  Cache:    {_CACHE_FILE.name}  (use --clean-cache to reset)")


if __name__ == "__main__":
    main()
