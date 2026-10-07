import AppKit
import AVFoundation
import IOKit.ps
import ServiceManagement
import SwiftUI
import Vision

// Settings (UserDefaults, edited in the Settings window): "dwell", "typingGrace", "camera", "enabled".
let defaults = UserDefaults.standard
/// Face detections per second: up to 10 (~7 in practice with a 15 fps camera), or 5 on battery / Low Power Mode. Measured on an M-series Mac with a C920:
/// ~10 % of one core at 10/s, ~7.5 % at 5/s (+ ~3 % in macOS's USB camera service). Camera is off when paused or single-display.
func sampleInterval() -> TimeInterval {
    let source = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()?.takeRetainedValue())?.takeUnretainedValue() as String?
    return source == kIOPMBatteryPowerKey || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.2 : 0.1
}
// Head turned further than this (radians, ~29°) from every calibrated screen = looking away: focus stays.
// A fixed angle, not relative to screen spacing: a tight calibration must not make every glance "away".
let awayReach = 0.5
let calibFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".focusmonitor.json")

// MARK: - Log (shown in the Settings window)

final class Log: ObservableObject {
    static let shared = Log()
    @Published var lines: [String] = [] // newest first
}

func log(_ msg: String) {
    let line = Date().formatted(date: .omitted, time: .standard) + "  " + msg
    print(line)
    DispatchQueue.main.async {
        Log.shared.lines.insert(line, at: 0)
        if Log.shared.lines.count > 300 { Log.shared.lines.removeLast() }
    }
}

/// What the camera sees right now, for the Settings window (only updated while it's open).
final class Live: ObservableObject {
    static let shared = Live()
    @Published var facing = ""
    @Published var seen = Date.distantPast
}

// MARK: - Gaze -> display

struct Anchor: Codable { let display: CGDirectDisplayID; let yaw: Double; let pitch: Double }

/// One calibration per set of connected monitors (home, office, …), plus the camera it was made with.
struct Profile: Codable { var camera: String?; var anchors: [Anchor] }

/// Profile key = the connected displays. Display IDs derive from vendor/model/serial, so they're stable per monitor.
// ponytail: two identical monitor models without serial numbers look like the same setup; fine until someone has that.
func setupKey(_ ids: [CGDirectDisplayID]) -> String { ids.sorted().map(String.init).joined(separator: "+") }

func loadProfiles() -> [String: Profile] {
    guard let data = try? Data(contentsOf: calibFile) else { return [:] }
    if let profiles = try? JSONDecoder().decode([String: Profile].self, from: data) { return profiles }
    // Pre-profiles file: a single calibration.
    guard let old = try? JSONDecoder().decode([Anchor].self, from: data) else { return [:] }
    return [setupKey(old.map(\.display)): Profile(camera: defaults.string(forKey: "camera"), anchors: old)]
}

// ponytail: head pose (yaw/pitch), not eye tracking. Works when you turn your head between
// monitors; eyes-only glances won't register. Upgrade path: eye landmarks from VNDetectFaceLandmarksRequest.
/// Nearest calibrated display, or nil when undecided:
/// - between screens: the nearest must be within (1 - margin) × the runner-up's distance;
/// - looking away (colleague, window): the nearest must be within `reach` (radians of head turn).
func nearest(yaw: Double, pitch: Double, _ anchors: [Anchor], margin: Double = 0, reach: Double = .infinity) -> CGDirectDisplayID? {
    let ranked = anchors.map { (a: $0, d: hypot($0.yaw - yaw, $0.pitch - pitch)) }.sorted { $0.d < $1.d }
    guard let best = ranked.first else { return nil }
    if ranked.count > 1, best.d > (1 - margin) * ranked[1].d { return nil }
    if best.d > reach { return nil }
    return best.a.display
}

/// Fires once per change, after the same display has been nearest for `dwell` seconds straight.
/// Slows face detection down while nothing happens: head still for 2 s, or no face (away from the desk).
/// Any head movement switches back to full speed. Costs at most `slow` extra delay on the first turn.
struct Pacer {
    var settled: (yaw: Double, pitch: Double)?, activeAt = 0.0
    static let slow = 0.4 // 2.5 detections/s
    /// `pose` is nil when no face was found. Returns the interval until the next detection.
    mutating func next(_ pose: (yaw: Double, pitch: Double)?, at t: Double, fast: Double) -> Double {
        // Compared with where the head settled, not the previous frame: frame-to-frame jitter measured up to
        // 0.08 rad while sitting still. 0.15 rad (~9°) is well under any screen-to-screen turn (≥ 0.4).
        if let p = pose, settled.map({ hypot($0.yaw - p.yaw, $0.pitch - p.pitch) > 0.15 }) ?? true {
            activeAt = t
            settled = p
        }
        return t - activeAt > 2 ? max(fast, Self.slow) : fast
    }
}

