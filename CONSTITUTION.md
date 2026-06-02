# QTH Dashboard — Project Constitution

> **Vibe-coded.** This project was built interactively with AI assistance.
> No formal testing, safety audit, or regulatory review has been performed.
> Never rely on this app as your sole means of navigation.

---

## 1. Project Vision

QTH Dashboard is a high-reliability Android navigation dashboard for people who
need precise, glanceable positional awareness in demanding conditions — aboard a
vessel at night, on a mountain summit with wet gloves, driving in an emergency,
or operating in the field as the last radio link.

The design philosophy can be summarised in three words: **fast, safe, honest**.

* **Fast** — every critical value is readable in under one second without
  interaction. No menus before the bearing to your MOB waypoint.
* **Safe** — the night mode never emits blue or green light that destroys
  night-adapted vision. The interface is operable one-handed in rough conditions.
  No feature that could cause a driver to look away from the road for more than
  a glance is accessible while driving.
* **Honest** — the heading display shows `---` rather than a plausible-looking
  MAG reading when the user is in GPS/TRK mode and data has not yet arrived.
  Alarms are as loud and disturbing as the hardware permits regardless of
  silent/mute/DND settings.

---

## 2. Use Cases

### 2.1 Ham Radio (SOTA · POTA · IOTA · EMCOM)

| Need | Feature |
|---|---|
| Grid-square for logging | IARU/Maidenhead 8-char display, live |
| Bearing and distance to designated spot | Waypoint navigation card |
| Emergency locator for rescue relay | MOB one-tap, coordinatesinstantly visible |
| Night operating with red-only lighting | Night mode (pure red palette) |
| Battery saving on summit | Screen-off GPS pause; compass/timer halt |
| EMCOM rendezvous at grid | Named waypoints, GPX import/export |

EMCOM deployments often rely on the phone as the only navigation device.
All critical data (coordinates, locator, bearing, distance) must be visible
simultaneously on a single screen without scrolling.

### 2.2 Marine / Sailing

| Need | Feature |
|---|---|
| Night watch — no white light | Night mode: only wavelengths >600 nm |
| Port/VHF data | Port mode city layer with VHF channel |
| Bearing/distance to anchorage | Waypoint card with relative ring |
| Anchor dragging alarm | Anchor alarm with two levels + GPS-loss escalation |
| MOB at sea | Instant MOB button, always visible at bottom |
| Pocket the phone safely | Proximity-based screen dim with charger bypass |
| Wake from lock on alarm | Screen wake-lock + `setShowWhenLocked` |

Night-sailing imposes a hard rule: **no white, green, blue, or amber at any
brightness**. The night palette is a single red hue family varying only in
brightness — exactly as the rod cells at the edge of the retina respond to
long-wavelength light without losing dark adaptation.

**Anchor alarm requirements:**
- Level 1 (Warning): gentle double vibration + audible beep, every ~8 s.
  Sounds at any volume level including silent mode.
- Level 2 (Alarm): maximum-volume dissonant siren, continuous vibration,
  flashlight strobe, full-screen blink. Sounds regardless of mute/DND/lock state.
- GPS loss: 60 s → Level 1, 180 s → Level 2. Stationary GPS keep-alive every 20 s.

### 2.3 Driving (including Emergency Services)

**Prime directive: the driver must never be distracted.**

Rules enforced by the design:
- The anchor alarm setup requires long-press in the Waypoints screen — it cannot
  be triggered while a thumb is resting on the main screen.
- No setup dialogs are surfaced from the primary navigation display.
- MOB tapping is intentional (single tap), but the 3-second clear hold prevents
  accidental clear while driving.
- Font hierarchy ensures heading, speed, and coordinates are readable at a glance
  without head movement.
- Wind-rose and arrow mode both work at a glance without reading a label.

In driving use the heading source auto-switches: GPS at ≥5.4 km/h, TRK while
in motion below that threshold, and — **critically** — shows `---` with TRK
colour before any track data exists, never silently using MAG.

### 2.4 Hiking (battery saving · rugged)

