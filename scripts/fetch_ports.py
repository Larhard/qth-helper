#!/usr/bin/env python3
"""
Fetches port, harbour and marina locations from the GeoNames web service and
writes them to assets/ports.tsv.

GeoNames feature codes fetched (class S – Spot):
  PRT   port / seaport / river port / lake port
  HBR   harbour
  MRNA  marina
  LDNG  landing (small wharfs, boat landings)
  ANCH  anchorage

Port-size note:
  Major commercial ports (PRT) are listed first.
  Recreational ports / marinas (MRNA, HBR, LDNG, ANCH) follow.
  If you need separate "Major port" vs "Marina" modes, split on the type
  column by re-running this script with a reduced FEATURE_CODES list.

Usage:
  1. Register for a free GeoNames account at https://www.geonames.org/login
  2. Run:  python scripts/fetch_ports.py [--user YOUR_USERNAME]
     (defaults to the limited 'demo' account if no username given)
"""
import argparse, csv, json, sys, time, urllib.request
from pathlib import Path

OUT = Path(__file__).parent.parent / "assets" / "ports.tsv"

FEATURE_CODES = ["PRT", "HBR", "MRNA", "LDNG", "ANCH"]
# Priority order for sorting when datasets overlap.
PRIORITY = {c: i for i, c in enumerate(FEATURE_CODES)}

def fetch(feature_code: str, start: int, user: str) -> list:
    url = (
        "http://api.geonames.org/searchJSON"
        f"?featureCode={feature_code}"
        "&maxRows=1000"
        f"&startRow={start}"
        f"&username={user}"
        "&style=SHORT"
    )
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return json.loads(resp.read()).get("geonames", [])
    except Exception as e:
        print(f"  Warning: {e}", file=sys.stderr)
        return []

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="demo",
                    help="GeoNames username (register free at geonames.org)")
    args = ap.parse_args()

    if args.user == "demo":
        print("Note: using the 'demo' account which is rate-limited.")
        print("Register free at https://www.geonames.org/login for higher limits.")

    seen: dict[int, dict] = {}

    for code in FEATURE_CODES:
        print(f"Fetching {code}…")
        start = 0
        while True:
            hits = fetch(code, start, args.user)
            if not hits:
                break
            for h in hits:
                gid = h.get("geonameId")
                if gid and gid not in seen:
                    name = (h.get("asciiName") or h.get("name", "")).strip()
                    country = h.get("countryCode", "").strip()
                    lat, lon = h.get("lat", ""), h.get("lng", "")
                    if name and lat and lon:
                        seen[gid] = dict(name=name, country=country,
                                         lat=lat, lon=lon, code=code)
            start += len(hits)
            if len(hits) < 1000:
                break
            time.sleep(0.3)
        print(f"  {len(seen)} entries so far")

    # Sort: PRT first, then others alphabetically by name.
    rows = sorted(seen.values(),
                  key=lambda r: (PRIORITY.get(r["code"], 9), r["name"].lower()))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["name", "country", "lat", "lon"])
        for r in rows:
            w.writerow([r["name"], r["country"], r["lat"], r["lon"]])

    print(f"\nSaved {len(rows)} ports → {OUT}")


if __name__ == "__main__":
    main()
