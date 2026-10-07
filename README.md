# focusMonitor

Look at a monitor, and its front window gets focus.

A macOS menu bar app that uses a webcam (built-in or external) to see which monitor your head is turned
to and focuses the top window on that screen. Answer an email on the left screen, turn back to your
editor on the right, and keep typing. No click or Cmd-Tab needed.

## Features

- **Head tracking** with Apple's Vision framework, all on-device. Video never leaves your Mac.
- **Window-level focus**: only the window on the watched screen comes forward. Other windows of the
  same app on other screens stay where they are.
- **Typing & mouse guards**: glancing at another screen while typing, or while using the mouse, doesn't steal focus.
- **Switch margin**: with your head between two screens, nothing switches until it's clear which one you face.
- **Pointer follows** (optional): the mouse pointer jumps to where it was on the newly focused screen.
- **Battery aware**: analyzes half as often on battery or in Low Power Mode.
- **Profiles per monitor setup** (home, office, …). Each set of connected monitors gets its own
  calibration and camera, and the right profile is picked automatically when you plug in.
- **Auto-pause** (camera off) when only one display is connected, e.g. laptop-only in a meeting.
- **Pause / resume** from the menu or with **⌃⌥⌘P** from anywhere.
- **Focus glow**: a short colored frame on the screen that just got focus (color and fade configurable).
- **Settings**: camera, switch delay, typing pause, glow, recalibration, live log.

## Install

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh && open focusMonitor.app
```

On first launch, grant **Camera** and **Accessibility** in System Settings → Privacy & Security.
Calibration starts automatically: look at each screen as the 👁 panel appears on it.

> The app is ad-hoc signed, so macOS forgets the Accessibility grant after every rebuild:
> remove focusMonitor from the list and add it again. To avoid this, sign with a stable certificate:
> `SIGN_ID="My Cert" ./build.sh`.

## How it works

1. About 10×/s, Vision detects your face and its yaw and pitch (where your head is pointing).
2. The closest calibrated screen wins once you've faced it for the switch delay (default 0.6 s).
3. The topmost normal window on that screen is raised and activated, the way a click would.

It follows your **head**, not your eyes: turn your head toward a monitor, don't just glance.
Calibration lives in `~/.focusmonitor.json`.

## Development

Everything is in `focusMonitor.swift`. `icon.swift` draws the app icon (delete `AppIcon.icns` to regenerate).

```sh
./build.sh
focusMonitor.app/Contents/MacOS/focusMonitor selftest
```

See [AGENTS.md](AGENTS.md) for the non-obvious parts.
