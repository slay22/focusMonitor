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

- **Accessibility permission resets on every rebuild** (ad-hoc signature → new cdhash). Focus switching and the
  ⌃⌥⌘P hotkey silently stop working until the user re-adds the app. Tell the user after rebuilding.
- **Window activation uses private SkyLight `_SLPSSetFrontProcessWithOptions`** (like yabai/AltTab), loaded via `dlsym`.
  Public alternatives were tried and fail: `kAXFrontmostAttribute` brings *all* the app's windows forward (Cmd-Tab
  behavior), and `NSRunningApplication.activate()` is refused for background processes. `GetProcessForPID` is bound
  with `@_silgen_name` because Swift hides it as deprecated.
- Head pose, not eye gaze: `VNDetectFaceRectanglesRequest` revision 3 yaw/pitch, nearest calibrated anchor.
- Profiles are keyed by the sorted set of connected `CGDirectDisplayID`s (stable per monitor: vendor/model/serial).
  `~/.focusmonitor.json` is `[setupKey: Profile]`. `loadProfiles()` still reads the old `[Anchor]` format.
- Overlay windows (glow, calibration panel) must not be at window layer 0, or `focusFrontWindow` would pick them.
- Settings live in `UserDefaults` (`local.focusMonitor`): `enabled`, `dwell`, `typingGrace`, `mouseGrace`, `margin`, `movePointer`, `camera`, `glow`,
  `glowColor` ("r g b a" sRGB), `glowFade`. Defaults are registered at the bottom of `focusMonitor.swift`.

## Style

Keep it small: one source file, no dependencies, no abstractions for single uses. Deliberate shortcuts are marked
`// ponytail:` with their limit and upgrade path.
