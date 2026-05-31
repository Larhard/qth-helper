# QTH Dashboard

A high-readability GPS navigation tool for Android, built for outdoor, maritime, and ham radio use. Optimised for glanceability in direct sunlight, wet conditions, and one-handed operation.

> ⚠️ **Vibe-coded project.** Built interactively with an AI assistant. No formal verification, testing framework, or safety audit has been performed. The author provides this software as-is, without any warranty of fitness for any particular purpose — including navigation, safety, or emergency use. **Never rely on this app as your sole means of navigation.**

---

## Features

### Heading
- Dual rotating arrows: **primary** (full colour) shows the active heading source, **secondary** (dimmed) shows the other
- Source auto-switches at ≥ 5.4 km/h: **GPS course** (green, true north) when moving, **magnetic compass + WMM declination** (white) when stationary
- **TRK** — smoothed track bearing computed from a spatial point buffer; more stable than last-two-point bearing and adapts within ~80 m of a direction change
- Speed display (long-press to cycle km/h / knots / mph)

### GPS Coordinates
- Three selectable formats: **DD° MM.MMM'** (default), **DD.DDDDDD°**, **DD° MM' SS.SS"** — long-press to cycle
- **IARU/Maidenhead** locator in 8-character extended format (`JO62mm80`), plus 6-char and 4-char variants
- **MGRS** — long-press locator to switch type
- Tap coordinates or locator to copy to clipboard
- GPS-calibrated clock (UTC or local — long-press to switch), altitude, and accuracy

### Nearest city / port
Four precision levels, cycled by tapping the city section:

| Mode | Dataset | Typical coverage |
|------|---------|-----------------|
| Large | Top 5 000 cities by population | Global overview |
| Precise | All cities ≥ 5 000 pop. | Regional |
| Detailed | All cities ≥ 1 000 pop. | Local |
| Port | WPI + GeoNames harbours/marinas | Maritime |

In **Port mode**, the VHF working channel and radio call sign are displayed when available; tap VHF to copy.

### Waypoints / MOB
- Tap **MOB** to drop a waypoint at the current position (serves as Man Overboard marker)
- Active waypoint shows bearing arrow, degrees, distance, coordinates (all formats), locator, creation date/time, and elapsed time
- Tap `+` in the Waypoints screen to add a waypoint by entering coordinates manually
- Tap a waypoint in the list to activate it as a navigation target; tap again to deactivate
- **Hold the active waypoint card for 3 seconds** to deactivate — progress ring fills the border; releasing early cancels
- Waypoint list sorted newest-first; each entry shows elapsed time, coordinates, and distance from current position

### Day / Night mode
- **Day** — full-contrast palette, readable in direct sunlight
- **Night** — red-only palette; no greens, blues, or ambers; preserves rhodopsin (night-vision accommodation) for marine use
- **Hold the moon/sun icon** (top-right area) to switch — deliberate hold required to prevent accidental activation during night sailing

### GPS on lock screen
- By default, GPS is paused when the screen turns off (saves battery)
- **Hold the source label** (`GPS @ 🔒`) for 1.5 s to toggle **ON LOCK** mode — GPS keeps tracking via a foreground service when the screen is off
- ON LOCK requires the *"Allow all the time"* location permission; the system will prompt for it when first enabled
- A persistent notification is shown while GPS is running in the background (Android requirement)

### Debug screen
Access by **holding the bug icon** (top-left corner). Three tabs:
- **GPS** — fix quality, accuracy, satellite count by constellation (GPS/GLO/GAL/BDS), position, motion, clock skew, session stats
- **Heading** — all bearing sources side-by-side, magnetic declination, TRK buffer visualisation
- **Locators** — all coordinate formats (tap to copy), Maidenhead 4/6/8-char, MGRS, geo URI, OSM link, nearest entry from each city/port mode

---

## Project structure

```
qth_dashboard/
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── city.dart          # City + port data model (shared)
│   │   └── waypoint.dart
│   ├── screens/
│   │   ├── home_screen.dart   # Main navigation display
│   │   ├── waypoints_screen.dart
│   │   └── debug_screen.dart
│   ├── services/
│   │   ├── city_service.dart  # Spatial grid lookup for cities and ports
│   │   ├── declination_service.dart
│   │   └── waypoint_service.dart
│   ├── utils/
│   │   ├── coordinate_utils.dart  # DDM / DD / DMS + Maidenhead
│   │   ├── geo_utils.dart         # Haversine + bearing
│   │   ├── mgrs_utils.dart
│   │   ├── track_bearing.dart     # Smoothed track bearing estimator
│   │   └── units.dart             # Speed / distance / format preferences
│   └── widgets/
│       └── arrow_widget.dart
├── android/
│   └── app/src/main/
│       ├── kotlin/…/MainActivity.kt  # Lock-screen flags + GNSS channel
│       └── AndroidManifest.xml
├── assets/
│   ├── cities.tsv           # top-5 000 cities — committed (260 KB, CC BY 4.0)
│   ├── cities_precise.tsv   # stub only — regenerate with fetch_cities.py
│   ├── cities_detailed.tsv  # stub only — regenerate with fetch_cities.py
│   ├── ports.tsv            # stub only — regenerate with fetch_ports.py
│   └── icon/                # generated by generate_icon.py
└── scripts/
    ├── fetch_cities.py      # Downloads city datasets from GeoNames
    ├── fetch_ports.py       # Downloads port data from NGA WPI + GeoNames
    └── generate_icon.py     # Generates app icon PNGs via Pillow
```

