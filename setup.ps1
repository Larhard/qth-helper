# QTH Dashboard -- one-time project setup
# Run from the qth_helper directory: .\setup.ps1
#
# This script does everything needed to build and run the app.
# Downloading full city / port datasets is intentionally NOT included here --
# that step requires internet access, a GeoNames account, and significant
# time.  See the README for instructions on running fetch_cities.py and
# fetch_ports.py when you are ready.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sep = '-' * 77

Write-Host ""
Write-Host "=== QTH Dashboard Setup ===" -ForegroundColor Cyan

# -- 1. Check Flutter ---------------------------------------------------------
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Flutter SDK not found. Install it first:" -ForegroundColor Yellow
    Write-Host "  https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "After installing, re-run this script." -ForegroundColor Yellow
    exit 1
}

$fver = flutter --version --machine 2>$null |
        ConvertFrom-Json |
        Select-Object -ExpandProperty frameworkVersion -ErrorAction SilentlyContinue
Write-Host "Flutter found: $fver" -ForegroundColor Green

# -- 2. Flutter packages ------------------------------------------------------
Write-Host ""
Write-Host "Running flutter pub get..." -ForegroundColor Cyan
flutter pub get

# -- 3. Asset stubs (required before first build, instant, no internet) -------
Write-Host ""
Write-Host "Creating asset stubs..." -ForegroundColor Cyan
python scripts\create_stubs.py

# -- 4. App icon --------------------------------------------------------------
Write-Host ""
Write-Host "Generating app icon..." -ForegroundColor Cyan
python scripts\generate_icon.py

Write-Host ""
Write-Host "Stamping Android launcher icons..." -ForegroundColor Cyan
dart run flutter_launcher_icons

# -- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "The app is ready to build and run." -ForegroundColor Cyan
Write-Host ""
Write-Host "Connect your Android device (USB debugging on) or start an emulator, then:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    flutter run" -ForegroundColor White
Write-Host ""
Write-Host "To build a release APK:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    flutter build apk --release" -ForegroundColor White
Write-Host "    # Output: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor DarkGray
Write-Host ""
Write-Host $sep -ForegroundColor DarkGray
Write-Host "OPTIONAL -- Download full data (requires internet access)" -ForegroundColor Cyan
Write-Host $sep -ForegroundColor DarkGray
Write-Host ""
Write-Host "The app works out of the box with the built-in top-5000 city dataset." -ForegroundColor Cyan
Write-Host "For finer city precision and port data, run the fetch scripts manually:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Full city datasets (cities_precise and cities_detailed, ~10 MB):" -ForegroundColor White
Write-Host ""
Write-Host "       python scripts\fetch_cities.py" -ForegroundColor White
Write-Host ""
Write-Host "  2. Port data -- requires a free GeoNames account and the NGA WPI CSV." -ForegroundColor White
Write-Host "     See README.md -> Step 3 for detailed instructions." -ForegroundColor White
Write-Host ""
Write-Host "       python scripts\fetch_ports.py --wpi-file `"path\to\UpdatedPub150.csv`" --user YOUR_USERNAME" -ForegroundColor White
Write-Host ""
Write-Host "The generated files are gitignored; git add . will never accidentally" -ForegroundColor DarkGray
Write-Host "commit them." -ForegroundColor DarkGray
Write-Host ""
Write-Host $sep -ForegroundColor DarkGray
Write-Host ""
