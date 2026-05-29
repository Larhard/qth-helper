#!/usr/bin/env python3
"""
Downloads the top 5000 cities by population from GeoNames and writes
assets/cities.tsv (tab-separated: name, country, lat, lon).

Run once before building the app:
    python scripts/fetch_cities.py

Requires internet access for this one-time step.
The app then works fully offline.
"""
import urllib.request
import zipfile
import io
import os
import sys

GEONAMES_URL = "https://download.geonames.org/export/dump/cities5000.zip"
ASSETS_DIR = os.path.join(os.path.dirname(__file__), '..', 'assets')
OUTPUT_PATH = os.path.join(ASSETS_DIR, 'cities.tsv')
TOP_N = 5000


def main():
    print("Downloading cities5000.zip from GeoNames (~2 MB)…")
    try:
        with urllib.request.urlopen(GEONAMES_URL, timeout=60) as resp:
            data = resp.read()
    except Exception as e:
        print(f"Download failed: {e}", file=sys.stderr)
        sys.exit(1)

    print("Parsing…")
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        with zf.open('cities5000.txt') as f:
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
            # Skip entries with no useful name
            if not name:
                continue
            cities.append((name, country, lat, lon, population))
        except (ValueError, IndexError):
            continue

    cities.sort(key=lambda x: x[4], reverse=True)
    top = cities[:TOP_N]

    os.makedirs(ASSETS_DIR, exist_ok=True)
    with open(OUTPUT_PATH, 'w', encoding='utf-8', newline='\n') as f:
        f.write('name\tcountry\tlat\tlon\n')
        for c in top:
            # Tabs in city names would break parsing — replace just in case
            safe_name = c[0].replace('\t', ' ')
            f.write(f'{safe_name}\t{c[1]}\t{c[2]}\t{c[3]}\n')

    print(f"Saved {len(top)} cities → {OUTPUT_PATH}")


if __name__ == '__main__':
    main()