struct Debouncer {
    var candidate: CGDirectDisplayID?, since = 0.0, current: CGDirectDisplayID?
    mutating func feed(_ d: CGDirectDisplayID, at t: Double, dwell: Double) -> CGDirectDisplayID? {
        if d != candidate { candidate = d; since = t }
        guard d != current, t - since >= dwell else { return nil }
        current = d
        return d
    }
}

// MARK: - Camera + face pose

final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let control = DispatchQueue(label: "camera.control") // start/stopRunning block
    var onPose: (_ yaw: Double, _ pitch: Double) -> Void = { _, _ in } // called on main
    private var last = 0.0
    private var interval = 0.1, fast = 0.1, fastChecked = 0.0
    private var pacer = Pacer()
    private let req = VNDetectFaceRectanglesRequest() // revision 3: continuous yaw/pitch

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    override init() {
        super.init()
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
    }

    /// Switches to the camera with `id` (first camera if unknown) and returns the id actually used.
    @discardableResult func use(cameraID: String?) -> String? {
        let cams = Self.cameras
        guard let cam = cams.first(where: { $0.uniqueID == cameraID }) ?? cams.first,
              let input = try? AVCaptureDeviceInput(device: cam) else { return nil }
        if (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID == cam.uniqueID { return cam.uniqueID }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.addInput(input)
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 } // 320x240 measured no cheaper
        session.commitConfiguration()
        log("Camera: \(cam.localizedName)")
        return cam.uniqueID
    }

    func setRunning(_ on: Bool) {
        control.async { [session] in
            if on != session.isRunning { on ? session.startRunning() : session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = ProcessInfo.processInfo.systemUptime
        if t - fastChecked > 30 { fast = sampleInterval(); fastChecked = t } // power source changes rarely
        guard t - last >= interval, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        last = t
        try? VNImageRequestHandler(cvPixelBuffer: px).perform([req])
        // Biggest face = you, not someone walking behind you.
        let face = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        let pose = face.flatMap { f in f.yaw.flatMap { y in f.pitch.map { (yaw: y.doubleValue, pitch: $0.doubleValue) } } }
        interval = pacer.next(pose, at: t, fast: fast)
        guard let pose else { return }
        DispatchQueue.main.async { self.onPose(pose.yaw, pose.pitch) }
    }
}

// MARK: - Focus

func screens() -> [(id: CGDirectDisplayID, screen: NSScreen)] {
    NSScreen.screens.compactMap { s in
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, s) }
    }
}

func axFrame(_ w: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
          AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

@_silgen_name("GetProcessForPID") // public but hidden from Swift as deprecated
func getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// ponytail: private SkyLight call (same as yabai/AltTab). Public APIs either bring *all* the app's windows
// forward (AX frontmost, like Cmd-Tab) or get refused for background processes (activate()). Falls back to activate().
let slSetFront = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), "_SLPSSetFrontProcessWithOptions")
    .map { unsafeBitCast($0, to: (@convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError).self) }

/// Activate the app like a click: only `windowID` comes forward, its other windows keep their place on other screens.
func activateWindowOnly(pid: pid_t, windowID: UInt32) {
    var psn = ProcessSerialNumber()
    let userGenerated: UInt32 = 0x200
    if let setFront = slSetFront, getProcessForPID(pid, &psn) == noErr, setFront(&psn, windowID, userGenerated) == .success { return }
    NSRunningApplication(processIdentifier: pid)?.activate()
}

@_silgen_name("_AXUIElementGetWindow") // private but stable for years; what yabai/AltTab use
func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// App rule lists ("keepFocus", "neverFocus"): comma-separated bundle IDs in UserDefaults.
func appRule(_ key: String) -> Set<String> {
    Set((defaults.string(forKey: key) ?? "").split(separator: ",").map(String.init))
}

