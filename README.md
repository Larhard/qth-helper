# QTH Dashboard

A high-readability GPS navigation tool for Android, built for outdoor, maritime,
and ham radio use. Optimised for glanceability in direct sunlight, wet conditions,
and one-handed operation.

> **Vibe-coded.** Built interactively with an AI assistant. No formal testing,
> safety audit, or regulatory review has been performed. The author provides this
> software as-is, without any warranty — including fitness for navigation, safety,
> or emergency use. **Never rely on this app as your sole means of navigation.**

---

## Features

### Heading display

Two display modes — long-press the arrow/rose to toggle:

**Arrow mode**
- **Primary arrow** (full colour) shows the active source
- **Secondary arrow** (30 % opacity) shows the complementary source
- Relative dot ring marks bearing to city, active waypoint, and MOB

**Wind-rose mode**
- Compass ring rotates so your heading is always at 12 o'clock
- **North marker**: traditional red tick + "N" label — distinct from waypoint dots
- **Heading cursor**: fixed white triangle at 12 o'clock indicates current travel direction
- **Secondary bearing** shown as a dash on the ring
- Bearing dots for city / waypoint / MOB rotate with the rose

**Heading sources** — long-press the degree readout to cycle:
- **GPS course** (green) — used above 5.4 km/h; true-north corrected
- **TRK** (yellow-green) — smoothed track bearing from a spatial point buffer; more stable than last-two-point GPS
- **MAG** (white / dim red) — magnetic compass with WMM declination correction; primary when stationary

### GPS Coordinates
- Three formats: **DD° MM.MMM'** (default), **DD.DDDDDD°**, **DD° MM' SS.SS"** — long-press to cycle
- **IARU/Maidenhead** locator, 8-character extended format (`JO62mm80`)
- **MGRS** — long-press the locator to switch type
- Tap coordinates or locator to copy to clipboard
- GPS-calibrated clock (UTC or local — long-press to switch), altitude, and accuracy

### Nearest city / port

Four precision levels, cycled by tapping the city section:

| Mode | Dataset | Coverage |
|------|---------|----------|
| Large | Top 5 000 cities | Global overview |
| Precise | Cities ≥ 5 000 pop. | Regional |
| Detailed | Cities ≥ 1 000 pop. | Local |
| Port | WPI + GeoNames harbours / marinas | Maritime |

Modes with no data loaded (setup scripts not yet run) are skipped automatically.
In **Port mode**, VHF working channel and radio call sign are shown when available; tap VHF to copy.
Long-press the city name to open a full detail sheet (coordinates, bearing, port facilities, links).

### Waypoints and MOB

**MOB (Man Overboard / emergency marker)**
- Tap **MOB** to drop an emergency waypoint at the current position
- Shows bearing, distance, coordinates (all formats), locator, and timestamp
- **Hold the MOB card for 3 s** to clear — progress ring fills the border; release early to cancel
- MOB is always visible at the bottom of the screen (landscape and portrait)

**Navigation waypoints**
- Open the **Waypoints screen** (pin icon, top-right) to manage saved waypoints
- Tap a waypoint to activate as navigation target; active waypoint shows bearing and distance
- Tap `+` to add a waypoint by coordinates
- **Hold to delete** from the list (prevents accidental removal)
- **Hold the nav waypoint card for 3 s** to deactivate

Both MOB and navigation waypoints can be active simultaneously.

### Day / Night mode
- **Day** — semantic colour palette: green = GPS, amber = MGRS/time, cyan = ports, orange = nav waypoints, red = emergency
- **Night** — red-only palette (hue ≈ 0°, varying brightness); no greens, blues, or ambers; preserves rhodopsin for marine and hiking use
- **Hold the moon / sun icon** to switch — deliberate hold prevents accidental activation

The entire UI uses a unified colour system (`kD*` day constants, `kN*` night constants in `utils/units.dart`). Changing one constant updates every screen.

### GPS on lock screen
- GPS pauses when the screen turns off by default (saves battery on long hikes)
- **Long-press** `GPS @ lock` to toggle — GPS keeps running via a foreground service (ON LOCK mode)
- ON LOCK requires the *"Allow all the time"* location permission; the system prompts on first enable

### Pocket lock
- **Long-press** `phone @ sensor` to toggle proximity-based screen dimming
- When enabled and the phone is in a pocket for 5 seconds: screen dims to black, touch is blocked
- Screen restores immediately when the phone is taken out
- Only activates when the charger is **not** connected
- Uses brightness + touch-blocking only — no PIN required, biometric unlock works instantly

