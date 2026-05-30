#!/usr/bin/env python3
"""
Downloads GeoNames cities1000.zip (all places with population >= 1 000) and
produces three city databases, each a subset of the next:

  assets/cities.tsv          -- top 5 000 cities by population (global overview)
  assets/cities_precise.tsv  -- all ~47 000 cities with population >= 5 000
  assets/cities_detailed.tsv -- all ~140 000 cities with population >= 1 000
                                 (includes small towns like Swiatniki Gorne)

All files are tab-separated: name, country, lat, lon  (header row included).

Run once before building the app:
    python scripts/fetch_cities.py
Requires internet access for this one-time step; the app then works fully offline.
"""
import urllib.request
import zipfile
import io
import os
import sys

GEONAMES_URL = "https://download.geonames.org/export/dump/cities1000.zip"
ASSETS_DIR = os.path.join(os.path.dirname(__file__), '..', 'assets')
LARGE_PATH    = os.path.join(ASSETS_DIR, 'cities.tsv')
PRECISE_PATH  = os.path.join(ASSETS_DIR, 'cities_precise.tsv')
DETAILED_PATH = os.path.join(ASSETS_DIR, 'cities_detailed.tsv')

LARGE_N          = 5_000
PRECISE_MIN_POP  = 5_000


def _write_tsv(path: str, cities: list) -> None:
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('name\tcountry\tlat\tlon\n')
        for name, country, lat, lon, _ in cities:
            safe_name = name.replace('\t', ' ')
            f.write(f'{safe_name}\t{country}\t{lat}\t{lon}\n')


def main():
    print("Downloading cities1000.zip from GeoNames (~10 MB)...")
    try:
        with urllib.request.urlopen(GEONAMES_URL, timeout=120) as resp:
            data = resp.read()
    except Exception as e:
        print(f"Download failed: {e}", file=sys.stderr)
        sys.exit(1)

    print("Parsing...")
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        with zf.open('cities1000.txt') as f:
            content = f.read().decode('utf-8')

    cities = []
    for line in content.splitlines():
        parts = line.split('\t')
        if len(parts) < 15:
            continue
        try:
            name = parts[1].strip()
            lat = float(parts[4])
            lon = float(parts[5])
            country = parts[8].strip()
            population = int(parts[14]) if parts[14].strip() else 0
            if not name:
                continue
            cities.append((name, country, lat, lon, population))
        except (ValueError, IndexError):
            continue

    # Sort by population descending so each subset is deterministic.
    cities.sort(key=lambda x: x[4], reverse=True)

    os.makedirs(ASSETS_DIR, exist_ok=True)

    # Level 1 -- top 5 000 worldwide (global overview)
    _write_tsv(LARGE_PATH, cities[:LARGE_N])
    print(f"Saved {LARGE_N} cities -> {LARGE_PATH}")

    # Level 2 -- all places with population >= 5 000 (regional)
    precise = [c for c in cities if c[4] >= PRECISE_MIN_POP]
    _write_tsv(PRECISE_PATH, precise)
    print(f"Saved {len(precise)} cities -> {PRECISE_PATH}")

    # Level 3 -- full dataset: population >= 1 000 (local, includes small towns)
    _write_tsv(DETAILED_PATH, cities)
    print(f"Saved {len(cities)} cities -> {DETAILED_PATH}")


if __name__ == '__main__':
    main()