---

## Building

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | 3.x stable | Add `flutter\bin` to PATH |
| Android SDK | API 21+ | Installed by Android Studio or `flutter doctor` |
| Python | 3.8+ | Required for the data-fetch scripts only |
| [Pillow](https://pillow.readthedocs.io/) | any | `pip install Pillow` — icon generation only |

---

### Step 1 — Install Flutter packages

```powershell
flutter pub get
```

---

### Step 2 — Create asset stubs (required before first build, instant)

The three large data assets are gitignored and must be created locally before
Flutter can compile. This step takes under a second and requires no internet:

```powershell
python scripts\create_stubs.py
```

This creates header-only placeholder files. The app will start with only the
built-in top-5 000 city dataset until the fetch scripts below are run.

---

### Step 3 — Download city data (optional but recommended, ~10 MB)

```powershell
python scripts\fetch_cities.py
```

Downloads `cities1000.zip` from GeoNames and produces three TSV files under `assets/`:

| File | Rows | Use |
|------|------|-----|
| `cities.tsv` | 5 000 | Global overview |
| `cities_precise.tsv` | ~47 000 | Regional |
| `cities_detailed.tsv` | ~140 000 | Local detail |

Each TSV includes: `name`, `country`, `lat`, `lon`, `population`, `timezone`.

---

### Step 3 — Download port data (optional but recommended for maritime use)

The port database is sourced from two places:

**NGA World Port Index (WPI)** — ~3 800 commercial ports with harbour size, VHF working channel, and radio call sign.
The NGA server blocks automated downloads, so this file must be saved manually:

1. Open <https://msi.nga.mil/Publications/WPI> in a browser
2. Under **Download Publication**, click **Complete Volume** — saves `UpdatedPub150.csv` (~3 800 rows)  
   ⚠️ Do **not** choose the PDF, MS Access, or Shapefile options — those are archived 2019 editions and will not parse
3. Save `UpdatedPub150.csv` anywhere on your computer

**GeoNames supplement** — covers marinas, small harbours, and anchorages not in the WPI.
Requires a **free GeoNames account** with free web services enabled:

1. Register at <https://www.geonames.org/login>
2. Go to <https://www.geonames.org/manageaccount>, tick **Free Web Services**, save

#### Run the script

```powershell
# With both WPI file and GeoNames account (recommended):
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --user YOUR_USERNAME

# Restrict to specific countries (fetches both GeoNames and OSM for those countries):
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --user YOUR_USERNAME --countries PL,DE,FI,SE,NL

# WPI only (no GeoNames account):
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --no-geonames --no-osm

# GeoNames only for specific countries (skip WPI and OSM):
python scripts\fetch_ports.py --no-wpi --no-osm --countries PL --user YOUR_USERNAME
```

If the script is interrupted (network error, daily quota), re-run with the same arguments — GeoNames progress is cached in `scripts/.geonames_cache.json` and already-fetched feature codes will not be re-queried.

#### What the script produces

`assets/ports.tsv` — 11 columns per entry:

| Column | Content |
|--------|---------|
| `name` | Port / harbour name |
| `country` | ISO 3166-1 alpha-2 code |
| `lat`, `lon` | Decimal coordinates |
| `type` | `PRT` / `HBR` / `MRNA` / `LDNG` / `ANCH` |
| `size` | WPI harbour size: `L` / `M` / `S` / `VS` |
| `vhf` | VHF working channel(s), e.g. `12;74` |
| `phone` | Harbour-master / operations number |
| `call_sign` | ITU radio call sign |
| `wpi_index` | NGA WPI world port number |
| `facilities` | Pipe-separated flags, e.g. `FUEL_OIL\|WATER\|PROVISIONS` |

A placeholder `ports.tsv` (header only) is committed to the repo, so the app builds and runs without this step — the Port mode will simply show no results until the script is run.

---

### Step 4 — Generate app icon (optional)

```powershell
python scripts\generate_icon.py
dart run flutter_launcher_icons
```

Pre-generated icons are already committed to the repo; only run this if you want to regenerate them.

---

### Run on device

Connect an Android phone with USB debugging enabled:

```powershell
flutter run
```

List connected devices first if needed:

```powershell
flutter devices
flutter run -d DEVICE_ID
```

---

### Build release APK

```powershell
flutter build apk --release
# Output: build\app\outputs\flutter-apk\app-release.apk
```

Transfer to the phone and install, or:

```powershell
flutter install
```

---

## Permissions

| Permission | When required | Reason |
|-----------|---------------|--------|
| `ACCESS_FINE_LOCATION` | Always | GPS coordinates and speed |
| `ACCESS_COARSE_LOCATION` | Always | Fallback location |
| `WAKE_LOCK` | Always | Keep screen on |
| `FOREGROUND_SERVICE` | GPS on lock screen | Android API 28+ requirement |
| `FOREGROUND_SERVICE_LOCATION` | GPS on lock screen | Android API 34+ requirement |
| `ACCESS_BACKGROUND_LOCATION` | GPS on lock screen | Background access, Android 10+; user grants at runtime via system prompt |

All features except *GPS on lock screen* work with only the first three permissions. Internet is never used by the app itself.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `geolocator` | GPS position stream + foreground service |
| `flutter_compass` | Magnetic compass heading |
| `get_storage` | Persistent settings and waypoints (pure Dart) |

---

## Data sources, licences, and attribution

### What is and isn't in this repository

| Asset | In repo? | Licence | Source |
|-------|----------|---------|--------|
| `assets/cities.tsv` (5 000 cities) | ✅ Yes (260 KB) | CC BY 4.0 | GeoNames |
| `assets/cities_precise.tsv` | ❌ Gitignored | CC BY 4.0 | GeoNames (via `fetch_cities.py`) |
| `assets/cities_detailed.tsv` | ❌ Gitignored | CC BY 4.0 | GeoNames (via `fetch_cities.py`) |
| `assets/ports.tsv` | ❌ Gitignored | Public Domain + CC BY 4.0 + **ODbL\*** | NGA WPI + GeoNames + OSM (via `fetch_ports.py`) |
| `data/UpdatedPub150.csv` | ❌ No | US Govt public domain | [NGA WPI](https://msi.nga.mil/Publications/WPI) |
| Source code | ✅ Yes | MIT | This project |
| App icon | ✅ Yes | MIT | This project |

\* **ports.tsv is an ODbL Derived Database** when generated with the `--countries` flag, because it then contains data from OpenStreetMap contributors.  Redistribution of the generated `ports.tsv` file requires making it available under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1.0/).  This does not affect the source code (MIT) or the compiled APK.

### Attribution notices

Applications built from this project must display (e.g. in an About screen or build documentation):

```
City data: GeoNames (geonames.org), CC BY 4.0
Port data: NGA World Port Index (public domain)
           GeoNames (geonames.org), CC BY 4.0
           © OpenStreetMap contributors (ODbL) — where applicable
```

### After running the setup scripts

The generated TSV files are listed in `.gitignore` so they can never be
accidentally staged with `git add .` — no `git update-index` call required.

---

## Removing large files from git history

If large data files were committed previously, remove them from history with
`git filter-repo` (install: `pip install git-filter-repo`):

```bash
# Remove all previously committed large data and raw source files
git filter-repo \
  --path assets/cities_precise.tsv \
  --path assets/cities_detailed.tsv \
  --path assets/ports.tsv \
  --path data/ \
  --invert-paths

# After rewriting, force-push all refs to the remote
git remote set-url origin <your-repo-url>
git push origin --force --all
git push origin --force --tags
```

⚠️ History rewriting **invalidates all existing clones and forks**.  Everyone
who has cloned the repository will need to re-clone or rebase.

---

## Licence

The source code is licensed under the **MIT Licence** — see [LICENSE](LICENSE).

Third-party data sources and their licence requirements are documented in
[NOTICES](NOTICES).

---

## Known limitations

- **Magnetic declination** uses Android's World Magnetic Model (WMM) via `GeomagneticField`. Accuracy degrades between update cycles (every 5 years) and at high latitudes.
- **GPS course** is only used above 5.4 km/h. Below that, the magnetic compass is the primary source and is susceptible to nearby metal and magnetic fields (e.g. a car mount).
- **TRK** requires ~80 m of movement to stabilise after a direction change. It is not available until at least two GPS fixes have been received.
- **City and port databases** are static snapshots generated at build time. Port communication data (VHF channels, phone numbers) comes from the NGA World Port Index; accuracy depends on the WPI publication date.
- **Port VHF data** — the WPI covers commercial ports well; smaller marinas may have incomplete or missing communication data.
- This project was **vibe coded** — no formal testing, security audit, or regulatory review has been performed.