- GPS stream is **cancelled** when the screen turns off (SAVE mode, default).
- Compass, stale timer, city lookups are **paused** on screen-off.
- GPS-on-lock mode allows optional background GPS (foreground service) for
  real-time tracking, with explicit user opt-in.
- Proximity sensor pocket lock prevents accidental button presses when the phone
  is stored without activating the keyguard (biometrics still work instantly).
- 0.5° compass threshold gate: no unnecessary redraws when standing still.
- City lookup threshold: 100 m movement before recalculating.
- All timers resume within one frame of screen-on; no stale data.

---

## 3. Supported Resolutions & Layout Rules

### Mandatory resolutions

| Device | Resolution | Logical pixels (approx) |
|---|---|---|
| Ulefone Armor Mini 20T Pro | 720 × 1600 px | 360 × 800 dp |
| Google Pixel 6a | 1080 × 2400 px | 411 × 914 dp |

Both portrait and landscape orientations must be supported at both resolutions.

### Layout rules

1. **Nothing cropped** — every visible widget must be fully within the safe area.
   Long city/port names (e.g. "Akademicki Związek Sportowy Kraków") must never
   clip; they shrink via `_fitFontSize()` instead.
2. **MOB always at bottom** — in both orientations the MOB button or card is
   pinned to the bottom of its column and never scrolled out of view.
3. **Primary dashboard always fits without scrolling** — heading, speed,
   coordinates, locator, time, and city are always simultaneously visible in
   portrait mode on the smallest mandatory screen.
4. **Anchor mode priority** — when anchoring, heading section + anchor card +
   MOB are always fully visible. City collapses to a compact one-liner.
   Nav waypoint shows as a compact bearing row.
5. **Font hierarchy** — the largest text (heading degrees) is always largest.
   Speed, coordinates, locator, time are secondary. Labels/metadata are tertiary.
6. **Dynamic font sizing** — `_fitFontSize()` uses TextPainter measurement to
   find the largest font that fits in `maxLines` lines. Never hard-clips text.
7. **Landscape compact sizes** — all landscape card sizes are noticeably smaller
   than portrait to fit within ~300 dp landscape height after safe area.

---

## 4. Colour System

### Philosophy

The app uses a single shared colour palette defined entirely in
`lib/utils/units.dart`. **No raw hex literals are permitted anywhere else in
the codebase.** All colours are referenced by their semantic constant name.

This ensures that:
- A single edit to one constant propagates to every screen instantly.
- Night mode is provably grey-free — all night constants share hue ≈ 0° (pure red).
- Day mode has semantic meaning (green = GPS, amber = MGRS, cyan = port, etc.).

### Night palette (`kN*`) — pure red family

All night constants share H ≈ 0° (pure red). Brightness is the only axis.

| Constant | Value | Semantic role |
|---|---|---|
| `kN0` | `#FF3333` | Emergency / North indicator arc / brightest accent |
| `kN1` | `#CC1111` | Primary text, active icon |
| `kN2` | `#9A1111` | Secondary text, sub-label |
| `kN3` | `#771111` | Metadata, captions |
| `kN4` | `#4A1111` | Hints, disabled, very dim |
| `kNBg` | `#1A0000` | Tile / card background |
| `kNDiv` | `#250505` | Dividers, borders |
| `kNSheet` | `#0A0000` | Modal / bottom-sheet background |

**Night mode rules:**
- No white, grey, blue, green, amber, or cyan.
- No splash/highlight/tooltip in any non-red colour.
- Screen strobe during anchor alarm alternates black ↔ red (`kN0`).
- Snackbars: `kNBg` background, `kN2` text.
- Tooltips: `kNBg` background, `kN1` text.

### Day palette (`kD*`) — semantic colours

