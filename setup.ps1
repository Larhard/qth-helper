# QTH Helper — one-time project setup
# Run from the qth_helper directory: .\setup.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== QTH Helper Setup ===" -ForegroundColor Cyan

# 1. Check Flutter
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host @"

Flutter SDK not found. Install it first:
  https://docs.flutter.dev/get-started/install/windows

After installing, re-run this script.
"@ -ForegroundColor Yellow
    exit 1
}

Write-Host "Flutter found: $(flutter --version --machine 2>$null | ConvertFrom-Json | Select-Object -ExpandProperty frameworkVersion -ErrorAction SilentlyContinue)" -ForegroundColor Green

# 2. Scaffold Flutter project if not already done
if (-not (Test-Path 'android\gradle\wrapper\gradle-wrapper.properties')) {
    Write-Host "`nRunning flutter create to generate Android boilerplate…" -ForegroundColor Cyan
    # --project-name must be snake_case and match pubspec.yaml name
    flutter create --project-name qth_helper --org com.example --platforms android .
    Write-Host "Flutter project created." -ForegroundColor Green

    # Restore our AndroidManifest (flutter create overwrites it)
    Write-Host "Restoring AndroidManifest.xml with location permissions…" -ForegroundColor Cyan
    $manifestPath = 'android\app\src\main\AndroidManifest.xml'
    # The file we wrote already has the correct permissions; flutter create replaced it, so re-apply
    # Check if our permissions are present; if not, patch them in
    $manifest = Get-Content $manifestPath -Raw
    if ($manifest -notmatch 'ACCESS_FINE_LOCATION') {
        $permissions = @'
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
'@
        $manifest = $manifest -replace '(<manifest[^>]*>)', "`$1`n$permissions"
        Set-Content $manifestPath $manifest -Encoding UTF8
        Write-Host "Permissions patched into AndroidManifest.xml." -ForegroundColor Green
    } else {
        Write-Host "Permissions already present." -ForegroundColor Green
    }
} else {
    Write-Host "Flutter project already initialised." -ForegroundColor Green
}

# 3. Fetch city data
if (-not (Test-Path 'assets\cities.tsv')) {
    Write-Host "`nFetching cities data (one-time, ~2 MB download)…" -ForegroundColor Cyan
    python scripts\fetch_cities.py
} else {
    $lines = (Get-Content 'assets\cities.tsv' | Measure-Object -Line).Lines
    Write-Host "cities.tsv already present ($($lines - 1) cities)." -ForegroundColor Green
}

# 4. Install Flutter packages
Write-Host "`nRunning flutter pub get…" -ForegroundColor Cyan
flutter pub get

Write-Host @"

=== Setup complete ===

Connect your Android device (USB debugging on) or start an emulator, then:

    flutter run

To build a release APK:

    flutter build apk --release
    # Output: build\app\outputs\flutter-apk\app-release.apk

"@ -ForegroundColor Cyan
