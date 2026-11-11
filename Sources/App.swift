import AppKit
import ApplicationServices
import CoreBluetooth
import IOBluetooth

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Stage { case idle, connecting, settling, calibrating(Int), pointing, tapTest }

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

    // link
    private var process: Process?
    private var stdinPipe: Pipe?
    private var devices: [(name: String, address: String, connected: Bool)] = []
    private var deviceIdx = 0
    private var buffer = ""
    private var bluetooth: CBCentralManager?

    private let defaults = UserDefaults.standard
    private let tapPresets: [Double] = [0.25, 0.4, 0.15, 0]
    private let dwellNames = ["off", "0.7 s", "1.0 s", "1.5 s"]
    private let dwellValues: [Double] = [0, 0.7, 1.0, 1.5]
    private var tapThreshold: Double {
        get { defaults.double(forKey: "tapThreshold") }
        set { defaults.set(newValue, forKey: "tapThreshold"); taps.threshold = newValue }
    }
    private var dwellIdx: Int { get { defaults.integer(forKey: "dwellIdx") } set { defaults.set(newValue, forKey: "dwellIdx") } }

    // MARK: start

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["tapThreshold": 0.25, "dwellIdx": 0])
        taps.threshold = tapThreshold
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
        setStatus("Not connected")
        overlay.show("AirMagic is running", "Click \u{1F9F2} in the menu bar, or open the app again to connect", autoHide: 5)
    }

    /// Opening the app again (Dock, Launchpad, Spotlight) connects or disconnects.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggleConnect()
        return false
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\u{1F9F2}"
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        connectItem = NSMenuItem(title: "", action: #selector(toggleConnect), keyEquivalent: "")
        confirmItem = NSMenuItem(title: "Confirm step (or tap, or \u{2303}\u{2325}Space)", action: #selector(confirmFromMenu), keyEquivalent: "")
        let recenter = NSMenuItem(title: "Recenter", action: #selector(recenter), keyEquivalent: "")
        let recal = NSMenuItem(title: "Recalibrate", action: #selector(recalibrate), keyEquivalent: "")
        pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
        deviceItem = NSMenuItem(title: "", action: #selector(cycleDevice), keyEquivalent: "")
        tapItem = NSMenuItem(title: "", action: #selector(cycleTap), keyEquivalent: "")
        testItem = NSMenuItem(title: "Test taps\u{2026}", action: #selector(startTapTest), keyEquivalent: "")
        dwellItem = NSMenuItem(title: "", action: #selector(cycleDwell), keyEquivalent: "")
        axItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit AirMagic", action: #selector(quitApp), keyEquivalent: "q")
        for item in [statusLine, connectItem, confirmItem, recenter, recal, pauseItem, NSMenuItem.separator(),
                     deviceItem, tapItem, testItem, dwellItem, axItem, NSMenuItem.separator(), quit] {
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
    @objc private func recenter() { if case .pointing = stage { beginCalibration(keepEdges: true) } }
    @objc private func recalibrate() {
        aim.forget()
        if process?.isRunning == true, orientation.ready { beginCalibration(keepEdges: false) }
    }

    // MARK: emergency stop

    /// Control + Option + Esc: stop moving the cursor right now and shut the link down.
    private func emergencyStop() {
        stage = .idle
        holdUntil = 0
        taps.threshold = tapThreshold
        disconnect()
        overlay.show("Stopped", "The cursor is yours again. Open AirMagic to connect.", autoHide: 4)
    }

    // MARK: link process

    private func connect() {
        refreshDevices()
        guard !devices.isEmpty else {
            overlay.show("No AirPods paired", "Pair them with this Mac first", autoHide: 4)
            return
        }
        guard AXIsProcessTrusted() else {
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
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkStream() }
        orientation = Orientation(seedBias: V3(defaults.array(forKey: "gyroBias") as? [Double]))
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
        case .settling, .calibrating, .pointing, .tapTest:
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
        setStatus("Lost the AirPods stream")
        overlay.show("Lost the AirPods", "No data for 3 s. Open the lid and connect again. Details: link.log", autoHide: 15)
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
    }

    private func linkEnded(_ status: Int32) {
        process = nil; stdinPipe = nil
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
            if l.contains("lid closed") { setStatus("Lid closed \u{2013} keeping the stream alive") }
            appendLog(l)
        }
    }

    private func appendLog(_ line: String) {
        let url = Link.supportDirectory().appendingPathComponent("link.log")
        let stamp = String(format: "%.1f ", ProcessInfo.processInfo.systemUptime)
        guard let data = (stamp + line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    private func process(_ samples: [Sample]) {
        if case .idle = stage { return }
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        for s in samples {
            if case .connecting = stage { stage = .settling; overlay.show("Hold the case still", "Upright, light facing you") }
            let updated = orientation.feed(s)
            if let strength = taps.feed(s) { tapped(strength) }
            switch stage {
            case .settling:
                if orientation.ready == false { settlingHint() }
                if orientation.ready {
                    defaults.set(orientation.bias.array, forKey: "gyroBias")
                    beginCalibration(keepEdges: aim.right != nil && aim.up != nil)
                }
            case .calibrating(let step):
                if updated { calibrationHold(step) }
            case .tapTest:
                tapTestTick()
            case .pointing:
                if !orientation.ready {
                    // the pose was lost (a long gap in the data): settle and aim again
                    stage = .settling
                    overlay.show("Lost the pose", "Hold the case still for a moment")
                } else if updated {
                    point(at: Double(s.stamp) * 1e-6)
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
        testReturn = stage
        tapPeaks = []
        tapNoise = 0
        lastTapAt = 0
        testStart = ProcessInfo.processInfo.systemUptime
        taps.threshold = 0.08      // listen closely during the test
        stage = .tapTest
        showTapTest()
    }

    private func showTapTest() {
        let last = tapPeaks.last.map { String(format: "last knock %.2f g", $0) } ?? "knock on the front of the case"
        overlay.show("Tap the case  \(tapPeaks.count)/3", String(format: "%@   \u{2022}   noise %.2f g", last, tapNoise))
    }

    private func tapTestTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTapAt > 0.7 { tapNoise = max(tapNoise * 0.995, taps.lastPeak) }
        if now - testStart > 25 { endTapTest(note: "No taps heard. Try knocking harder, or leave it as it was.", keep: false); return }
        if now - lastHint > 0.3 { lastHint = now; showTapTest() }
    }

    private func tapTestHit(_ strength: Double) {
        lastTapAt = ProcessInfo.processInfo.systemUptime
        tapPeaks.append(strength)
        showTapTest()
        if tapPeaks.count >= 3 { endTapTest(note: nil, keep: true) }
    }

    private func endTapTest(note: String?, keep: Bool) {
        taps.threshold = tapThreshold
        var message = note ?? ""
        if keep, let weakest = tapPeaks.min() {
            // a knock must be clearly above the noise, and the weakest knock must still count
            let value = min(1.0, max(0.6 * weakest, 2.5 * tapNoise, 0.08))
            tapThreshold = (value * 100).rounded() / 100
            message = String(format: "Threshold set to %.2f g  (knocks %.2f\u{2013}%.2f g, noise %.2f g)", tapThreshold, weakest, tapPeaks.max() ?? weakest, tapNoise)
        }
        switch testReturn {
        case .calibrating(let n): showStep(n)
        default:
            if aim.calibrated { stage = .pointing } else { showStep(0) }
        }
        overlay.show("Tap test done", message, autoHide: 5)
    }

    // MARK: calibration

    // steps: 0 centre, 1 right edge, 2 top edge
    private let targets: [(x: Double, y: Double)] = [(0.5, 0.5), (0.97, 0.5), (0.5, 0.04)]
    private let prompts = ["Point at the dot in the middle", "Point at the dot on the right edge", "Point at the dot on the top edge"]

    private func beginCalibration(keepEdges: Bool) {
        if !keepEdges { aim.right = nil; aim.up = nil }
        resetFilters()
        showStep(0)
    }

    private func showStep(_ n: Int) {
        stage = .calibrating(n)
        stepShownAt = ProcessInfo.processInfo.systemUptime
        holdStart = nil
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
            if progress >= 1 { holdStart = nil; confirm() }
            else if now - lastHint > 0.2 {
                lastHint = now
                overlay.show(prompts[step], "Hold steady\u{2026} \(Int(progress * 100))%", target: targets[step])
            }
        } else {
            holdStart = nil
            if now - lastHint > 0.4 {
                lastHint = now
                overlay.show(prompts[step], far ? "Hold steady on the dot (or tap, or \u{2303}\u{2325}Space)" : "Aim further \u{2013} about 15\u{00B0} from the middle", target: targets[step])
            }
        }
    }

    private func tapped(_ strength: Double) {
        statusItem.button?.title = String(format: "\u{1F5B1}%.2f", strength)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.statusItem.button?.title = "\u{1F9F2}" }
        if case .calibrating = stage {
            if ProcessInfo.processInfo.systemUptime - stepShownAt > 1.5 { confirm() }
            return
        }
        if case .tapTest = stage { tapTestHit(strength); return }
        guard case .pointing = stage, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClick > 0.5 else { return }
        lastClick = now
        holdUntil = now + 0.4
        // the knock itself jolts the cursor, so click where it was a moment ago
        let target = history.last(where: { now - $0.t >= 0.2 })?.p ?? history.first?.p ?? NSEvent.mouseLocation
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
        stage = .pointing
        resetFilters()
        setStatus("Pointing")
        overlay.show("Pointing", "Hold still on something to click", autoHide: 2.5)
    }

    // MARK: pointing

    private func resetFilters() {
        fx.reset(); fy.reset(); history.removeAll(); dwellArmed = false
    }

    private func point(at time: Double) {
        guard !paused, let p = aim.point(orientation.q) else { return }
        lastRaw = p
        let b = CGDisplayBounds(CGMainDisplayID())
        let nx = max(0, min(1, fx.filter(p.x, at: time))), ny = max(0, min(1, fy.filter(p.y, at: time)))
        let pt = CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + ny * (b.height - 1))
        let now = ProcessInfo.processInfo.systemUptime
        history.append((now, pt))
        history.removeAll { now - $0.t > 0.6 }
        if now < holdUntil { return }

        let dwell = dwellValues[dwellIdx]
        if dwell > 0 {
            if hypot(pt.x - dwellAnchor.x, pt.y - dwellAnchor.y) > 30 {
                dwellAnchor = pt; dwellStart = now; dwellArmed = true
            } else if dwellArmed, now - dwellStart > dwell, now - lastClick > 0.5 {
                dwellArmed = false; lastClick = now; holdUntil = now + 0.4
                click(at: dwellAnchor)
                return
            }
        }
        move(to: pt)
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