/// Raise + focus the topmost normal window whose center lies on `display`.
func focusFrontWindow(on display: CGDirectDisplayID) {
    let bounds = CGDisplayBounds(display)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let neverFocus = appRule("neverFocus")
    for w in list { // front-to-back order
        guard w[kCGWindowLayer as String] as? Int == 0, (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd), r.width > 100, r.height > 100,
              bounds.contains(CGPoint(x: r.midX, y: r.midY)),
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              !neverFocus.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") else { continue }
        let windowID = w[kCGWindowNumber as String] as? CGWindowID ?? 0

        // Raise the exact window (an app may have windows on several screens), then activate the app.
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
        let windows = v as? [AXUIElement] ?? []
        let byID = windows.first { var id: CGWindowID = 0; return axWindowID($0, &id) == .success && id == windowID }
        if let win = byID ?? windows.first(where: { axFrame($0) == r }) { // frame match only if the private call fails
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        activateWindowOnly(pid: pid, windowID: windowID)
        let screen = screens().first { $0.id == display }?.screen.localizedName ?? "display \(display)"
        log("→ \(w[kCGWindowOwnerName as String] as? String ?? "?") on \(screen)")
        return
    }
}

// MARK: - Settings window

/// Colors live in UserDefaults as "r g b a" (sRGB).
func color(from s: String) -> Color {
    let c = s.split(separator: " ").compactMap { Double($0) }
    return c.count == 4 ? Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3]) : .green
}
func string(from c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .systemGreen
    return "\(n.redComponent) \(n.greenComponent) \(n.blueComponent) \(n.alphaComponent)"
}


struct SettingsView: View {
    @AppStorage("camera") var camera = ""
    @AppStorage("dwell") var dwell = 0.6
    @AppStorage("typingGrace") var typingGrace = 2.0
    @AppStorage("mouseGrace") var mouseGrace = 1.0
    @AppStorage("margin") var margin = 0.3
    @AppStorage("movePointer") var movePointer = false
    @AppStorage("pauseInCalls") var pauseInCalls = true
    @AppStorage("glow") var glow = true
    @AppStorage("glowColor") var glowColor = ""
    @AppStorage("glowFade") var glowFade = 0.8
    @ObservedObject var log = Log.shared
    @ObservedObject var live = Live.shared
    let onCameraChange: (String) -> Void
    let onRecalibrate: () -> Void
    let onPreviewGlow: () -> Void