| Group | Constants | Semantic role |
|---|---|---|
| Text | `kDFg0–kDFg4` | White → dark-grey scale |
| GPS / heading | `kDGps`, `kDGpsL`, `kDTrk` | Green (GPS), yellow (TRK) |
| Emergency / MOB | `kDEmg`, `kDEmgS`, `kDEmgBg` | Red family |
| Stale / warning | `kDStale` | Orange-red |
| Nav waypoint | `kDNav`, `kDNavL` | Deep orange |
| MGRS / amber | `kDAmb`, `kDAmbs` | Amber-orange family |
| City tiers | `kDCityL`, `kDCityP`, `kDCityD`, `kDCityDS` | Orange → lime |
| Port / cyan | `kDPort`, `kDPortL` | Cyan |
| UI chrome | `kDDiv`, `kDBrd`, `kDFoc`, `kDSheetBg`, `kDSnackBg` | Dark surfaces |
| Animation rings | `kDEmgRing`, `kDEmgRingDim`, `kNEmgRing`, `kNEmgRingDim`, `kDEmgArc`, `kNEmgArc` | Hold-to-clear animation |
| Debug precision | `kDGpsM6`, `kDGpsM4` | Maidenhead tier colours |

**Day mode rules:**
- All text must be readable in direct sunlight on a 720×1600 phone.
- Contrast ratio ≥ 4.5:1 for primary text against black background.
- Tooltips: `kDSnackBg` background, `kDFg1` text.

### Theme-level colours (dynamic, in `main.dart`)

`QthHelperApp` is a `StatefulWidget` that listens to `GetStorage('day_mode')`
and rebuilds the `MaterialApp` theme on every day↔night toggle. This ensures
tooltips, ripples, and tab bars always use the correct palette regardless of
Material 3 surface-tint defaults.

---

## 5. Coding Practices

### 5.1 General

- **Flutter 3.x / Dart 3.x** for all UI and business logic.
- **Kotlin** for Android-only hardware features (vibration, audio, flashlight,
  wake lock, proximity sensor, GNSS status).
- **Pure Dart** service classes for platform-independent logic (waypoints, cities,
  anchor state). No Android SDK references outside `*.kt` files and MethodChannels.
- All `MethodChannel` / `EventChannel` identifiers follow the format
  `qth_helper/<feature>` (e.g. `qth_helper/anchor_alarm`).

### 5.2 No raw colour literals

```dart
// ✓ correct
color: _dayMode ? kDGps : kN1,

// ✗ wrong — breaks the unified palette
color: const Color(0xFF55DD55),
```

The only exception is `Colors.black`, `Colors.transparent`, `Colors.white38`
(form hint opacity), and structural dark surfaces (`Colors.black` for Scaffold
backgrounds) where semantic naming would be redundant.

### 5.3 No unnecessary abstractions

Three similar lines are better than a premature abstraction. Do not extract a
helper unless it is called from ≥ 3 distinct locations or contains non-trivial
logic that would be tested independently.

### 5.4 No silent fallbacks that mislead the user

If GPS/TRK data is unavailable in auto mode, the heading display shows `---`
with the correct source colour. It never silently falls back to MAG and pretends
GPS is active.

### 5.5 Battery budget

When the screen is off:
- GPS stream **cancelled** (SAVE mode) or foreground-service (LIVE mode, explicit opt-in).
- Compass stream **paused**.
- Stale timer **cancelled**.
- City calculations **skipped**.
- No `setState` calls from any background path.

When the screen turns on, all streams resume within one frame.

New features must not add any background CPU, sensor, or network work unless the
user has explicitly opted in (e.g. anchor mode GPS keep-alive is only active when
the anchor is deployed).

### 5.6 Screen-size safety

Every new widget that displays dynamic text must either:
(a) use `_fitFontSize()` to auto-scale, or
(b) use `overflow: TextOverflow.ellipsis`, or
(c) be wrapped in a `Flexible`/`Expanded` that prevents unconstrained growth.

Static layout testing against both mandatory resolutions (360×800 dp and
411×914 dp) in portrait and landscape is required before merging any layout
change.

### 5.7 XML and structured data

Never use regex to parse XML or any structured format. Use the `xml` package
(`XmlDocument.parse()`) for GPX import/export. Entity references, CDATA sections,
comments, and namespaces are handled correctly only by a proper parser.

### 5.8 Anti-misclick for safety-critical actions

Any action that:
- Activates an alarm system (anchor alarm)
- Clears a safety marker (MOB)
- Changes GPS mode

must require a deliberate gesture (long-press or 3-second hold) that cannot
be triggered by casual contact with the screen during driving or sailing.

---

## 6. Module Structure

