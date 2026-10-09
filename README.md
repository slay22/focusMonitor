# focusMonitor

[![CI](https://github.com/slay22/focusMonitor/actions/workflows/ci.yml/badge.svg)](https://github.com/slay22/focusMonitor/actions/workflows/ci.yml)

Look at a monitor, and its front window gets focus.

A macOS menu bar app that uses a webcam (built-in or external) to see which monitor your head is turned
to and focuses the top window on that screen. Answer an email on the left screen, turn back to your
editor on the right, and keep typing. No click or Cmd-Tab needed.

## Features

**Focus that follows your head**
- **Head tracking** with Apple's Vision framework, all on-device. Video never leaves your Mac.
- **Window-level focus**: only the window on the watched screen comes forward. Other windows of the
  same app on other screens stay where they are.
- **Pointer follows** (optional): the mouse pointer jumps back to where it was on the newly focused screen.
- **Focus flash**: a short colored frame on the screen that just got focus, with effects: Fade, Pulse,
  Ripple, Orbit, Dissolve, Explode, Splash, Fireworks or Random (color and duration configurable).

**No accidental switches**
- **Typing & mouse guards**: glancing at another screen while typing or using the mouse doesn't steal focus.
- **Switch margin**: with your head between two screens, nothing switches until it's clear which one you face.
- **Look away freely**: turn to a colleague, look out the window or leave the desk, and focus stays where it was.
- **App rules**: never switch away from some apps (games, presentations), never focus others (dashboards).

**Fits your day**
- **Profiles per monitor setup** (home, office, …). Each set of connected monitors gets its own
  calibration and camera, and the right profile is picked automatically when you plug in.
- **Auto-pause** (camera off): with only one display (laptop-only in a meeting), during calls (another app
  uses the microphone or a camera),
  and while the screen is locked or asleep.
- **Camera recovery**: restarts after sleep, falls back to another camera if yours is unplugged, and
  switches back when it returns.
- **Power aware**: slows down while your head is still or you're away, and analyzes half as often on
  battery or in Low Power Mode.
- **Pause / resume** from the menu or with **⌃⌥⌘P** from anywhere.
- **Keep awake while you're here**: as long as the camera sees you, the screen doesn't dim, sleep or lock,
  even if you're just reading. Once you leave, macOS's normal sleep and lock timers take over (optional grace
  time). Replaces apps like Amphetamine for the "don't lock on me while I'm sitting here" case.
- **Launch at login**.
- 🎆 **Welcome back**: come back after 3+ minutes away (or unlock your Mac) and the screen you face
  greets you with fireworks and their sound (synthesized, no audio files). Both can be turned off.

## Install

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/slay22/focusMonitor.git && cd focusMonitor
./make-cert.sh   # once: self-signed signing identity, so permissions survive rebuilds
./build.sh && open focusMonitor.app
```

On first launch, grant **Camera** and **Accessibility** in System Settings → Privacy & Security.
Settings → Status shows both, with a button to the right pane if one is missing.

> Without `make-cert.sh` the app is ad-hoc signed, and macOS forgets the Accessibility grant after
> every rebuild. To use your own certificate instead: `SIGN_ID="My Cert" ./build.sh`.

## Usage

**Calibration** starts automatically for every new monitor setup. A "👁 Look at this screen" panel appears
on each screen in turn: turn your head toward it and hold still until it moves on. VoiceOver also
reads out which screen is next. Recalibrate from the menu whenever you move the camera or your monitors.

**Menu bar 👁**
- Green eye: tracking. Eye with a slash: paused (the tooltip says why).
- **Watching: \<screen\>**: the screen that has focus right now.
- **Pause Tracking / Resume Tracking** (⌃⌥⌘P), **Recalibrate**, **Settings…**, **Quit**.

**Settings**

| Section | What's there |
|---|---|
| Status | Live **Facing** readout (screen, *between screens*, *looking away* + raw angles), Camera / Accessibility permission, Launch at login |
| Tracking | Camera, switch delay, switch margin, mouse guard, pointer follows, pause during video calls, keep awake (+ grace after leaving), typing guard |
| Glow | On/off, effect, color (with opacity), duration, Preview, welcome-back fireworks (sound, Preview) |
| Calibration | Current monitor setup, Recalibrate |
| App rules | *Never switch away from* / *Never focus* lists |
| Log | Focus switches, status changes, calibration results, warnings |
| About | Version, build commit, GitHub link |

## Tips

- **Camera placement**: anywhere works, since calibration records your head angle per screen *as seen
  from that camera*. A camera in the middle of your monitors is best. With a camera at one side (e.g. the
  laptop's built-in camera with the laptop on the left), the screen farthest away needs a big head turn.
  If it's unreliable, angle the laptop slightly toward the middle.
- **Check a setup** with Settings → Status → **Facing**: look at each screen and see what it reads.
- **⚠️ "… look almost the same to the camera"** in the log means two screens can't be told apart:
  turn your head more during calibration, or move the camera.
- **Focus doesn't switch at all?** Check Settings → Status → Accessibility.
- It follows your **head**, not your eyes: turn your head toward a monitor, don't just glance.

### Replacing Amphetamine (or similar keep-awake apps)

Keep-awake apps hold your Mac awake and unlocked even when you've left. focusMonitor keeps the **screen** on
only while you're at the desk. Once you leave, macOS's normal sleep and lock timers take over. Add these
for the rest:

- **Agents keep working while you're away.** The screen locks, but a locked Mac still runs everything.
  The Mac only has to be kept from *sleeping*:
  - **Claude Code** does that on its own while it works.
  - **Codex**: turn on the experimental option "Prevent sleep while running" (`/experimental`, or
    `prevent_idle_sleep = true` under `[features]` in `~/.codex/config.toml`).
  - **Anything else** (pi, opencode, gemini, long builds): start it with macOS's `caffeinate -i`, e.g. in
    `~/.zshrc`:
    ```sh
    alias pi='caffeinate -i pi'
    ```
    The Mac stays awake while the command is open (even idle), and normal sleep returns when you quit it.
  - Check who's keeping the Mac awake with `pmset -g assertions`.
- **Closing the lid** sleeps the Mac no matter what, *unless* it's on power with an external display
  connected (clamshell mode). Your desk setup keeps running, a laptop in a bag doesn't. Agents resume
  when you open the lid; a request in flight may need a retry.
- **Back in without typing your password**: unlock with Apple Watch (System Settings → Touch ID &
  Password) or Touch ID. Or set Lock Screen → "Require password after …" to a few minutes, so short
  breaks wake straight to the desktop.
- **Short breaks without the screen sleeping**: use the *…and after I leave for* slider next to
  *Keep the Mac awake while I'm at the desk* in Settings.

## How it works

1. Vision detects your face and its yaw and pitch (where your head points): ~7×/s while you move,
   ~2.5×/s while you're still or away, half that on battery.
2. The nearest calibrated screen wins if it's clearly closer than the runner-up (switch margin) and
   within ~29° (otherwise you're looking away). Typing, mouse use and app rules can hold focus.
3. Once you've faced the new screen for the switch delay (default 0.6 s), its topmost normal window is
   raised and activated, the way a click would.

CPU: ~5–9 % of one core while tracking (most of it is the camera feed itself), 0 % when paused.
Profiles and calibration live in `~/.focusmonitor.json`, settings in the `local.focusMonitor` defaults.

## Development

Everything is in `focusMonitor.swift`. `icon.swift` draws the app icon (delete `AppIcon.icns` to regenerate).

```sh
./build.sh
focusMonitor.app/Contents/MacOS/focusMonitor selftest
```

CI builds and runs the self-test on every push. Ideas and plans are in [TODO.md](TODO.md); see
[AGENTS.md](AGENTS.md) for the non-obvious parts.