    var body: some View {
        Form {
            Section("Status") {
                // Re-checked every half second: permissions change in System Settings, faces come and go.
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    LabeledContent("Facing") {
                        Text(ctx.date.timeIntervalSince(live.seen) < 1 ? live.facing : "no face (or camera off)")
                            .monospacedDigit()
                    }
                    permission("Camera", AVCaptureDevice.authorizationStatus(for: .video) == .authorized, pane: "Privacy_Camera")
                    permission("Accessibility", AXIsProcessTrusted(), pane: "Privacy_Accessibility")
                }
                Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                    catch { focusMonitor.log("Launch at login: \(error.localizedDescription)") }
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                }))
            }
            Picker("Camera", selection: Binding(get: { camera }, set: { camera = $0; onCameraChange($0) })) {
                ForEach(HeadTracker.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            LabeledContent("Switch after looking for") {
                Slider(value: $dwell, in: 0.2...2, step: 0.1)
                Text(String(format: "%.1f s", dwell)).monospacedDigit().frame(width: 44)
            }
            LabeledContent("Switch margin") {
                Slider(value: $margin, in: 0...0.6, step: 0.05)
                Text("\(Int(margin * 100)) %").monospacedDigit().frame(width: 44)
            }
            LabeledContent("Keep focus while using the mouse for") {
                Slider(value: $mouseGrace, in: 0...5, step: 0.5)
                Text(mouseGrace == 0 ? "off" : String(format: "%.1f s", mouseGrace)).monospacedDigit().frame(width: 44)
            }
            Toggle("Move the mouse pointer to the focused screen", isOn: $movePointer)
            Toggle("Pause during video calls (another app uses a camera)", isOn: $pauseInCalls)
            LabeledContent("Pause after typing for") {
                Slider(value: $typingGrace, in: 0...5, step: 0.5)
                Text(typingGrace == 0 ? "off" : String(format: "%.1f s", typingGrace)).monospacedDigit().frame(width: 44)
            }
            Toggle("Flash the screen that gets focus", isOn: $glow)
            Group {
                ColorPicker("Flash color", selection: Binding(get: { color(from: glowColor) }, set: { glowColor = string(from: $0) }))
                LabeledContent("Fade out over") {
                    Slider(value: $glowFade, in: 0.2...3, step: 0.1)
                    Text(String(format: "%.1f s", glowFade)).monospacedDigit().frame(width: 44)
                }
                LabeledContent("") { Button("Preview", action: onPreviewGlow) }
            }.disabled(!glow)
            LabeledContent("Calibration") {
                Text(screens().map(\.screen.localizedName).joined(separator: " + ")).foregroundStyle(.secondary)
                Button("Recalibrate…", action: onRecalibrate)
            }
            Section("App rules") {
                AppList("Never switch away from", key: "keepFocus")
                AppList("Never focus", key: "neverFocus")
            }
            Section("Log") {
                ScrollView {
                    Text(log.lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220) // fixed, so the log scrolls inside its box instead of stretching the Form
            }
            Section("About") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("focusMonitor").font(.headline)
                        Text("Look at a monitor, and its front window gets focus.").foregroundStyle(.secondary)
                        let info = Bundle.main.infoDictionary ?? [:]
                        Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Link("github.com/slay22/focusMonitor", destination: URL(string: "https://github.com/slay22/focusMonitor")!)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 720) // grouped Form has no natural height
    }

    func permission(_ name: String, _ granted: Bool, pane: String) -> some View {
        LabeledContent(name) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Missing", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}

/// Editable list of apps, stored as comma-separated bundle IDs (see `appRule`).
struct AppList: View {
    let title: String
    @AppStorage var ids: String
    init(_ title: String, key: String) {
        self.title = title
        _ids = AppStorage(wrappedValue: "", key)
    }
    var list: [String] { ids.split(separator: ",").map(String.init) }

    var body: some View {
        LabeledContent(title) {
            Menu("Add App") {
                let running = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && !list.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != nil }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                ForEach(running, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier!) { ids = (list + [app.bundleIdentifier!]).joined(separator: ",") }
                }
            }.fixedSize()
        }
        ForEach(list, id: \.self) { id in
            HStack {
                Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    .padding(.leading)
                Spacer()
                Button { ids = list.filter { $0 != id }.joined(separator: ",") } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
    }
}

// MARK: - Menu bar app

final class App: NSObject, NSApplicationDelegate {
    let tracker = HeadTracker()
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var profiles = loadProfiles()
    var profile: Profile? { profiles[setupKey(screens().map(\.id))] }
    var setupChange: DispatchWorkItem?
    let watching = NSMenuItem(title: "Watching: –", action: nil, keyEquivalent: "")
    var glow: NSWindow?
    var pointerSpots: [CGDirectDisplayID: CGPoint] = [:]
    var pausedBy: Set<String> = [] // automatic pauses: "video call", "screen locked", "screen asleep"
    var deb = Debouncer()
    var settingsWindow: NSWindow?
    // Calibration in progress: screens still to do, results so far, current screen's samples.
    var calibQueue: [(id: CGDirectDisplayID, screen: NSScreen)] = []
    var calibAnchors: [Anchor] = []
    var calibKey = ""
    var calibSamples: [(Double, Double)]?
    var calibPanel: NSPanel?

    func applicationDidFinishLaunching(_: Notification) {
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            log("⚠️ No Accessibility permission: focus switching won't work. Grant it in System Settings → Privacy & Security → Accessibility.")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        watching.isEnabled = false
        menu.addItem(watching)
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "Pause Tracking", action: #selector(toggle), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        // ⌃⌥⌘P from any app (global: other apps focused, local: our Settings window focused). Needs Accessibility.
        let isHotkey = { (e: NSEvent) in
            e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command] && e.charactersIgnoringModifiers == "p"
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [unowned self] e in if isHotkey(e) { toggle() } }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            guard isHotkey(e) else { return e }
            toggle()
            return nil
        }
        menu.addItem(withTitle: "Recalibrate", action: #selector(recalibrate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit focusMonitor", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        status.menu = menu

        pickCamera()
        tracker.onPose = { [unowned self] in pose(yaw: $0, pitch: $1) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [unowned self] _ in
            // Docking connects monitors one by one: wait until it settles.
            setupChange?.cancel()
            setupChange = DispatchWorkItem { [unowned self] in setupChanged() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: setupChange!)
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { self.setupChanged() } }

        // Camera plugged/unplugged: back to the profile's camera, or fall back to another one.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in pickCamera() }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [unowned self] n in
            log("Camera error, restarting: \((n.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "?")")
            restartCamera()
        }
        // Lock / display sleep pause tracking; waking from sleep restarts the camera (sessions can stall over sleep).
        let pauseOn = { [unowned self] (reason: String, on: Bool) in
            if on { pausedBy.insert(reason) } else { pausedBy.remove(reason) }
            refresh()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in pauseOn("screen locked", true) }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in pauseOn("screen locked", false) }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in pauseOn("screen asleep", true) }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in pauseOn("screen asleep", false) }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in restartCamera() }
        // Video call = some other app has a camera open. Polled: there's no notification for it.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let inCall = defaults.bool(forKey: "pauseInCalls") && HeadTracker.cameras.contains { $0.isInUseByAnotherApplication }
            if inCall != self.pausedBy.contains("video call") { pauseOn("video call", inCall) }
        }
    }

    /// Use the profile's camera if it's connected, otherwise any camera (and say so).
    func pickCamera() {
        let wanted = profile?.camera ?? defaults.string(forKey: "camera")
        guard let used = tracker.use(cameraID: wanted) else { return log("⚠️ No camera connected") }
        if let wanted, used != wanted {
            log("⚠️ The calibrated camera isn't connected, using another one until it's back (calibration may be off).")
        }
        defaults.set(used, forKey: "camera")
    }

    func restartCamera() {
        tracker.setRunning(false)
        refresh()
    }

    /// Switch to the profile of the connected monitors; calibrate if this setup is new.
    func setupChanged() {
        deb = Debouncer()
        if !calibQueue.isEmpty { // monitors changed mid-calibration: start over
            calibPanel?.close()
            calibQueue = []
        }
        let names = screens().map(\.screen.localizedName).joined(separator: " + ")
        if screens().count > 1 {
            if let p = profile {
                log("Setup: \(names)")
                if p.camera != defaults.string(forKey: "camera") { pickCamera() }
            } else {
                log("New setup: \(names), calibrating")
                recalibrate()
            }
        }
        refresh()
    }

    func refresh() {
        let on = defaults.bool(forKey: "enabled")
        let single = screens().count < 2 // laptop alone (e.g. in a meeting): nothing to switch between
        let tracking = on && !single && pausedBy.isEmpty
        // Green while the camera is on (like macOS's camera indicator); plain template icon when paused.
        let icon = NSImage(systemSymbolName: tracking ? "eye.fill" : "eye.slash", accessibilityDescription: "focusMonitor")
        let green = icon?.withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
        green?.isTemplate = false // template images get drawn monochrome by the menu bar
        status.button?.image = tracking ? green : icon
        let state = tracking ? "tracking" : !on ? "paused" : single ? "paused, single display" : "paused, " + pausedBy.sorted().joined(separator: ", ")
        if status.button?.toolTip != "focusMonitor: " + state { log("Status: " + state) }
        status.button?.toolTip = "focusMonitor: " + state
        if !tracking { watching.title = "Watching: –" }
        status.menu?.item(at: 2)?.title = on ? "Pause Tracking" : "Resume Tracking"
        tracker.setRunning(tracking || !calibQueue.isEmpty) // camera light off when not tracking
    }

    @objc func toggle() {
        defaults.set(!defaults.bool(forKey: "enabled"), forKey: "enabled")
        refresh()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(onCameraChange: { [unowned self] id in
                tracker.use(cameraID: id)
                recalibrate() // other camera, other angles
            }, onRecalibrate: { [unowned self] in recalibrate() },
               onPreviewGlow: { [unowned self] in if let s = settingsWindow?.screen { glow(s) } })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "focusMonitor Settings"
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// "LG FHD", "between screens", "looking away" + raw angles, using the same rules as switching.
    func showFacing(yaw: Double, pitch: Double) {
        let anchors = profile?.anchors ?? []
        let name = { (id: CGDirectDisplayID) in screens().first { $0.id == id }?.screen.localizedName ?? "?" }
        let verdict = anchors.isEmpty ? "not calibrated"
            : nearest(yaw: yaw, pitch: pitch, anchors, reach: awayReach) == nil ? "looking away"
            : nearest(yaw: yaw, pitch: pitch, anchors, margin: defaults.double(forKey: "margin")).map(name) ?? "between screens"
        Live.shared.facing = String(format: "%@   (yaw %+.2f, pitch %+.2f)", verdict, yaw, pitch)
        Live.shared.seen = Date()
    }

    func pose(yaw: Double, pitch: Double) {
        if settingsWindow?.isVisible == true { showFacing(yaw: yaw, pitch: pitch) }
        if !calibQueue.isEmpty { // calibrating: no focus switching, sample once the panel's delay is over
            if calibSamples != nil { calibrationSample(yaw, pitch) }
            return
        }
        guard defaults.bool(forKey: "enabled"), screens().count > 1 else { return }
        // Glancing at another screen while writing must not steal focus. Reset the dwell so it
        // only counts once you've stopped typing.
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < defaults.double(forKey: "typingGrace") {
            deb.candidate = nil
            return
        }
        // Never switch away from listed apps (games, presentations, …).
        if appRule("keepFocus").contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
            deb.candidate = nil
            return
        }
        // Head between two screens, or turned away from all of them: undecided, focus stays put and
        // the dwell starts over once it's clear again. (Leaving the desk = no face = no samples at all.)
        guard let d = nearest(yaw: yaw, pitch: pitch, profile?.anchors ?? [], margin: defaults.double(forKey: "margin"), reach: awayReach) else {
            deb.candidate = nil
            return
        }
        // Using the mouse on one screen: don't take focus away from that screen.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let pointerDisplay = screens().map(\.id).first { CGDisplayBounds($0).contains(pointer) }
        let mouseIdle = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()!
        if mouseIdle < defaults.double(forKey: "mouseGrace"), pointerDisplay != d {
            deb.candidate = nil
            return
        }
        guard let target = deb.feed(d, at: ProcessInfo.processInfo.systemUptime, dwell: defaults.double(forKey: "dwell")) else { return }
        focusFrontWindow(on: target)
        if defaults.bool(forKey: "movePointer"), let from = pointerDisplay, from != target {
            // Leave the pointer where it was on each screen, and bring it back there on return.
            pointerSpots[from] = pointer
            let b = CGDisplayBounds(target)
            CGWarpMouseCursorPosition(pointerSpots[target] ?? CGPoint(x: b.midX, y: b.midY))
            CGAssociateMouseAndMouseCursorPosition(1) // no input freeze after the warp
        }
        guard let screen = screens().first(where: { $0.id == target })?.screen else { return }
        watching.title = "Watching: " + screen.localizedName
        if defaults.bool(forKey: "glow") { glow(screen) }
    }

    /// Brief green frame around the screen focus just moved to; click-through, fades out.
    func glow(_ screen: NSScreen) {
        glow?.close()
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .screenSaver // above everything, and not layer 0 so focusFrontWindow never picks it
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: Rectangle().strokeBorder(color(from: defaults.string(forKey: "glowColor") ?? ""), lineWidth: 8))
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        glow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = defaults.double(forKey: "glowFade"); w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
    }

    // MARK: Calibration: a panel on each screen in turn; look at it until it moves on.

    @objc func recalibrate() {
        guard calibQueue.isEmpty, screens().count > 1 else { return refresh() }
        calibQueue = screens()
        calibKey = setupKey(calibQueue.map(\.id))
        calibAnchors = []
        nextCalibrationScreen()
    }

    func nextCalibrationScreen() {
        calibPanel?.close()
        guard let s = calibQueue.first else {
            calibPanel = nil
            calibSamples = nil
            profiles[calibKey] = Profile(camera: defaults.string(forKey: "camera"), anchors: calibAnchors)
            try? JSONEncoder().encode(profiles).write(to: calibFile)
            deb = Debouncer()
            return refresh()
        }
        let f = s.screen.frame
        let panel = NSPanel(contentRect: CGRect(x: f.midX - 260, y: f.midY - 170, width: 520, height: 340),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "focusMonitor calibration (\(calibAnchors.count + 1)/\(calibAnchors.count + calibQueue.count))"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 140))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse) // static when Reduce Motion is on
                    .accessibilityHidden(true)
                Text("Look at this screen").font(.largeTitle.bold())
                Text("Hold still a moment, it moves on by itself.").font(.title3).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity))
        // Position again after init: init alone may clamp the panel onto another screen (seen on SMB2440MH).
        panel.setFrameOrigin(CGPoint(x: f.midX - 260, y: f.midY - 170))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Look at \(s.screen.localizedName)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        calibPanel = panel
        calibSamples = nil
        refresh()
        // Give the eyes/head a moment to get there before sampling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in calibSamples = [] }
    }

    func calibrationSample(_ yaw: Double, _ pitch: Double) {
        calibSamples!.append((yaw, pitch))
        guard calibSamples!.count == 20 else { return }
        let s = calibSamples!
        let done = calibQueue.removeFirst()
        let a = Anchor(display: done.id, yaw: s.map(\.0).sorted()[10], pitch: s.map(\.1).sorted()[10]) // median
        // Two screens that look alike to the camera can't be told apart reliably.
        for other in calibAnchors where hypot(other.yaw - a.yaw, other.pitch - a.pitch) < 0.25 {
            let name = screens().first { $0.id == other.display }?.screen.localizedName ?? "another screen"
            log("⚠️ \(done.screen.localizedName) and \(name) look almost the same to the camera. Turn your head more, or move the camera, and recalibrate.")
        }
        calibAnchors.append(a)
        log(String(format: "Calibrated %@: yaw %.2f, pitch %.2f", done.screen.localizedName, a.yaw, a.pitch))
        nextCalibrationScreen()
    }
}