```
lib/
├── main.dart                    # App root; stateful theme (day/night aware)
├── models/
│   ├── city.dart                # City + port data model (immutable fields)
│   └── waypoint.dart            # Waypoint (mutable name/lat/lon, persistent ID)
├── screens/
│   ├── home_screen.dart         # Primary dashboard (~2 800 lines)
│   ├── waypoints_screen.dart    # Waypoint list + GPX import/export + anchor setup
│   ├── about_screen.dart        # Legal notices + open-source licences
│   └── debug_screen.dart        # 4-tab sensor/GPS/heading/locator debug view
├── services/
│   ├── anchor_service.dart      # Anchor state, radius checking, GPS-loss escalation
│   ├── city_service.dart        # Spatial grid lookup (city and port datasets)
│   ├── declination_service.dart # WMM magnetic declination via Android GeomagneticField
│   ├── environment_service.dart # EventChannel wrapper for sensor stream
│   └── waypoint_service.dart    # MOB + nav waypoints; GPX import with dedup + undo
└── utils/
    ├── coordinate_utils.dart    # DDM / DD / DMS + Maidenhead encode/decode
    ├── geo_utils.dart           # Haversine distance + bearing
    ├── gpx_utils.dart           # GPX 1.1 parse (xml package) + build (XmlBuilder)
    ├── mgrs_utils.dart          # MGRS encode/decode
    ├── track_bearing.dart       # Smoothed track bearing from spatial point buffer
    └── units.dart               # ALL colour constants (kD*/kN*) + unit preferences
```

### Module boundaries

| Module | May depend on | Must not depend on |
|---|---|---|
| `models/` | Dart core only | Services, screens, widgets |
| `utils/` | Dart core, `xml` package | Services, models, screens |
| `services/` | `models/`, `utils/`, `flutter/services` | Screens, widgets |
| `screens/` | All of the above | Nothing outside `lib/` |

Services are plain Dart singletons with no Flutter widget dependencies. Screens
are the only layer that touches `BuildContext`, `setState`, and `Navigator`.

---

## 7. Alarm & Safety Systems

### 7.1 Anchor alarm guarantee

The anchor alarm must produce audible output in all of the following states:
- Phone muted / silent mode
- Do Not Disturb active
- Screen locked
- Screen on with another app in focus
- Volume at 0

Implementation: `AudioTrack` on `STREAM_ALARM` with `AudioAttributes.USAGE_ALARM`.
Before starting, set `AudioManager.setStreamVolume(STREAM_ALARM, max, 0)` and
request `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE`. The `USAGE_ALARM` attribute bypasses
DND at the "Priority Only" level on all modern Android versions without additional
permissions. Total-silence DND bypass requires `ACCESS_NOTIFICATION_POLICY`
(requested optionally; alarm still sounds in priority-only mode without it).

### 7.2 Alarm audio design

- **Level 1 (Warning):** 523 Hz + 784 Hz (perfect 5th) alternating, 50 % duty cycle,
  soft amplitude. Urgent but not panic-inducing. Every 8 s.
- **Level 2 (Alarm):** Synthesised siren sweep 400–1200 Hz with second harmonic at
  2× frequency shifted 90°. Creates dissonance and urgency. Continuous, looping.
  Volume at absolute maximum of `STREAM_ALARM`.
- Both levels use `AudioTrack` with looping PCM data — no `ToneGenerator` (unreliable
  when other audio focus is active, skips when screen is on).

### 7.3 GPS keep-alive when stationary

Android GPS receivers can stop delivering updates when the device is stationary.
When the anchor alarm is active, the stale timer calls `_requestImmediateGpsFix()`
every 20 s if no position update has been received. This wakes the GNSS receiver
and delivers a fresh fix without continuous power drain.

---

## 8. Version history note

The app started as a proof-of-concept GPS heading display and grew iteratively
through field testing into a full maritime/radio/hiking dashboard. The architecture
reflects this history — `home_screen.dart` is intentionally large because it
manages a unified state machine for all navigation sensors. Future refactoring
should extract `_HomeScreenState` sub-concerns (city, anchor, waypoint sections)
into `StatefulWidget` subtrees before splitting into separate files.
