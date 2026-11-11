import AppKit
import ApplicationServices
import CoreBluetooth
import IOBluetooth
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    enum Stage { case idle, connecting, settling, calibrating(Int), tapTest, practice, pointing }

    // UI
    private var statusItem: NSStatusItem!
    private let overlay = Overlay()
    private var statusLine = NSMenuItem()
    private var connectItem = NSMenuItem()
    private var confirmItem = NSMenuItem()
    private var pauseItem = NSMenuItem()
    private var deviceItem = NSMenuItem()
    private var tapItem = NSMenuItem()
    private var testItem = NSMenuItem()
    private var recordItem = NSMenuItem()
    private var dwellItem = NSMenuItem()
    private var axItem = NSMenuItem()

    // pointing
    private var stage = Stage.idle
    private var paused = false
    private var orientation = Orientation(seedBias: nil)
    private let aim = Aim()
    private let taps = TapDetector(threshold: 0.25)
    private let fx = OneEuro(), fy = OneEuro()
    private var history: [(t: Double, p: CGPoint)] = []
    private var holdUntil = 0.0
    private var lastClick = 0.0
    private var dwellAnchor = CGPoint.zero
    private var dwellStart = 0.0
    private var dwellArmed = false
    private var lastSampleAt = 0.0
    private var watchdog: Timer?
    private var suppressEndOverlay = false
    private var counted = 0
    private var countStart = 0.0
    private var rate = 0.0
    private var lastHint = 0.0
    private var stepShownAt = 0.0
    private var holdStart: Double?
    private var tapPeaks: [Double] = []
    private var tapNoise = 0.0
    private var lastTapAt = 0.0
    private var testStart = 0.0
    private var testReturn = Stage.pointing

    // window
    private let model = AppModel()
    private var window: NSWindow?
    private var syncTimer: Timer?
    private var totalSamples = 0
    private var rateTotal = 0
    private var rateAt = 0.0
    private var liveRate = 0
    private var holdProgress = 0.0
    private var notice: String?
    private var lidClosed = false
    private var lastKnock = 0.0
    private var lastDeviceRefresh = 0.0
    private var filteredPos: CGPoint?
    private var practiceHits: Set<Int> = []
    private var practiceClick: PracticeClick?
    private var clickCounter = 0
    private var previewing = false
    private var earbudSilent = false
    private let gyro = GyroMouse()
    private let slide = SlideMouse()
    private var mousePos = CGPoint(x: 0.5, y: 0.5)
    private var mouseHint: String?
    private var mouseRate = 0.0
    private var gyroRetries = 0
    private var lastMoveLog = 0.0
    private var recorder: SlideRecorder?
    private static let otherDeviceHint = "The AirPods are not answering. They are probably also connected to another device, such as your iPhone. Turn Bluetooth off on it, then connect again."

    // link
    private var process: Process?
    private var stdinPipe: Pipe?
    private var devices: [(name: String, address: String, connected: Bool)] = []
    private var deviceIdx = 0
    private var buffer = ""
    private var bluetooth: CBCentralManager?

    private let defaults = UserDefaults.standard
    private let tapPresets: [Double] = [0.4, 0.25, 0.6, 0]
    private let dwellNames = ["off", "0.7 s", "1.0 s", "1.5 s"]
    private let dwellValues: [Double] = [0, 0.7, 1.0, 1.5]
    private var tapThreshold: Double {
        get { defaults.double(forKey: "tapThreshold") }
        set { defaults.set(newValue, forKey: "tapThreshold"); taps.threshold = newValue }
    }
    private var dwellIdx: Int { get { defaults.integer(forKey: "dwellIdx") } set { defaults.set(newValue, forKey: "dwellIdx") } }
    private var mode: Int { get { defaults.integer(forKey: "mode") } set { defaults.set(newValue, forKey: "mode") } }
    /// Either of the relative modes: the gyro mouse (1) or sliding on a surface (2).
    private var mouseMode: Bool { mode != 0 }
    private var slideMode: Bool { mode == 2 }
    /// Whether the pointing for the current mode is calibrated (aim edges, or the two turns).
    private var calibratedNow: Bool { slideMode ? slide.calibrated : (mouseMode ? gyro.calibrated : (aim.right != nil && aim.up != nil)) }
    private var invertX: Bool { get { defaults.bool(forKey: "invertX") } set { defaults.set(newValue, forKey: "invertX"); aim.invertX = newValue } }
    private var invertY: Bool { get { defaults.bool(forKey: "invertY") } set { defaults.set(newValue, forKey: "invertY"); aim.invertY = newValue } }
    private var gain: Double {
        get { defaults.double(forKey: "gain") }
        set { defaults.set(newValue, forKey: "gain"); aim.gain = newValue; gyro.gain = newValue; slide.gain = newValue }
    }
    private var smooth: Double {
        get { defaults.double(forKey: "smooth") }
        set { defaults.set(newValue, forKey: "smooth"); applySmooth() }
    }

    /// Smoothing 0...1 maps to the filter's cutoff: more smoothing, lower cutoff.
    private func applySmooth() {
        let cutoff = 3.0 - 2.6 * min(max(smooth, 0), 1)
        fx.minCutoff = cutoff
        fy.minCutoff = cutoff
        gyro.smoothing = 0.08 * min(max(smooth, 0), 1)
    }

    // MARK: start

    func applicationDidFinishLaunching(_ notification: Notification) {
        // an earlier build could save a bad knock threshold: start from the tuned default once
        if !defaults.bool(forKey: "tapReset4") {
            defaults.set(0.4, forKey: "tapThreshold")
            defaults.set(false, forKey: "tapSetupDone")
            defaults.set(true, forKey: "tapReset4")
        }
        defaults.register(defaults: ["tapThreshold": 0.4, "dwellIdx": 0, "gain": 1.0, "smooth": 0.7, "mode": 0, "invertX": false, "invertY": false])
        taps.threshold = tapThreshold
        aim.gain = gain
        aim.invertX = invertX
        aim.invertY = invertY
        gyro.load()
        gyro.gain = gain
        slide.load()
        slide.gain = gain
        applySmooth()
        // edges saved by an earlier build may be bad: start clean once, then reuse good ones
        if defaults.bool(forKey: "aimReset3") { aim.load() } else { aim.forget(); defaults.set(true, forKey: "aimReset3") }
        // Creating a manager is what makes macOS ask for Bluetooth access.
        bluetooth = CBCentralManager(delegate: nil, queue: nil)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.contains([.control, .option]) else { return }
            switch e.keyCode {
            case 53: self?.emergencyStop()      // Control + Option + Esc: stop everything
            case 35: self?.togglePause()        // Control + Option + P: pause / resume
            case 49: self?.confirm()            // Control + Option + Space: confirm a calibration step
            default: break
            }
        }
        buildMenu()
        buildMainMenu()
        setStatus("Not connected")
        model.actions = Actions(
            toggleConnect: { [weak self] in self?.toggleConnect() },
            confirmStep: { [weak self] in self?.confirm() },
            recenter: { [weak self] in self?.recenter() },
            recalibrate: { [weak self] in self?.recalibrate() },
            togglePause: { [weak self] in self?.togglePause() },
            testTaps: { [weak self] in self?.startTapTest() },
            skipTapTest: { [weak self] in self?.skipTapTest() },
            startLive: { [weak self] in self?.startLive() },
            backToPractice: { [weak self] in self?.backToPractice() },
            resetPractice: { [weak self] in self?.practiceHits = []; self?.practiceClick = nil },
            setTap: { [weak self] v in self?.tapThreshold = (v * 100).rounded() / 100 },
            setDwell: { [weak self] i in self?.dwellIdx = i; self?.dwellArmed = false },
            setGain: { [weak self] v in self?.gain = v },
            setSmooth: { [weak self] v in self?.smooth = v },
            setMode: { [weak self] m in self?.setMode(m) },
            setInvertX: { [weak self] on in self?.invertX = on },
            setInvertY: { [weak self] on in self?.invertY = on },
            selectDevice: { [weak self] a in self?.defaults.set(a, forKey: "deviceAddress"); self?.refreshDevices() },
            openAccessibility: { [weak self] in self?.openAccessibility() },
            openBluetooth: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            },
            openLog: {
                NSWorkspace.shared.activateFileViewerSelecting([Link.supportDirectory().appendingPathComponent("link.log")])
            },
            startRecording: { [weak self] in self?.startRecording() },
            stopRecording: { [weak self] in self?.finishRecording() })
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.syncModel() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        showWindow()
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--preview=") }) {
            applyPreview(String(arg.dropFirst("--preview=".count)))
        }
        // `--snapshot=/path/image.png` saves the window as a picture and quits (for the README screenshots)
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
            let path = String(arg.dropFirst("--snapshot=".count))
            window?.setContentSize(NSSize(width: 500, height: 860))
            window?.center()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.saveSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Renders the whole window, title bar included, to a PNG. Only the app's own pixels: nothing else on screen.
    private func saveSnapshot(to path: String) {
        guard let frameView = window?.contentView?.superview else { return }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// For reviewing the window without AirPods: `AirMagic --preview=practice` and so on.
    private func applyPreview(_ name: String) {
        previewing = true
        model.accessibilityOK = true; model.bluetoothOK = true; model.bluetoothStatus = "Allowed"
        model.devices = [DeviceInfo(id: "x", name: "AirPods 4", connected: true)]
        model.selectedAddress = "x"
        model.calibrated = true
        model.rate = 402; model.accel = 0.99; model.gyro = 1.1; model.turned = 14
        model.lastKnock = 0.31; model.noise = 0.02
        model.lidClosed = true
        model.mode = 0
        model.tapThreshold = 0.4
        switch name {
        case "permissions": model.accessibilityOK = false
        case "connecting": model.phase = .connecting
        case "settling": model.phase = .settling; model.stillProgress = 0.55
        case "calibrating": model.phase = .calibrating(1); model.holdProgress = 0.6
        case "taptest": model.phase = .tapTest; model.tapTestCount = 2
        case "practice":
            model.phase = .practice
            model.pos = CGPoint(x: 0.43, y: 0.2)
            model.practiceHits = [0, 2, 4]
            model.practiceClick = PracticeClick(id: 1, pos: CGPoint(x: 0.5, y: 0.82), time: Date().addingTimeInterval(-0.2))
        case "pointing": model.phase = .pointing; model.pos = CGPoint(x: 0.6, y: 0.4)
        case "record": model.recording = true; model.recordPrompt = "Slide it RIGHT about 10 cm, then stop"; model.recordProgress = 0.3; model.recordRemaining = 52
        case "mouseidle": model.mode = 1
        case "slide": model.mode = 2; model.phase = .calibrating(0); model.slideLevel = 0.12; model.slideState = "Moving"
        case "slidepractice": model.mode = 2; model.phase = .practice; model.pos = CGPoint(x: 0.6, y: 0.4); model.practiceHits = [1]; model.slideState = "Still"
        case "mouse": model.mode = 1; model.phase = .calibrating(0); model.holdProgress = 0.5; model.mouseSpin = 14
        case "mousepractice": model.mode = 1; model.phase = .practice; model.pos = CGPoint(x: 0.6, y: 0.4); model.practiceHits = [1]; model.mouseRate = 23
        default: break
        }
    }

    /// Opening the app again (Dock, Launchpad, Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    // MARK: window

    @objc private func showWindowAction() { showWindow() }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let host = NSHostingController(rootView: MainView(m: model))
            let w = NSWindow(contentViewController: host)
            w.title = "AirMagic"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 500, height: 780))
            w.center()
            window = w
        }
        lastDeviceRefresh = 0
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncModel()
    }

    /// Closing the window leaves AirMagic running in the menu bar.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit AirMagic", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }

    /// Copies what the app knows into the model the window shows (10 times a second).
    private func syncModel() {
        recordTick()
        if previewing { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - rateAt >= 1 {
            liveRate = Int(Double(totalSamples - rateTotal) / max(now - rateAt, 0.001))
            rateTotal = totalSamples
            rateAt = now
        }
        guard window?.isVisible == true else { return }
        func put<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
            if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
        }
        let phase: Phase
        switch stage {
        case .idle: phase = .idle
        case .connecting: phase = .connecting
        case .settling: phase = .settling
        case .calibrating(let n): phase = .calibrating(n)
        case .pointing: phase = .pointing
        case .tapTest: phase = .tapTest
        case .practice: phase = .practice
        }
        put(\.phase, phase)
        put(\.paused, paused)
        put(\.notice, notice)
        put(\.lidClosed, lidClosed)
        put(\.calibrated, calibratedNow)
        put(\.stillProgress, (orientation.settling * 100).rounded() / 100)
        put(\.holdProgress, (holdProgress * 100).rounded() / 100)
        put(\.tapThreshold, tapThreshold)
        put(\.dwellIdx, dwellIdx)
        put(\.lastKnock, (lastKnock * 100).rounded() / 100)
        put(\.noise, (tapNoise * 100).rounded() / 100)
        put(\.tapTestCount, tapPeaks.count)
        put(\.rate, liveRate)
        put(\.accel, (orientation.accelSize * 100).rounded() / 100)
        put(\.gyro, (orientation.gyroSize * 10).rounded() / 10)
        put(\.turned, ((aim.relative(orientation.q)?.norm ?? 0) * 180 / Double.pi).rounded())
        switch stage {
        case .pointing, .practice: put(\.pos, filteredPos)
        default: put(\.pos, nil)
        }
        put(\.practiceHits, practiceHits)
        put(\.practiceClick, practiceClick)
        put(\.gain, gain)
        put(\.smoothness, smooth)
        put(\.mode, mode)
        put(\.invertX, invertX)
        put(\.invertY, invertY)
        put(\.mouseHint, mouseHint)
        put(\.mouseRate, (mouseRate * 10).rounded() / 10)
        put(\.mouseSpin, (gyro.spinDegrees * 10).rounded() / 10)
        put(\.slideState, slideMode ? slide.stateText : "")
        put(\.slideLevel, (slide.activity * 100).rounded() / 100)

        if case .idle = stage, now - lastDeviceRefresh > 3 { refreshDevices(); lastDeviceRefresh = now }
        put(\.devices, devices.map { DeviceInfo(id: $0.address, name: $0.name, connected: $0.connected) })
        put(\.selectedAddress, devices.indices.contains(deviceIdx) ? devices[deviceIdx].address : "")

        put(\.accessibilityOK, AXIsProcessTrusted())
        let status: (String, Bool)
        switch CBManager.authorization {
        case .allowedAlways: status = ("Allowed", true)
        case .denied: status = ("Denied", false)
        case .restricted: status = ("Restricted", false)
        default: status = ("Not asked yet", false)
        }
        put(\.bluetoothStatus, status.0)
        put(\.bluetoothOK, status.1)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\u{1F9F2}"
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let openItem = NSMenuItem(title: "Open AirMagic\u{2026}", action: #selector(showWindowAction), keyEquivalent: "")
        connectItem = NSMenuItem(title: "", action: #selector(toggleConnect), keyEquivalent: "")
        confirmItem = NSMenuItem(title: "Confirm step (or tap, or \u{2303}\u{2325}Space)", action: #selector(confirmFromMenu), keyEquivalent: "")
        let recenter = NSMenuItem(title: "Recenter", action: #selector(recenter), keyEquivalent: "")
        let recal = NSMenuItem(title: "Recalibrate", action: #selector(recalibrate), keyEquivalent: "")
        pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
        deviceItem = NSMenuItem(title: "", action: #selector(cycleDevice), keyEquivalent: "")
        tapItem = NSMenuItem(title: "", action: #selector(cycleTap), keyEquivalent: "")
        testItem = NSMenuItem(title: "Test taps\u{2026}", action: #selector(startTapTest), keyEquivalent: "")
        recordItem = NSMenuItem(title: "Record sliding test\u{2026}", action: #selector(startRecordingAction), keyEquivalent: "")
        dwellItem = NSMenuItem(title: "", action: #selector(cycleDwell), keyEquivalent: "")
        axItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit AirMagic", action: #selector(quitApp), keyEquivalent: "q")
        for item in [statusLine, openItem, connectItem, confirmItem, recenter, recal, pauseItem, NSMenuItem.separator(),
                     deviceItem, tapItem, testItem, recordItem, dwellItem, axItem, NSMenuItem.separator(), quit] {
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshDevices() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        // Earbuds with a case only (not AirPods Max); connected ones first, then by name.
        let found = paired.filter { d in
            let n = (d.name ?? "").lowercased()
            return n.contains("airpods") && !n.contains("max")
        }.map { (name: $0.name ?? "AirPods", address: $0.addressString ?? "", connected: $0.isConnected()) }
        devices = found.sorted { a, b in
            a.connected != b.connected ? a.connected : a.name < b.name
        }
        if let saved = defaults.string(forKey: "deviceAddress"), let i = devices.firstIndex(where: { $0.address == saved }) {
            deviceIdx = i
        } else { deviceIdx = 0 }
    }

    private func refreshMenu() {
        refreshDevices()
        let running = process?.isRunning == true
        connectItem.title = running ? "Disconnect  (\u{2303}\u{2325}Esc stops anywhere)" : "Connect"
        testItem.isEnabled = running
        recordItem.isEnabled = running && recorder == nil
        pauseItem.title = (paused ? "Resume" : "Pause") + "  (\u{2303}\u{2325}P)"
        if case .calibrating = stage { confirmItem.isEnabled = true } else { confirmItem.isEnabled = false }
        if devices.isEmpty {
            deviceItem.title = "AirPods: none paired"
        } else {
            let d = devices[deviceIdx]
            deviceItem.title = "AirPods: \(d.name)\(d.connected ? "" : " (not connected)") \u{2013} click to change"
        }
        tapItem.title = "Tap to click: \(tapThreshold == 0 ? "off" : String(format: "%.2f g", tapThreshold)) \u{2013} click to change  (last knock \(String(format: "%.2f", taps.lastPeak)) g)"
        dwellItem.title = "Click by holding still: \(dwellNames[dwellIdx])"
        axItem.title = AXIsProcessTrusted() ? "Accessibility: OK" : "Accessibility: NOT GRANTED (click to open)"
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        statusItem.button?.toolTip = text
    }

    // MARK: menu actions

    @objc private func toggleConnect() { process?.isRunning == true ? disconnect() : connect() }
    @objc private func confirmFromMenu() { confirm() }
    @objc private func togglePause() { paused.toggle(); resetFilters() }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func quitApp() { disconnect(); NSApp.terminate(nil) }
    @objc private func cycleDevice() {
        refreshDevices()
        guard !devices.isEmpty else { return }
        deviceIdx = (deviceIdx + 1) % devices.count
        defaults.set(devices[deviceIdx].address, forKey: "deviceAddress")
    }
    @objc private func cycleTap() {
        let i = tapPresets.firstIndex(of: tapThreshold) ?? -1
        tapThreshold = tapPresets[(i + 1) % tapPresets.count]
    }
    @objc private func cycleDwell() { dwellIdx = (dwellIdx + 1) % dwellNames.count; dwellArmed = false }
    @objc private func recenter() {
        switch stage {
        case .pointing, .practice:
            if mouseMode { mousePos = CGPoint(x: 0.5, y: 0.5); filteredPos = mousePos } else { beginCalibration(keepEdges: true) }
        default: break
        }
    }
    @objc private func recalibrate() {
        aim.forget()
        if process?.isRunning == true, orientation.ready { beginCalibration(keepEdges: false) }
    }

    // MARK: sliding test recording

    /// Records the raw samples while the window walks you through a script of slides (see `SlideRecorder`).
    @objc private func startRecordingAction() { startRecording() }

    private func startRecording() {
        guard process?.isRunning == true else { return }
        switch stage {
        case .idle, .connecting: return
        default: break
        }
        let r = SlideRecorder()
        r.begin(now: ProcessInfo.processInfo.systemUptime)
        recorder = r
        model.recordNote = nil
        model.recording = true
        appendLog("recording started")
        showWindow()
    }

    private func recordTick() {
        guard let r = recorder else { return }
        if let step = r.tick(now: ProcessInfo.processInfo.systemUptime) {
            model.recordPrompt = step.prompt
            model.recordProgress = step.progress
            model.recordRemaining = step.remaining
        } else {
            finishRecording()
        }
    }

    private func finishRecording() {
        guard let r = recorder else { return }
        recorder = nil
        model.recording = false
        let url = Link.supportDirectory().appendingPathComponent("slide-test.csv")
        do {
            try r.write(to: url)
            model.recordNote = "Saved \(r.samples.count) samples to slide-test.csv"
            appendLog("recording saved: \(r.samples.count) samples")
        } catch {
            model.recordNote = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: emergency stop

    /// Control + Option + Esc: stop moving the cursor right now and shut the link down.
    private func emergencyStop() {
        stage = .idle
        holdUntil = 0
        notice = nil
        taps.threshold = tapThreshold
        disconnect()
        overlay.show("Stopped", "The cursor is yours again. Open AirMagic to connect.", autoHide: 4)
    }

    // MARK: link process

    private func connect() {
        refreshDevices()
        notice = nil
        guard !devices.isEmpty else {
            notice = "No AirPods are paired with this Mac."
            overlay.show("No AirPods paired", "Pair them with this Mac first", autoHide: 4)
            return
        }
        guard AXIsProcessTrusted() else {
            notice = "Allow AirMagic in System Settings \u{2192} Privacy & Security \u{2192} Accessibility."
            overlay.show("Accessibility needed", "Allow AirMagic in Privacy & Security \u{2192} Accessibility", autoHide: 5)
            return
        }
        let device = devices[deviceIdx]
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--link", device.address]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        buffer = ""
        try? Data().write(to: Link.supportDirectory().appendingPathComponent("link.log"))
        appendLog("connect \(device.name) \(device.address)")
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.handleLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.linkEnded(proc.terminationStatus) }
        }
        do { try p.run() } catch {
            overlay.show("Could not start", error.localizedDescription, autoHide: 5)
            return
        }
        process = p; stdinPipe = inp
        lastSampleAt = 0
        suppressEndOverlay = false
        lidClosed = false
        earbudSilent = false
        lastRaw = nil
        filteredPos = nil
        lastKnock = 0
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkStream() }
        orientation = Orientation(seedBias: V3(defaults.array(forKey: "gyroBias") as? [Double]))
        gyro.resetMotion()
        gyro.resetGesture()
        slide.reset()
        resetFilters()
        stage = .connecting
        setStatus("Connecting to \(device.name)\u{2026}")
        overlay.show("Connecting\u{2026}", "Put the AirPods in the case with the lid open. Audio will drop for a moment.")
    }

    private func disconnect() {
        guard let p = process, p.isRunning else { return }
        stage = .idle
        taps.threshold = tapThreshold
        try? stdinPipe?.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        try? stdinPipe?.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 9) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }

    /// The menu must never claim a connection that is dead: no samples for 3 s ends it.
    private func checkStream() {
        guard process?.isRunning == true else { watchdog?.invalidate(); return }
        switch stage {
        case .settling, .calibrating, .tapTest, .practice, .pointing:
            let now = ProcessInfo.processInfo.systemUptime
            if lastSampleAt > 0, now - lastSampleAt > 3 { lostStream() }
        default:
            break
        }
    }

    private func lostStream() {
        appendLog("watchdog: no samples for 3 s")
        stage = .idle
        taps.threshold = tapThreshold
        suppressEndOverlay = true
        notice = earbudSilent ? Self.otherDeviceHint : "Lost the AirPods: no data for 3 seconds. Open the lid and connect again."
        setStatus("Lost the AirPods stream")
        overlay.show("Lost the AirPods", "No data for 3 s. Open the lid and connect again. Details: link.log", autoHide: 15)
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
    }

    private func linkEnded(_ status: Int32) {
        process = nil; stdinPipe = nil
        if recorder != nil { finishRecording() }
        stage = .idle
        taps.threshold = tapThreshold
        appendLog("exit \(status)")
        statusItem.button?.title = "\u{1F9F2}"
        let reasons: [Int32: String] = [
            20: "Allow Bluetooth for AirMagic in Privacy & Security.",
            21: "Bluetooth is off.",
            22: "These AirPods are not paired with this Mac.",
            23: "Connect the AirPods to this Mac first.",
            24: "macOS changed its Bluetooth internals; this version cannot talk to the case.",
            25: "Another app is using the AirPods channel.",
            26: "Could not reconnect the AirPods.",
            27: "No control channel from the AirPods. Try again with the lid open.",
            28: "The AirPods did not answer. Reopen the lid and try again.",
            30: "No motion data. Make sure the AirPods are not also connected to an iPhone.",
            31: "The earbud did not identify itself.",
            32: "These earbuds are not supported.",
            34: "The case did not identify itself as a charging case.",
            35: "The case went out of reach.",
            36: "The case refused the keep-alive request.",
            40: "The AirPods stopped answering.",
            41: "Unexpected reply from the AirPods; stopped for safety.",
            42: "Could not write to the AirPods.",
            43: "Motion stopped arriving. Open the lid and connect again.",
            44: "The AirPods link dropped.",
        ]
        watchdog?.invalidate()
        if suppressEndOverlay {
            // the watchdog already told the user why
        } else if status == 0 || status == 52 {
            setStatus("Not connected")
            overlay.hide()
        } else {
            let text = (reasons[status] ?? "Stopped") + " (code \(status))"
            notice = earbudSilent ? Self.otherDeviceHint : text
            setStatus(text)
            overlay.show("Disconnected", text, autoHide: 15)
        }
    }

    // MARK: incoming data

    private func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        var samples = [Sample]()
        while let nl = buffer.firstIndex(of: "\n") {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let f = line.split(separator: ",")
            guard f.count == 6, f[0] == "M", let service = Int(f[1]), let stamp = UInt64(f[2]),
                  let x = Int32(f[3]), let y = Int32(f[4]), let z = Int32(f[5]) else { continue }
            samples.append(Sample(service: service, stamp: stamp, x: x, y: y, z: z))
        }
        if !samples.isEmpty { DispatchQueue.main.async { [weak self] in self?.process(samples) } }
    }

    private func handleLog(_ text: String) {
        for line in text.split(separator: "\n") {
            let l = String(line)
            if l.contains("WARN earbud silent") {
                earbudSilent = true
                notice = Self.otherDeviceHint
                overlay.show("The AirPods are not answering", "Probably connected to your iPhone too. Turn its Bluetooth off, then connect again.", autoHide: 20)
            }
            if l.contains("lid closed") { lidClosed = true; setStatus("Lid closed \u{2013} keeping the stream alive") }
            else if l.contains("lid open") { lidClosed = false }
            appendLog(l)
        }
    }

    private func appendLog(_ line: String) {
        let url = Link.supportDirectory().appendingPathComponent("link.log")
        let stamp = String(format: "%.1f ", ProcessInfo.processInfo.systemUptime)
        let shown = stamp + line
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.log.append(shown)
            if self.model.log.count > 300 { self.model.log.removeFirst(self.model.log.count - 300) }
        }
        guard let data = (stamp + line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    private func process(_ samples: [Sample]) {
        totalSamples += samples.count
        recorder?.add(samples)
        if case .idle = stage { return }
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        for s in samples {
            if case .connecting = stage { stage = .settling; overlay.show("Hold the case still", "Upright, light facing you") }
            let updated = orientation.feed(s)
            var mouseDelta: (dx: Double, dy: Double)?
            if updated, mouseMode, orientation.ready {
                mouseRate = orientation.gyroSize
                if slideMode {
                    mouseDelta = slide.feed(accel: orientation.accelBody, gyro: orientation.gyroBody, dt: orientation.lastDt)
                } else if gyro.calibrated {
                    mouseDelta = gyro.feed(gyro: orientation.gyroBody, dt: orientation.lastDt)
                }
            }
            if let strength = taps.feed(s) { tapped(strength) }
            switch stage {
            case .settling:
                if orientation.ready == false { settlingHint() }
                if orientation.ready {
                    defaults.set(orientation.bias.array, forKey: "gyroBias")
                    beginCalibration(keepEdges: calibratedNow)
                }
            case .calibrating(let step):
                if updated { if slideMode { slideCalibrationTick(step) } else if mouseMode { gyroCalibrationTick(step) } else { calibrationHold(step) } }
            case .tapTest:
                tapTestTick()
            case .pointing:
                if !orientation.ready {
                    // the pose was lost (a long gap in the data): settle and aim again
                    stage = .settling
                    overlay.show("Lost the pose", "Hold the case still for a moment")
                } else if updated {
                    if mouseMode { moveMouse(mouseDelta, live: true) } else { point(at: Double(s.stamp) * 1e-6, live: true) }
                }
                pointingHint()
            case .practice:
                if !orientation.ready {
                    stage = .settling
                    overlay.show("Lost the pose", "Hold the case still for a moment")
                } else if updated {
                    if mouseMode { moveMouse(mouseDelta, live: false) } else { point(at: Double(s.stamp) * 1e-6, live: false) }
                }
                pointingHint()
            default:
                break
            }
        }
    }

    /// Live numbers while waiting for the case to be still, so a stall is visible.
    private func settlingHint() {
        let now = ProcessInfo.processInfo.systemUptime
        counted += 1
        if countStart == 0 { countStart = now }
        if now - countStart >= 1 { rate = Double(counted) / (now - countStart); counted = 0; countStart = now }
        guard now - lastHint > 0.4 else { return }
        lastHint = now
        let o = orientation
        let text = String(format: "still %d%%  |a| %.2f g  gyro %.1f\u{00B0}/s  spread %.2f/%.3f  %d/s", Int(o.settling * 100), o.accelSize, o.gyroSize, o.spreadGyro, o.spreadAccel, Int(rate))
        overlay.show("Hold the case still", text)
        setStatus(text)
    }

    private var lastRaw: (x: Double, y: Double)?

    /// Live numbers while pointing, in the menu's first line.
    private func pointingHint() {
        let now = ProcessInfo.processInfo.systemUptime
        counted += 1
        if countStart == 0 { countStart = now }
        if now - countStart >= 1 { rate = Double(counted) / (now - countStart); counted = 0; countStart = now }
        guard now - lastHint > 0.5 else { return }
        lastHint = now
        let raw = lastRaw.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "-"
        let angle = (aim.relative(orientation.q)?.norm ?? 0) * 180 / Double.pi
        setStatus(String(format: "pointing  pos %@  turned %.0f\u{00B0}  gyro %.1f\u{00B0}/s  %d/s", raw, angle, orientation.gyroSize, Int(rate)))
    }

    // MARK: tap test

    @objc private func startTapTest() {
        guard process?.isRunning == true, orientation.ready else {
            overlay.show("Connect first", "The tap test needs the case connected and still", autoHide: 3)
            return
        }
        beginTapTest(returning: stage)
    }

    private func beginTapTest(returning: Stage) {
        testReturn = returning
        tapPeaks = []
        tapNoise = 0
        lastTapAt = 0
        testStart = ProcessInfo.processInfo.systemUptime
        taps.threshold = 0.25      // listen a little closer during the test
        stage = .tapTest
        showTapTest()
    }

    private func skipTapTest() {
        guard case .tapTest = stage else { return }
        endTapTest(note: "Skipped.", keep: false, done: true)
    }

    private func showTapTest() {
        let last = tapPeaks.last.map { String(format: "last knock %.2f g", $0) } ?? "knock on the front of the case"
        overlay.show("Tap the case  \(tapPeaks.count)/3", String(format: "%@   \u{2022}   noise %.2f g", last, tapNoise))
    }

    private func tapTestTick() {
        let now = ProcessInfo.processInfo.systemUptime
        tapNoise = taps.recentPeak      // shown live so a knock that is too soft to count is still visible
        if now - testStart > 45 { endTapTest(note: "No taps heard. Try knocking harder, or leave it as it was.", keep: false, done: false); return }
        if now - lastHint > 0.3 { lastHint = now; showTapTest() }
    }

    private func tapTestHit(_ strength: Double) {
        lastTapAt = ProcessInfo.processInfo.systemUptime
        tapPeaks.append(strength)
        showTapTest()
        if tapPeaks.count >= 3 { endTapTest(note: nil, keep: true, done: true) }
    }

    private func endTapTest(note: String?, keep: Bool, done: Bool) {
        taps.threshold = tapThreshold
        if done { defaults.set(true, forKey: "tapSetupDone") }
        var message = note ?? ""
        if keep, let weakest = tapPeaks.min() {
            // the weakest knock must still count, with room to spare
            let value = min(0.6, max(0.2, 0.5 * weakest))
            tapThreshold = (value * 100).rounded() / 100
            message = String(format: "Threshold set to %.2f g  (knocks %.2f\u{2013}%.2f g)", tapThreshold, weakest, tapPeaks.max() ?? weakest)
        }
        switch testReturn {
        case .calibrating(let n): showStep(n)
        case .pointing: stage = .pointing
        default:
            if calibratedNow { enterPractice() } else { showStep(0) }
        }
        if case .practice = stage { setStatus(message.isEmpty ? "Practice" : message) }
        else { overlay.show("Tap test done", message, autoHide: 5) }
    }

    // MARK: calibration

    // steps: 0 centre, 1 right edge, 2 top edge
    private let targets: [(x: Double, y: Double)] = [(0.5, 0.5), (0.97, 0.5), (0.5, 0.04)]
    private let prompts = ["Point at the dot in the middle", "Point at the dot on the right edge", "Point at the dot on the top edge"]

    private func beginCalibration(keepEdges: Bool) {
        if slideMode { beginSlideCalibration(keep: keepEdges); return }
        if mouseMode { beginGyroCalibration(keep: keepEdges); return }
        if !keepEdges { aim.right = nil; aim.up = nil }
        resetFilters()
        showStep(0)
    }

    // MARK: gyro mouse

    /// Two short turns tell the app which way is "right" and which is "up", as rotation axes of the case
    /// itself. They are kept while the case is held the same way (gravity in its frame).
    private func beginGyroCalibration(keep: Bool) {
        resetFilters()
        gyro.resetGesture()
        gyro.resetMotion()
        mouseHint = nil
        gyroRetries = 0
        let up = orientation.upBody
        if keep, gyro.calibrated, let held = gyro.held, held.dot(up) >= cos(40 * Double.pi / 180) {
            finishCalibration()
            return
        }
        gyro.forget()
        showGyroStep(0)
    }

    private func showGyroStep(_ n: Int) {
        stage = .calibrating(n)
        stepShownAt = ProcessInfo.processInfo.systemUptime
        holdProgress = 0
        gyro.resetGesture()
    }

    private func gyroCalibrationTick(_ step: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - stepShownAt > 0.6 else { gyro.resetGesture(); return }
        holdProgress = min(1, gyro.spinDegrees / 25)
        guard let axis = gyro.trackGesture(gyro: orientation.gyroBody, dt: orientation.lastDt, minimumDegrees: 12) else { return }
        appendLog(String(format: "gyro turn %d: axis %.2f, %.2f, %.2f", step, axis.x, axis.y, axis.z))
        if step == 0 {
            gyro.right = axis
            mouseHint = nil
            showGyroStep(1)
            return
        }
        guard let right = gyro.right else { showGyroStep(0); return }
        let across = axis - right * axis.dot(right)
        if across.norm >= 0.5 {
            gyro.up = across.unit
            mouseHint = nil
        } else if gyroRetries < 2 {
            // the second turn was the same as the first: ask for the other one
            gyroRetries += 1
            mouseHint = "That was the same turn. Now tip the top of the case up, like nodding."
            showGyroStep(1)
            return
        } else {
            gyro.up = GyroMouse.anyPerpendicular(to: right)
            mouseHint = "Up and down were assumed. If the pointer goes the wrong way, turn on Invert up / down."
        }
        gyro.held = orientation.upBody
        gyro.save()
        finishCalibration()
    }

    private func setMode(_ newMode: Int) {
        guard newMode != mode else { return }
        mode = newMode
        gyro.resetMotion()
        gyro.resetGesture()
        slide.reset()
        mouseHint = nil
        switch stage {
        case .calibrating, .practice, .pointing:
            if orientation.ready { beginCalibration(keepEdges: true) }
        default: break
        }
    }

    // MARK: sliding on a surface

    /// Two short strokes tell the app which way is right and which is away from you, in the case's own frame.
    private func beginSlideCalibration(keep: Bool) {
        resetFilters()
        slide.reset()
        mouseHint = nil
        gyroRetries = 0
        let up = orientation.upBody
        if keep, slide.calibrated, let held = slide.held, held.dot(up) >= cos(35 * Double.pi / 180) {
            finishCalibration()
            return
        }
        slide.forget()
        showSlideStep(0)
    }

    private func showSlideStep(_ n: Int) {
        stage = .calibrating(n)
        stepShownAt = ProcessInfo.processInfo.systemUptime
        holdProgress = 0
        _ = slide.takeStroke()
    }

    private func slideCalibrationTick(_ step: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - stepShownAt > 0.8 else { _ = slide.takeStroke(); return }
        holdProgress = min(1, slide.activity / 0.12)
        guard let direction = slide.takeStroke() else { return }
        appendLog(String(format: "slide stroke %d: axis %.2f, %.2f, %.2f", step, direction.x, direction.y, direction.z))
        if step == 0 {
            slide.right = direction
            mouseHint = nil
            showSlideStep(1)
            return
        }
        guard let right = slide.right else { showSlideStep(0); return }
        let across = direction - right * direction.dot(right)
        let up = orientation.upBody
        if across.norm >= 0.5 {
            slide.forward = across.unit
            mouseHint = nil
        } else if gyroRetries < 2 {
            gyroRetries += 1
            mouseHint = "That was along the same line. Now slide it straight away from you."
            showSlideStep(1)
            return
        } else {
            let other = up.cross(right)
            slide.forward = other.norm > 1e-6 ? other.unit : GyroMouse.anyPerpendicular(to: right)
            mouseHint = "Up and down were assumed. If the pointer goes the wrong way, turn on Invert up / down."
        }
        slide.held = up
        slide.save()
        finishCalibration()
    }

    /// Mouse mode: turning the case moves the pointer, relative to where it is, like an air mouse.
    private func moveMouse(_ delta: (dx: Double, dy: Double)?, live: Bool) {
        guard let d = delta else { return }
        if live && paused { return }
        let now = ProcessInfo.processInfo.systemUptime
        let b = CGDisplayBounds(CGMainDisplayID())
        let w = max(b.width - 1, 1), h = max(b.height - 1, 1)
        let dx = d.dx * (invertX ? -1 : 1)
        let dy = d.dy * (invertY ? -1 : 1)
        if (dx != 0 || dy != 0), now - lastMoveLog > 1 {
            lastMoveLog = now
            appendLog(String(format: "move: %@ dx %.1f dy %.1f px (turning %.0f deg/s)", live ? "live" : "practice", dx, dy, mouseRate))
        }

        var pt: CGPoint
        if live {
            guard let loc = CGEvent(source: nil)?.location else { return }
            pt = CGPoint(x: min(max(loc.x + dx, b.minX), b.maxX - 1), y: min(max(loc.y + dy, b.minY), b.maxY - 1))
            filteredPos = CGPoint(x: (pt.x - b.minX) / w, y: (pt.y - b.minY) / h)
        } else {
            mousePos = CGPoint(x: min(max(mousePos.x + dx / w, 0), 1), y: min(max(mousePos.y + dy / h, 0), 1))
            filteredPos = mousePos
            pt = CGPoint(x: b.minX + mousePos.x * w, y: b.minY + mousePos.y * h)
        }
        history.append((now, pt))
        history.removeAll { now - $0.t > 0.6 }
        if now < holdUntil { return }
        if dwellClick(at: pt, now: now, live: live) { return }
        if live && (dx != 0 || dy != 0) { move(to: pt) }
    }

    /// Click-by-holding-still: returns true when it clicked.
    private func dwellClick(at pt: CGPoint, now: Double, live: Bool) -> Bool {
        let dwell = dwellValues[dwellIdx]
        guard dwell > 0 else { return false }
        if hypot(pt.x - dwellAnchor.x, pt.y - dwellAnchor.y) > 30 {
            dwellAnchor = pt; dwellStart = now; dwellArmed = true
        } else if dwellArmed, now - dwellStart > dwell, now - lastClick > 0.5 {
            dwellArmed = false; lastClick = now; holdUntil = now + 0.4
            if live { click(at: dwellAnchor) } else { virtualClick(at: dwellAnchor) }
            return true
        }
        return false
    }

    private func showStep(_ n: Int) {
        if slideMode { showSlideStep(n); return }
        if mouseMode { showGyroStep(n); return }
        stage = .calibrating(n)
        stepShownAt = ProcessInfo.processInfo.systemUptime
        holdStart = nil
        holdProgress = 0
        overlay.show(prompts[n], "Hold steady on the dot (or tap, or \u{2303}\u{2325}Space)", target: targets[n])
    }

    /// A step confirms itself when the case is held steady on the dot, so no tap is needed.
    private func calibrationHold(_ step: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - stepShownAt > 1.2 else { return }
        let steady = orientation.gyroSize < 4
        var far = true
        if step > 0, let v = aim.relative(orientation.q) { far = v.norm * 180 / Double.pi >= 10 }
        if steady && far {
            let began = holdStart ?? now
            holdStart = began
            let progress = (now - began) / 1.3
            holdProgress = min(1, progress)
            if progress >= 1 { holdStart = nil; confirm() }
            else if now - lastHint > 0.2 {
                lastHint = now
                overlay.show(prompts[step], "Hold steady\u{2026} \(Int(progress * 100))%", target: targets[step])
            }
        } else {
            holdStart = nil
            holdProgress = 0
            if now - lastHint > 0.4 {
                lastHint = now
                overlay.show(prompts[step], far ? "Hold steady on the dot (or tap, or \u{2303}\u{2325}Space)" : "Aim further \u{2013} about 15\u{00B0} from the middle", target: targets[step])
            }
        }
    }

    private func tapped(_ strength: Double) {
        lastKnock = strength
        statusItem.button?.title = String(format: "\u{1F5B1}%.2f", strength)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.statusItem.button?.title = "\u{1F9F2}" }
        if case .calibrating = stage {
            if ProcessInfo.processInfo.systemUptime - stepShownAt > 1.5 { confirm() }
            return
        }
        if case .tapTest = stage { tapTestHit(strength); return }
        if case .practice = stage {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastClick > 0.5 else { return }
            lastClick = now
            holdUntil = now + 0.4
            if let target = history.last(where: { now - $0.t >= 0.2 })?.p ?? history.first?.p { virtualClick(at: target) }
            return
        }
        guard case .pointing = stage, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClick > 0.5 else { return }
        lastClick = now
        holdUntil = now + 0.4
        // the knock itself jolts the cursor, so click where it was a moment ago
        let target = history.last(where: { now - $0.t >= 0.2 })?.p ?? history.first?.p ?? CGEvent(source: nil)?.location ?? .zero
        click(at: target)
    }

    private func confirm() {
        guard case .calibrating(let step) = stage, orientation.ready else { return }
        do {
            switch step {
            case 0:
                let keep = aim.recenter(orientation.q, referenceGravity: orientation.referenceGravity)
                if !keep { aim.setCenter(orientation.q, referenceGravity: orientation.referenceGravity) }
                if keep { finishCalibration() } else { showStep(1) }
            case 1:
                try aim.setEdge(right: true, orientation.q)
                showStep(2)
            default:
                try aim.setEdge(right: false, orientation.q)
                finishCalibration()
            }
        } catch Aim.AimError.tooSmall {
            overlay.show("Aim a little further", "About 15\u{00B0} away from the middle", target: targets[step])
        } catch {
            overlay.show("Aim in a different direction", "Return to the middle, then aim at the dot", target: targets[step])
            showStepAgain(step)
        }
    }

    private func showStepAgain(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if case .calibrating(let s) = self?.stage, s == n { self?.showStep(n) }
        }
    }

    private func finishCalibration() {
        aim.save()
        resetFilters()
        // every time: the three-knock test, then the practice pad (the test can be skipped)
        beginTapTest(returning: .practice)
    }

    /// The pointer is virtual here: it moves in the window, and nothing on the Mac is clicked.
    private func enterPractice() {
        stage = .practice
        resetFilters()
        practiceHits = []
        practiceClick = nil
        mousePos = CGPoint(x: 0.5, y: 0.5)
        gyro.resetMotion()
        slide.reset()
        filteredPos = mouseMode ? mousePos : nil
        overlay.hide()
        setStatus("Practice \u{2013} nothing is clicked yet")
        showWindow()
    }

    private func startLive() {
        guard case .practice = stage else { return }
        stage = .pointing
        resetFilters()
        setStatus("Pointing")
        overlay.show("Pointing is live", "\u{2303}\u{2325}Esc stops everything", autoHide: 2.5)
    }

    private func backToPractice() {
        guard case .pointing = stage else { return }
        enterPractice()
    }

    // MARK: pointing

    private func resetFilters() {
        fx.reset(); fy.reset(); history.removeAll(); dwellArmed = false
    }

    private func point(at time: Double, live: Bool) {
        guard let p = aim.point(orientation.q) else { return }
        if live && paused { return }
        lastRaw = p
        let b = CGDisplayBounds(CGMainDisplayID())
        let fxv = fx.filter(p.x, at: time), fyv = fy.filter(p.y, at: time)
        filteredPos = CGPoint(x: fxv, y: fyv)
        let nx = max(0, min(1, fxv)), ny = max(0, min(1, fyv))
        let pt = CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + ny * (b.height - 1))
        let now = ProcessInfo.processInfo.systemUptime
        history.append((now, pt))
        history.removeAll { now - $0.t > 0.6 }
        if now < holdUntil { return }

        if dwellClick(at: pt, now: now, live: live) { return }
        if live { move(to: pt) }
    }

    /// A click in the practice pad: lights up the circle under the pointer, if any.
    private func virtualClick(at screenPoint: CGPoint) {
        let b = CGDisplayBounds(CGMainDisplayID())
        let n = CGPoint(x: (screenPoint.x - b.minX) / max(b.width - 1, 1), y: (screenPoint.y - b.minY) / max(b.height - 1, 1))
        clickCounter += 1
        practiceClick = PracticeClick(id: clickCounter, pos: n, time: Date())
        for (i, t) in AppModel.practiceTargets.enumerated() {
            let dx = (n.x - t.x) * 1.6, dy = n.y - t.y          // the pad is 16:10
            if (dx * dx + dy * dy).squareRoot() < 0.11 { practiceHits.insert(i); break }
        }
    }

    private func move(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func click(at p: CGPoint) {
        move(to: p)
        // Dock and menu bar need a moment of hover before they accept a click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.move(to: p)
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: 1)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { disconnect() }
}
