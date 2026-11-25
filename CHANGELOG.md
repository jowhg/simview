# Changelog

## 0.2.0 — 2026-11-25

**App**

- Scroll with the trackpad (two fingers) or a mouse wheel while the pointer is over a device's screen: it drags a
  finger on the device, content follows your fingers, and iOS adds its own momentum when you lift them.
  Horizontal scrolling works too; the device row still scrolls from the bezels and the gaps between devices.

## 0.1.0 — 2026-11-23

First public release.

**App**

- Every booted iOS simulator live in one window, side by side, inside Xcode's device bezels, with touch,
  keyboard and hardware buttons.
- Full height and Fit all layouts; drag a bezel to resize its device.
- Detachable device windows, optionally kept above every other app (full-screen ones included).
- Rotation (⌘← / ⌘→) and light / dark appearance toggle (⇧⌘A).
- Drag and drop onto a device: `.app` and simulator `.ipa` files are installed and opened, photos and videos go
  to Photos.
- Screenshots and screen recordings, with a captures panel.
- Two-way clipboard sync between the Mac and the devices.
- Simulators slimmed down as they boot with simslim (about 4× less memory), on by default.
- Sidebar grouped by device family (iPhone, iPad…), with simulators that can't boot set apart.
- English and French.

**MCP server**

- `simview-mcp`: 40 tools to see and drive the simulators (screenshots, touch, keys, apps, environment,
  clipboard, logs). Shipped inside the app and linked onto the `PATH` by the Homebrew cask.
