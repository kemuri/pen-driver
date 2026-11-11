# wdrive

A minimal, native macOS driver for Wacom and XP-Pen tablets: area mapping across one or more
displays, click guard (tap stability), and pen button mapping. Written as a low-latency
replacement for OpenTabletDriver, whose cursor lags when the system is under heavy load.

## Install

Download the latest `wdrive-<version>.dmg` from
[Releases](https://github.com/kemuri/pen-driver/releases), open it and drag wdrive to
Applications. It's signed with a Developer ID and notarized by Apple.

## Build

    ./build.sh             # → build/wdrive.app, installed to /Applications (a running copy restarts from there)
    ./build.sh --no-install
    swift test             # descriptor parser, mapping, click guard, display snapping

Requires macOS 15+ and Xcode. `build.sh` signs with your Developer ID / Apple Development
certificate if one is installed (a stable signature keeps the permission grants across
rebuilds), otherwise ad-hoc. Set `WDRIVE_IDENTITY` to choose one.

## Release

    Scripts/release.sh                # → build/wdrive-<version>.dmg, notarized and stapled
    Scripts/release.sh --publish      # also creates a draft GitHub release v<version> with it
    Scripts/release.sh --no-notarize  # just build and package, to check locally

The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`. The build is
universal (Apple silicon and Intel), signed with Developer ID and the hardened runtime. Store
notarization credentials once with
`xcrun notarytool store-credentials wdrive --apple-id <apple-id> --team-id <team-id>`
(set `WDRIVE_NOTARY_PROFILE` to use another profile name).

On first launch, allow **Input Monitoring** (to read the tablet) and **Accessibility** (to move
the pointer). If OpenTabletDriver is running, quit it (the settings window offers a button). Existing
OpenTabletDriver settings (buttons, tip threshold, left-handed, display) are imported on first run.

## Features

- **Mapping:** map to the main display, any single display, or all displays. One preview shows
  the tablet with its active area, the mapped displays inside it and the live pen position. When
  mapping to all displays, "Arrange…" lets you drag displays to set how the tablet spans them;
  this doesn't touch the macOS arrangement.
- **Keep proportions:** the active area takes the screens' shape so circles stay round. The free
  and proportional areas are remembered separately, so switching back restores your old area.
- **Click guard:** after touchdown the pointer stays put until the pen clearly moves (measured in
  millimetres on the tablet, so it holds on large screens), so taps don't turn into tiny drags;
  the second tap of a double-click lands on the first.
- **Screen edges:** past the edge of the area the pointer rests on the screen edge, ignoring hover
  jitter, so a hidden Dock and hot corners work as with a mouse.
- **Modifier keys** (⌘-click, ⇧-click, ⌥-drag) are read from the keyboard itself.
- **Pen buttons, eraser, tip pressure threshold**, left-handed (rotated 180°) use.
- **Mouse or tablet mode:** mouse mode (the default) sends plain mouse events. Tablet mode adds
  pressure and tilt to them and tells apps when the pen or its eraser end comes near, so drawing
  apps can use them.
- Lives in the menu bar (can be hidden; open the app again to get the settings window).

## How it works

- Tablets are matched by vendor ID (Wacom 056a, XP-Pen 28bd). The pen report layout is read from
  the device's own HID report descriptor, so there are no per-model tables. Wacom's vendor page
  0xFF0D is mapped onto the standard digitizer page, the same mapping Linux uses.
- The pen interface is opened exclusively, so macOS doesn't also drive the pointer from it.
- A single thread with a real-time (time-constraint) scheduling policy receives each report from
  IOKit, decodes it, runs the click guard and posts the CGEvent inline. No queues or thread hops,
  so system load doesn't add latency the way it does for normal-priority threads.
- `Sources/PenCore` is pure, unit-tested logic (parser, mapping, click guard, display snapping);
  `Sources/wdrive` is the HID/CGEvent layer and the SwiftUI settings window.

## Status

Developed and tested against a Wacom Intuos Pro M (PTH-660). XP-Pen support follows the standard
HID digitizer descriptor but hasn't been tested on hardware yet; reports welcome.

## Diagnostics

    "build/wdrive.app/Contents/MacOS/wdrive" --list-tablets
    "build/wdrive.app/Contents/MacOS/wdrive" --snapshot out.png [--terrain] [--page mapping|settings] [--dark]
    "build/wdrive.app/Contents/MacOS/wdrive" --snapshot out.png --classic [--tab mapping|general|about] [--dark]
    "build/wdrive.app/Contents/MacOS/wdrive" --snapshot out.png --tuning terrain|dots [--dark]
