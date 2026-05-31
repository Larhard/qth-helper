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
  Usage:  --osm-countries PL,DE,FI,SE,NL,HU   (comma-separated ISO codes)
  "ALL" queries every country (slow, ~several hours):
          --osm-countries ALL
"""
import argparse, csv, io, json, re, sys, time, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path

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
_VHF_COLS      = ("comm_vhf", "communications_vhf")          # not in current WPI CSV
_PHONE_COLS    = ("comm_phone", "comm_radio_tel")              # not in current WPI CSV
_CALLSIGN_COLS = ("radio_call_sign", "call_sign")              # not in current WPI CSV
_SIZE_COLS     = ("harbor_size",)
_LAT_COLS      = ("latitude_dec", "latitude")
_LON_COLS      = ("longitude_dec", "longitude")
_NAME_COLS     = ("port_name", "main_port_name")
_COUNTRY_COLS  = ("country_code", "country")
_INDEX_COLS    = ("world_port_number", "world_port_index_number", "index_no")

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
        "name":    _NAME_COLS,
        "country": _COUNTRY_COLS,
        "lat":     _LAT_COLS,
        "lon":     _LON_COLS,
        "size":    _SIZE_COLS,
        "vhf":     _VHF_COLS,
        "phone":   _PHONE_COLS,
        "sign":    _CALLSIGN_COLS,
        "index":   _INDEX_COLS,
    }.items()}

    # Columns that must exist for basic parsing to work.
    _REQUIRED = {"name", "lat", "lon", "country"}
    # Columns absent in the current WPI CSV (known data limitation, not an error).
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
        rows.append({
            "name":       name,
            "country":    (g("country") + "  ")[:2].upper().strip(),
            "lat":        lat,
            "lon":        lon,
            "type":       "PRT",
            "size":       g("size").upper(),
            "vhf":        _clean_vhf(g("vhf")),
            "phone":      g("phone"),
            "call_sign":  g("sign"),
            "wpi_index":  g("index"),
            "facilities": "|".join(facilities),
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
_GN_CACHE = Path(__file__).parent / ".geonames_cache.json"


def _cache_load() -> dict:
    if _GN_CACHE.exists():
        try:
            cache = json.loads(_GN_CACHE.read_text(encoding="utf-8"))
            done_count = sum(1 for v in cache.values() if v.get("done"))
            if done_count:
                print(f"  Cache: {done_count} country/code pairs already fetched.")
            return cache
        except Exception:
            pass
    return {}


def _cache_save(cache: dict) -> None:
    _GN_CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


def _cache_clear() -> None:
    if _GN_CACHE.exists():
        _GN_CACHE.unlink()


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


def fetch_geonames(user: str) -> list[dict]:
    cache    = _cache_load()
    all_rows : list[dict] = []
    seen     : set[int]   = set()
    abort = False

    total_pairs = len(GEONAMES_CODES) * len(_ALL_COUNTRIES)
    done_pairs  = sum(1 for v in cache.values() if v.get("done"))
    print(f"  {total_pairs} country/code pairs to fetch "
          f"({done_pairs} already cached).")

    pair_num = 0
    for feat_code in GEONAMES_CODES:
        if abort:
            break
        code_total = 0

        for country in _ALL_COUNTRIES:
            if abort:
                break

            pair_num += 1
            cache_key = f"{feat_code}:{country}"

            # Reuse cached result for this pair.
            if cache.get(cache_key, {}).get("done"):
                for r in cache[cache_key]["rows"]:
                    seen.add(r.get("_gid", 0))
                    all_rows.append(r)
                    code_total += 1
                continue

            rows, fatal = _fetch_country_code(feat_code, country, user, seen)

            # Cache this pair immediately (partial results are better than none).
            cache[cache_key] = {"done": not fatal, "rows": rows}
            if pair_num % 20 == 0:
                # Flush to disk every 20 pairs to limit data loss on Ctrl-C.
                _cache_save(cache)

            all_rows.extend(rows)
            code_total += len(rows)

            if fatal:
                abort = True
                break

            if rows:
                # Only delay when we actually got data (skip idle countries fast).
                time.sleep(0.3)

        _cache_save(cache)  # always flush at end of each feature code
        print(f"  {feat_code}: {code_total} entries total.")

    # Strip internal _gid field before returning
    for r in all_rows:
        r.pop("_gid", None)

    print(f"  {len(all_rows)} GeoNames entries total.")
    return all_rows


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


def _overpass(query: str, *, timeout: int = 180) -> bytes | None:
    """POST a query to the Overpass API and return the raw response bytes."""
    data = urllib.parse.urlencode({"data": query}).encode()
    req = urllib.request.Request(
        OVERPASS_API, data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept":       "application/json",
            "User-Agent":   "QTH-Dashboard-fetch-ports/1.0 (recreational navigation app)",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        # Try to read the error body — Overpass often puts a helpful message there
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        print(f"  Overpass HTTP {e.code} {e.reason}. {body}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  Overpass error: {e}", file=sys.stderr)
        return None


def _osm_vhf(tags: dict) -> str:
    raw = tags.get("communication:vhf", "") or tags.get("seamark:radio:frequency", "")
    return _clean_vhf(raw)


def fetch_osm(countries: list[str], cache: dict) -> list[dict]:
    """Query Overpass for marinas/harbours in each listed country."""
    all_rows: list[dict] = []
    seen: set[tuple] = set()

    for country in countries:
        cache_key = f"{_OSM_CACHE_PREFIX}:{country}"
        if cache.get(cache_key, {}).get("done"):
            rows = cache[cache_key]["rows"]
            print(f"  OSM {country}: {len(rows)} cached entries.")
            all_rows.extend(rows)
            continue

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
        print(f"  OSM {country}: {len(rows)} entries ({vhf_count} with VHF).")

        cache[cache_key] = {"done": True, "rows": rows}
        _cache_save(cache)
        all_rows.extend(rows)
        time.sleep(1.0)  # be polite to the Overpass server

    return all_rows


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Build assets/ports.tsv from NGA WPI, GeoNames, and/or OpenStreetMap."
    )
    ap.add_argument("--user", default="demo",
                    help="GeoNames username (register free at geonames.org)")
    ap.add_argument("--wpi-file", metavar="PATH",
                    help="Path to locally downloaded UpdatedPub150.csv or WPI.zip")
    ap.add_argument("--no-wpi",      action="store_true", help="Skip WPI")
    ap.add_argument("--no-geonames", action="store_true", help="Skip GeoNames")
    ap.add_argument(
        "--osm-countries", metavar="CC[,CC...]", default="",
        help=(
            "Comma-separated ISO country codes to supplement with OpenStreetMap "
            "marina/harbour data via Overpass API.  Use 'ALL' for every country. "
            "Examples: PL,DE,FI,SE,NL  or  PL  or  ALL.  "
            "OSM often includes actual VHF channels for small ports."
        ),
    )
    args = ap.parse_args()

    if args.user == "demo" and not args.no_geonames:
        print(
            "Note: using the 'demo' GeoNames account.\n"
            "  For complete marina/harbour coverage, register free at\n"
            "  https://www.geonames.org/login and re-run with --user YOUR_USERNAME\n"
        )

    osm_countries: list[str] = []
    if args.osm_countries:
        raw = args.osm_countries.upper().strip()
        osm_countries = list(_ALL_COUNTRIES) if raw == "ALL" else [
            c.strip() for c in raw.split(",") if c.strip()
        ]

    shared_cache = _cache_load()
    all_rows: list[dict] = []

    if not args.no_wpi:
        all_rows += fetch_wpi(args.wpi_file)

    if not args.no_geonames:
        print("Fetching GeoNames supplement…")
        all_rows += fetch_geonames(args.user)

    if osm_countries:
        print(f"Fetching OSM data for: {', '.join(osm_countries)}")
        all_rows += fetch_osm(osm_countries, shared_cache)

    all_rows.sort(key=lambda r: (
        0 if r["type"] == "PRT" else {"HBR": 1, "MRNA": 2, "LDNG": 3, "ANCH": 4}.get(r["type"], 9),
        r["name"].lower()
    ))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("name\tcountry\tlat\tlon\ttype\tsize\tvhf\tphone\tcall_sign\twpi_index\tfacilities\n")
        for r in all_rows:
            f.write("\t".join([
                r["name"].replace("\t", " "),
                r["country"],
                str(r["lat"]),
                str(r["lon"]),
                r["type"],
                r["size"],
                r["vhf"],
                r["phone"].replace("\t", " "),
                r["call_sign"].replace("\t", " "),
                r["wpi_index"],
                r["facilities"],
            ]) + "\n")

    # Cache is only cleared after a successful write — so a crash or Ctrl-C
    # before this point leaves the cache intact for the next run.
    _cache_clear()

    vhf_total = sum(1 for r in all_rows if r["vhf"])
    wpi_total = sum(1 for r in all_rows if r["wpi_index"])
    print(f"\nSaved {len(all_rows)} ports -> {OUT}")
    print(f"  WPI:       {wpi_total:5d}")
    print(f"  GeoNames:  {len(all_rows) - wpi_total - sum(1 for r in all_rows if not r['wpi_index'] and r['country'].upper() in {c.upper() for c in osm_countries}):5d}")
    for cc in osm_countries:
        n = sum(1 for r in all_rows if r["country"].upper() == cc.upper() and not r["wpi_index"])
        v = sum(1 for r in all_rows if r["country"].upper() == cc.upper() and r["vhf"])
        if n:
            print(f"  OSM {cc}:   {n:5d}  ({v} with VHF)")
    print(f"  VHF data:  {vhf_total:5d} ports")


if __name__ == "__main__":
    main()