### Debug screen
Hold the bug icon (top-left). Four tabs:

| Tab | Contents |
|-----|----------|
| GPS | Fix quality, satellite count per constellation, stale timer |
| Heading | All bearing sources (GPS course, TRK, MAG), declination, track buffer canvas |
| Locators | All coordinate formats, Maidenhead 4/6/8, MGRS, nearest city per mode |
| Sensors | Proximity, environmental (temp, pressure, light, humidity), gravity, linear acceleration, battery |

---

## Project structure

```
qth_helper/
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── city.dart            # City + port data model
│   │   └── waypoint.dart
│   ├── screens/
│   │   ├── home_screen.dart     # Main navigation display (~2 500 lines)
│   │   ├── waypoints_screen.dart
│   │   ├── about_screen.dart    # Legal notices and open-source licences
│   │   └── debug_screen.dart
│   ├── services/
│   │   ├── city_service.dart    # Spatial grid lookup (cities and ports)
│   │   ├── declination_service.dart
│   │   ├── environment_service.dart  # Sensor stream (proximity, env, motion)
│   │   └── waypoint_service.dart
│   ├── utils/
│   │   ├── coordinate_utils.dart  # DDM / DD / DMS + Maidenhead
│   │   ├── geo_utils.dart         # Haversine + bearing
│   │   ├── mgrs_utils.dart
│   │   ├── track_bearing.dart     # Smoothed track bearing estimator
│   │   └── units.dart             # Unified colour palette + speed / distance / format preferences
│   └── widgets/
│       └── arrow_widget.dart
├── android/app/src/main/
│   ├── kotlin/…/MainActivity.kt   # Lock-screen flags, pocket lock, GNSS/sensor channels
│   └── AndroidManifest.xml
├── assets/
│   ├── cities.tsv            # Top-5 000 cities — committed (260 KB, CC BY 4.0)
│   ├── cities_precise.tsv    # gitignored — create with fetch_cities.py
│   ├── cities_detailed.tsv   # gitignored — create with fetch_cities.py
│   ├── ports.tsv             # gitignored — create with fetch_ports.py
│   └── icon/                 # App icon PNGs — committed
└── scripts/
    ├── create_stubs.py       # Creates placeholder assets (instant, no internet)
    ├── fetch_cities.py       # Downloads city datasets from GeoNames
    ├── fetch_ports.py        # Downloads port data from NGA WPI + GeoNames + OSM
    └── generate_icon.py      # Generates app icon PNGs via Pillow
```

---

