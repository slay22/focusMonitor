# AGENTS.md

macOS menu bar app (Swift, AppKit + SwiftUI + Vision). Webcam head pose → which monitor → focus that screen's front window.

## Build & test

- `./build.sh` compiles with plain `swiftc` and assembles + ad-hoc signs `focusMonitor.app`. **No SwiftPM / Xcode project**:
  SwiftPM is broken in this machine's Command Line Tools (dyld error), and a single file doesn't need it.
- `focusMonitor.app/Contents/MacOS/focusMonitor selftest` runs the `precondition`-based checks (pure logic only).
  Add a line there when touching `nearest`, `Debouncer`, `setupKey` or color storage.
- Compiled with `-swift-version 5` on purpose (avoids Swift 6 strict-concurrency churn for a tiny app).
- To read the app's log from a shell, run the binary on a pty (stdout to a pipe/file is buffered and lost on kill):
  `python3 -c 'import pty,subprocess,time,os; m,s=pty.openpty(); p=subprocess.Popen(["focusMonitor.app/Contents/MacOS/focusMonitor"],stdout=s,stderr=s); time.sleep(5); os.set_blocking(m,False); print(os.read(m,10000).decode()); p.terminate()'`
- In a CLI test harness, `NSWorkspace.frontmostApplication` doesn't update without a run loop. Check with `lsappinfo front` instead.

## Gotchas

- **Signing decides whether permissions survive a rebuild.** `build.sh` signs with the self-signed
  "focusMonitor Self-Signed" identity from `make-cert.sh` (untrusted cert, still fine for codesign and TCC:
  designated requirement = bundle id + cert leaf hash). Without it, ad-hoc signing → new cdhash every build →
  Accessibility silently stops working until the user re-adds the app.
- **Window activation uses private SkyLight `_SLPSSetFrontProcessWithOptions`** (like yabai/AltTab), loaded via `dlsym`.
  Public alternatives were tried and fail: `kAXFrontmostAttribute` brings *all* the app's windows forward (Cmd-Tab
  behavior), and `NSRunningApplication.activate()` is refused for background processes. `GetProcessForPID` is bound
  with `@_silgen_name` because Swift hides it as deprecated. The exact AX window is found via private
  `_AXUIElementGetWindow` (window ID), falling back to frame matching.
- Call pause: `AVCaptureDevice.isInUseByAnotherApplication` is useless (always `false`, even with Photo Booth open).
  Instead, polled every 3 s: CoreAudio per-process `kAudioProcessPropertyIsRunningInput` (any other process on a mic,
  macOS 14.2+) or CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` for any camera except our own. Our own
  camera counts only while `tracker.wantsRunning` is false. Known gap: another app on our camera without a mic.
- Keep awake = `IOPMAssertionDeclareUserActivity` every 3 s while a face was seen recently (shows as `UserIsActive` in
  `pmset -g assertions`). It postpones display sleep/lock by the user's own timeout and does *not* reset
  `CGEventSource.secondsSinceLastEventType`, so the typing/mouse guards are unaffected (checked).
- Head pose, not eye gaze: `VNDetectFaceRectanglesRequest` revision 3 yaw/pitch, nearest calibrated anchor.
- Profiles are keyed by the sorted set of connected `CGDirectDisplayID`s (stable per monitor: vendor/model/serial).
  `~/.focusmonitor.json` is `[setupKey: Profile]`. `loadProfiles()` still reads the old `[Anchor]` format.
- Overlay windows (glow, calibration panel) must not be at window layer 0, or `focusFrontWindow` would pick them.
- Settings live in `UserDefaults` (`local.focusMonitor`): `enabled`, `pauseInCalls`, `keepFocus` / `neverFocus` (comma-separated bundle IDs), `dwell`, `typingGrace`, `mouseGrace`, `margin`, `movePointer`, `camera`, `glow`,
  `glowColor` ("r g b a" sRGB), `glowFade` (effect duration), `glowEffect` (one of `flashEffects`), `welcome`, `welcomeSound`, `keepAwake`, `awakeGrace` (minutes). Defaults are registered at the bottom of `focusMonitor.swift`.

## Style

Keep it small: one source file, no dependencies, no abstractions for single uses. Deliberate shortcuts are marked
`// ponytail:` with their limit and upgrade path.