// MARK: - Main

func selftest() {
    let a = [Anchor(display: 1, yaw: -0.5, pitch: 0), Anchor(display: 2, yaw: 0.5, pitch: 0), Anchor(display: 3, yaw: 0, pitch: 0.4)]
    precondition(nearest(yaw: -0.4, pitch: 0.1, a) == 1)
    precondition(nearest(yaw: 0.6, pitch: 0, a) == 2)
    precondition(nearest(yaw: 0, pitch: 0.3, a) == 3)
    precondition(nearest(yaw: 0, pitch: 0, a, margin: 0.3) == nil)       // between all three: undecided
    precondition(nearest(yaw: 0, pitch: 0, a) == 3)                      // ...but plain nearest picks 3
    precondition(nearest(yaw: 0.45, pitch: 0, a, margin: 0.3) == 2)      // clearly 2
    precondition(nearest(yaw: 0.9, pitch: 0, [a[1]], margin: 0.3) == 2)  // single anchor always wins
    precondition(nearest(yaw: 1.5, pitch: 0, a, reach: awayReach) == nil)     // turned far right: looking away
    precondition(nearest(yaw: 0.7, pitch: 0, a, reach: awayReach) == 2)       // right screen's edge: still 2
    precondition(setupKey([3, 1, 2]) == setupKey([2, 3, 1]))
    precondition(string(from: color(from: "1.0 0.5 0.0 0.75")) == "1.0 0.5 0.0 0.75") // color survives storage
    var pc = Pacer()
    precondition(pc.next((0, 0), at: 0, fast: 0.1) == 0.1)         // first face: fast
    precondition(pc.next((0.01, 0), at: 1, fast: 0.1) == 0.1)      // still, but not for 2 s yet
    precondition(pc.next((0.01, 0), at: 2.5, fast: 0.1) == Pacer.slow) // still for 2.5 s: slow
    precondition(pc.next(nil, at: 5, fast: 0.1) == Pacer.slow)     // no face: stays slow
    precondition(pc.next((0.4, 0), at: 6, fast: 0.1) == 0.1)       // head turns: fast again
    let dwell = 0.6
    var d = Debouncer()
    precondition(d.feed(1, at: 0, dwell: dwell) == nil)          // not long enough yet
    precondition(d.feed(1, at: dwell, dwell: dwell) == 1)        // fires
    precondition(d.feed(1, at: dwell + 1, dwell: dwell) == nil)  // only once
    precondition(d.feed(2, at: 10, dwell: dwell) == nil)         // glance…
    precondition(d.feed(1, at: 10.1, dwell: dwell) == nil)       // …back: no switch, still on 1
    precondition(d.feed(2, at: 20, dwell: dwell) == nil)
    precondition(d.feed(2, at: 20 + dwell, dwell: dwell) == 2)
    print("selftest ok")
}

if CommandLine.arguments.contains("selftest") { selftest(); exit(0) }
defaults.register(defaults: ["dwell": 0.6, "typingGrace": 2.0, "enabled": true, "glow": true, "glowColor": "0.2 0.78 0.35 0.8", "glowFade": 0.8,
                                    "margin": 0.3, "mouseGrace": 1.0, "movePointer": false, "pauseInCalls": true])
let delegate = App()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
