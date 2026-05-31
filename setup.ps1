# QTH Dashboard — one-time project setup
# Run from the qth_helper directory: .\setup.ps1
#
# This script does everything needed to build and run the app.
# Downloading full city / port datasets is intentionally NOT included here —
# that step requires internet access, a GeoNames account, and significant
# time.  See the README for instructions on running fetch_cities.py and
# fetch_ports.py when you are ready.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== QTH Dashboard Setup ===" -ForegroundColor Cyan

# ── 1. Check Flutter ──────────────────────────────────────────────────────────
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host @"

Flutter SDK not found. Install it first:
  https://docs.flutter.dev/get-started/install/windows

After installing, re-run this script.
"@ -ForegroundColor Yellow
    exit 1
}

Write-Host "Flutter found: $(flutter --version --machine 2>$null | ConvertFrom-Json | Select-Object -ExpandProperty frameworkVersion -ErrorAction SilentlyContinue)" -ForegroundColor Green

# ── 2. Flutter packages ────────────────────────────────────────────────────────
Write-Host "`nRunning flutter pub get…" -ForegroundColor Cyan
flutter pub get

# ── 3. Asset stubs (required before the first build, instant, no internet) ────
Write-Host "`nCreating asset stubs…" -ForegroundColor Cyan
python scripts\create_stubs.py

# ── 4. App icon ────────────────────────────────────────────────────────────────
Write-Host "`nGenerating app icon…" -ForegroundColor Cyan
python scripts\generate_icon.py

Write-Host "`nStamping Android launcher icons…" -ForegroundColor Cyan
dart run flutter_launcher_icons

Write-Host @"

=== Setup complete ===

The app is ready to build and run.

Connect your Android device (USB debugging on) or start an emulator, then:

    flutter run

To build a release APK:

    flutter build apk --release
    # Output: build\app\outputs\flutter-apk\app-release.apk

─────────────────────────────────────────────────────────────────────────────
OPTIONAL — Download full data (requires internet access)
─────────────────────────────────────────────────────────────────────────────

The app works out of the box with the built-in top-5 000 city dataset.
For finer city precision and port data, run the fetch scripts manually:

  1. Full city datasets (cities_precise and cities_detailed, ~10 MB):

       python scripts\fetch_cities.py

  2. Port data — requires a free GeoNames account and the NGA WPI CSV.
     See README.md → Step 3 for detailed instructions.

       python scripts\fetch_ports.py --wpi-file "path\to\UpdatedPub150.csv" --user YOUR_USERNAME

The generated files are gitignored; git add . will never accidentally
commit them.

─────────────────────────────────────────────────────────────────────────────

"@ -ForegroundColor Cyan
