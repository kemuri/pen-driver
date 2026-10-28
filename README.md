# Pen Driver

A minimal, native macOS driver for Wacom and XP-Pen tablets: area mapping across one or more
displays, click guard (tap stability), and pen button mapping. Written as a low-latency
replacement for OpenTabletDriver, whose cursor lags when the system is under heavy load.

## Build

    ./build.sh             # → build/Pen Driver.app
    ./build.sh --install   # also installs it to /Applications and quits the running copy
    swift test             # descriptor parser, mapping, click guard, display snapping

Requires macOS 15+ and Xcode. `build.sh` signs with your Developer ID / Apple Development
certificate if one is installed (a stable signature keeps the permission grants across
rebuilds), otherwise ad-hoc. Set `PEN_DRIVER_IDENTITY` to choose one.

On first launch, allow **Input Monitoring** (to read the tablet) and **Accessibility** (to move
the pointer). If OpenTabletDriver is running, quit it (the Tablet pane offers a button). Existing
OpenTabletDriver settings (buttons, tip threshold, left-handed, display) are imported on first run.

## Features

- **Mapping:** map to the main display, any single display, or all displays. The screen preview
  shows your displays at their real proportions with the live pen position. Drag displays to
  arrange how the tablet spans them; this doesn't touch the macOS arrangement. The tablet preview
  draws the mapped displays inside the active area.
- **Keep proportions:** the active area takes the screens' shape so circles stay round. The free
  and proportional areas are remembered separately, so switching back restores your old area.
- **Click guard:** after touchdown the pointer stays put until the pen clearly moves, so taps
  don't turn into tiny drags; the second tap of a double-click lands on the first.
- **Pen buttons, eraser, tip pressure threshold**, left-handed (rotated 180°) use.
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
  `Sources/PenDriver` is the HID/CGEvent layer and the SwiftUI settings window.

## Status

Developed and tested against a Wacom Intuos Pro M (PTH-660). XP-Pen support follows the standard
HID digitizer descriptor but hasn't been tested on hardware yet; reports welcome.

## Diagnostics

    "build/Pen Driver.app/Contents/MacOS/PenDriver" --list-tablets
    "build/Pen Driver.app/Contents/MacOS/PenDriver" --snapshot out.png --pane mapping [--dark]
