# TODO

Ideas, roughly in priority order within each section. ⭐ = high value for little work.

## Accuracy

- [x] **Switch margin**: only switch when the nearest screen is clearly closer than the runner-up.
- [ ] **Learn from clicks**: when you click a window on the screen you're facing, nudge that screen's
  calibration toward your current head pose. This corrects drift from chair or camera moves without recalibrating.
- [ ] **Eye gaze on top of head pose**: use pupil landmarks from `VNDetectFaceLandmarksRequest`, so
  glances with the eyes alone count too, and screens close together become easier to tell apart.
- [ ] **More calibration points** per screen (e.g. corners) for very large or ultrawide monitors.
- [ ] **Which window *within* a screen**: with two windows side by side on one monitor, focus the half you look at.
  Head pose can roughly tell left from right on a wide monitor if calibrated with points per half (see "more
  calibration points"), but finer than that needs real eye gaze (see above).
- [x] **Live "facing: \<screen\>" indicator** in Settings for tuning (pose → screen, without switching).

## Behaviour

- [x] **Move the mouse pointer** to the newly focused screen (optional): today the pointer stays behind.
- [x] **Mouse guard**: don't switch away while the mouse is moving or dragging on the current screen,
  the same way the typing guard works.
- [ ] **Per-app rules**: never take focus away from some apps (screen sharing, fullscreen video, games),
  or never give focus to some (e.g. a monitoring dashboard).
- [ ] **Auto-pause when another app uses the camera** (video calls), or when the screen is locked or asleep.
- [ ] **Sleep/wake and camera unplug**: restart the capture session after wake. When the profile's camera
  disappears, fall back and say so in the log.
- [ ] **Better window match**: raise the exact window by window ID (private `_AXUIElementGetWindow`) instead
  of matching its frame, which picks the wrong one when two windows share the same frame.

## UX

- [x] **Stable code signing** (self-signed certificate + script) so the Accessibility grant survives rebuilds.
- [x] **Launch at login** toggle (`SMAppService.mainApp.register()`).
- [x] **Permission status in Settings** (Camera / Accessibility ✓/✗) + "Open Accessibility Settings…" button.
- [ ] **Configurable pause hotkey** (now fixed at ⌃⌥⌘P).
- [ ] **Profile management** in Settings: list, rename, delete, recalibrate a profile.
- [ ] **Glow options**: thickness, edges only vs. corners, or a small badge instead of a frame.

## Engineering

- [x] **Measure CPU/battery**: ~10 % of one core at 10 detections/s (Apple's face model; our code is negligible),
  ~7.5 % at 5/s, which is now used on battery / Low Power Mode. Smaller frames and a lower camera fps measured no gain.
- [ ] **Further power saving**: sample slowly (1–2/s) while nothing changes and speed up when the head starts turning.
- [ ] **CI**: GitHub Actions builds the app and runs `selftest` on every push.
- [ ] **Releases**: universal binary (arm64 + x86_64), zipped app on GitHub Releases, Homebrew cask.
  Notarization needs a paid Apple Developer ID.
- [ ] **Split `focusMonitor.swift`** once it passes ~800 lines (tracking / focus / UI).

## Porting

The screen-picking logic (`nearest`, `Debouncer`, profiles) is plain Swift. The platform-specific parts are
the camera + face pose and window focusing.

- [ ] **Windows**: Media Foundation camera + MediaPipe / ONNX face mesh for head pose; `SetForegroundWindow`
  has focus-stealing restrictions (needs the `AttachThreadInput` / `AllowSetForegroundWindow` tricks).
  Probably C# or Rust.
- [ ] **Linux**: works on X11 (`_NET_ACTIVE_WINDOW`). Wayland compositors block focus stealing by design,
  so it would need a per-compositor plugin (e.g. a KWin script, a GNOME extension).