## Building

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | 3.x stable | Add `flutter/bin` to `PATH` |
| Android SDK | API 21+ | Via Android Studio or `flutter doctor` |
| Python | 3.8+ | `python3` on Linux/macOS; `python` on Windows |
| [Pillow](https://pillow.readthedocs.io/) | any | `pip install Pillow` — icon generation only |

---

### Quick setup

Run the setup script once after cloning. It installs Flutter packages, creates
the required asset placeholders, and generates the app icon. No internet access
is needed for this step.

**Windows (PowerShell):**
```powershell
.\setup.ps1
```

**Linux / macOS:**
```bash
chmod +x setup.sh   # first time only
./setup.sh
```

The app is then ready to build and run with the built-in top-5 000 city dataset.
Full city and port data can be downloaded separately (see below).

---

### Run on device

```bash
flutter run
```

```bash
flutter devices             # list connected devices
flutter run -d DEVICE_ID   # target a specific device
```

---

### Build release APK

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

```bash
flutter install   # transfer and install directly over USB
```

---

### Download full city data (optional, ~10 MB)

The setup script ships with only the top-5 000 cities. For the Precise and
Detailed modes, download the extended datasets:

```bash
# Windows
python scripts\fetch_cities.py

# Linux / macOS
python3 scripts/fetch_cities.py
```

Downloads `cities1000.zip` from GeoNames and writes three files to `assets/`:

| File | Rows | Mode |
|------|------|------|
| `cities.tsv` | 5 000 | Large (always present) |
| `cities_precise.tsv` | ~47 000 | Precise |
| `cities_detailed.tsv` | ~140 000 | Detailed |

---

### Download port data (optional, maritime use)

Port data comes from three sources. NGA blocks automated downloads, so the
WPI file must be saved manually first:

1. Open <https://msi.nga.mil/Publications/WPI> in a browser
2. Under **Download Publication** click **Complete Volume** — saves `UpdatedPub150.csv`
   (Do **not** use the PDF, MS Access, or Shapefile options — those are archived editions)
3. Save the file anywhere on your machine

For the GeoNames harbour supplement, register a free account and enable free
web services at <https://www.geonames.org/manageaccount>.

**Windows:**
```powershell
# Recommended: WPI + GeoNames
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --user YOUR_USERNAME

# WPI only (no account needed):
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --no-geonames --no-osm

# Add inland marinas for specific countries (OSM, no account needed):
python scripts\fetch_ports.py --wpi-file "C:\path\to\UpdatedPub150.csv" --user YOUR_USERNAME --countries PL,DE,FI,SE,NL
```

**Linux / macOS:**
```bash
python3 scripts/fetch_ports.py --wpi-file "/path/to/UpdatedPub150.csv" --user YOUR_USERNAME
```

If interrupted, re-run with the same arguments — progress is cached in
`scripts/.ports_cache.json` and completed countries are not re-fetched.

`assets/ports.tsv` columns: `name`, `country`, `lat/lon`, `type` (PRT/HBR/MRNA/LDNG/ANCH),
`size`, `vhf`, `phone`, `call_sign`, `wpi_index`, `facilities`, plus 13 navigation detail fields.

---

### Regenerate app icon (optional)

Pre-generated icons are committed to the repo. Regenerate only if you change
`scripts/generate_icon.py`:

```bash
python3 scripts/generate_icon.py   # python on Windows
dart run flutter_launcher_icons
```

---

## Permissions

| Permission | When required | Reason |
|-----------|---------------|--------|
| `ACCESS_FINE_LOCATION` | Always | GPS coordinates and speed |
| `ACCESS_COARSE_LOCATION` | Always | Fallback location |
| `WAKE_LOCK` | Always | Keep screen on |
| `FOREGROUND_SERVICE` | GPS on lock screen | Android API 28+ |
| `FOREGROUND_SERVICE_LOCATION` | GPS on lock screen | Android API 34+ |
| `ACCESS_BACKGROUND_LOCATION` | GPS on lock screen | Android 10+; granted via system prompt at runtime |

All features except *GPS on lock screen* work with only the first three permissions.
The app never uses a network connection.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `geolocator` | GPS position stream + foreground service |
| `flutter_compass` | Magnetic compass heading |
| `get_storage` | Persistent settings and waypoints (pure Dart) |
| `url_launcher` | Open external links in the port detail sheet |

---

## Data sources, licences, and attribution

| Asset | In repo | Licence | Source |
|-------|---------|---------|--------|
| `assets/cities.tsv` | Yes (260 KB) | CC BY 4.0 | GeoNames |
| `assets/cities_precise.tsv` | No (gitignored) | CC BY 4.0 | GeoNames via `fetch_cities.py` |
| `assets/cities_detailed.tsv` | No (gitignored) | CC BY 4.0 | GeoNames via `fetch_cities.py` |
| `assets/ports.tsv` | No (gitignored) | PD + CC BY 4.0 + ODbL* | NGA WPI + GeoNames + OSM via `fetch_ports.py` |
| Source code | Yes | MIT | This project |
| App icon | Yes | MIT | This project |

\* `ports.tsv` is an **ODbL Derived Database** when generated with `--countries` (OSM inland marina
data). Redistributing that file requires making it available under
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1.0/). This does not affect the source code
(MIT) or the compiled APK.

Required attribution (displayed in-app via About & Legal screen):
```
City data: GeoNames (geonames.org), CC BY 4.0
Port data: NGA World Port Index (public domain)
           GeoNames (geonames.org), CC BY 4.0
           © OpenStreetMap contributors (ODbL) — where applicable
```

Full licence text: [LICENSE](LICENSE) · Third-party notices: [NOTICES](NOTICES)

---

## Known limitations

- **Magnetic declination** uses Android's `GeomagneticField` (WMM). Accuracy degrades between
  model update cycles (every 5 years) and at high latitudes.
- **GPS course** is only used above 5.4 km/h. Below that, the magnetic compass is primary and
  is susceptible to nearby metal or magnetic fields (e.g. a car-mount magnet).
- **TRK** requires ~80 m of movement to stabilise after a direction change, and at least two GPS
  fixes to initialise.
- **City and port databases** are static snapshots. Port communication data (VHF channels, phone
  numbers) comes from the NGA WPI; accuracy depends on the publication date.
- Port VHF data is absent for many small marinas — the WPI focuses on commercial ports.
- **Pocket lock** uses brightness + touch-blocking, not a device lock. The screen dims to black
  and touch is disabled, but the keyguard remains in its normal state so biometric unlock works
  immediately when the phone is taken out of the pocket.
