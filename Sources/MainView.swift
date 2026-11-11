import SwiftUI

// The main window: status and the one big button on top, the card for whatever step
// you are on, then grouped settings.

private let stepNames = ["Allow", "Connect", "Calibrate", "Tap", "Try"]

extension AppModel {
    var needsPermissions: Bool { !accessibilityOK || !bluetoothOK }

    /// 0 Allow, 1 Connect, 2 Calibrate, 3 Tap, 4 Try; 5 when everything is done.
    var setupStep: Int {
        if phase == .idle && needsPermissions { return 0 }
        switch phase {
        case .idle, .connecting, .settling: return 1
        case .calibrating: return 2
        case .tapTest: return 3
        case .practice: return 4
        case .pointing: return 5
        }
    }

    var title: String {
        switch phase {
        case .idle: return needsPermissions ? "Set up AirMagic" : (notice == nil ? "Ready to connect" : "Disconnected")
        case .connecting: return "Connecting\u{2026}"
        case .settling: return "Hold the case still"
        case .calibrating: return "Calibrating"
        case .tapTest: return "Tap test"
        case .practice: return "Practice"
        case .pointing: return paused ? "Paused" : "Pointing"
        }
    }

    var subtitle: String {
        switch phase {
        case .idle:
            if needsPermissions { return "Two permissions, then connect your AirPods." }
            return notice ?? "Here is how it works. Open the lid near your Mac, then press Connect."
        case .connecting: return "Open the lid. Audio drops for a moment while the link is re-established."
        case .settling: return mode == 2 ? "Close the lid and lay the case flat on the desk." : "Close the lid and hold the case upright, light facing you."
        case .calibrating: return mode == 2 ? "Slide the case along the desk as shown, then stop." : (mode == 1 ? "Turn the case as shown, then hold still for a moment." : "Point at each red dot on your screen and hold steady.")
        case .tapTest: return "Knock on the case: \(tapTestCount) of 3."
        case .practice: return mode == 2 ? "Nothing is clicked on your Mac yet. Slide the case and check the pointer follows." : (mode == 1 ? "Nothing is clicked on your Mac yet. Turn the case and check the pointer follows." : "Nothing is clicked on your Mac yet. Check that it points where you aim.")
        case .pointing:
            if paused { return "The cursor is yours. Resume to point again." }
            return mode == 2 ? "Slide the case like a mouse. Knock on it, or hold still, to click." : (mode == 1 ? "Turn the case like an air mouse. Knock on it, or hold still, to click." : "Move the case to move the cursor. Knock on it, or hold still, to click.")
        }
    }

    var symbol: String {
        switch phase {
        case .idle: return needsPermissions ? "lock.shield" : (notice == nil ? "cursorarrow.slash" : "exclamationmark.triangle.fill")
        case .connecting: return "dot.radiowaves.left.and.right"
        case .settling: return "hand.raised.fill"
        case .calibrating: return "scope"
        case .tapTest: return "hand.tap.fill"
        case .practice: return "circle.dotted"
        case .pointing: return paused ? "pause.fill" : "cursorarrow.motionlines"
        }
    }

    var tint: Color {
        switch phase {
        case .idle: return notice == nil ? .secondary : .orange
        case .pointing: return paused ? .yellow : .green
        default: return .accentColor
        }
    }
}

struct MainView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header(m: m)
            Divider()
            Form {
                Section { StageCard(m: m).padding(.vertical, 6) }
                airPodsSection
                pointingSection
                clickingSection
                if m.phase == .pointing { liveSection }
                permissionsSection
                shortcutsSection
                testSection
                activitySection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 820)
    }

    // MARK: sections

    private var airPodsSection: some View {
        Section("AirPods") {
            if m.devices.isEmpty {
                Label("No paired AirPods found", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Use", selection: Binding(get: { m.selectedAddress },
                                                 set: { m.selectedAddress = $0; m.actions.selectDevice($0) })) {
                    ForEach(m.devices) { d in
                        Text(d.connected ? d.name : "\(d.name) (not connected)").tag(d.id)
                    }
                }
                .disabled(m.phase != .idle)
            }
            if m.phase.isActive {
                LabeledContent("Case lid") {
                    Label(m.lidClosed ? "Closed" : "Open", systemImage: m.lidClosed ? "lock.fill" : "lock.open")
                        .foregroundStyle(m.lidClosed ? Color.green : Color.secondary)
                }
            }
        }
    }

    private var pointingSection: some View {
        Section("Pointing") {
            Picker("Mode", selection: Binding(get: { m.mode }, set: { m.mode = $0; m.actions.setMode($0) })) {
                Text("Aim in the air").tag(0)
                Text("Gyro mouse").tag(1)
                Text("Slide (beta)").tag(2)
            }
            .pickerStyle(.segmented)
            LabeledContent("Calibration") {
                Text(m.calibrated ? "Saved" : "Not set").foregroundStyle(m.calibrated ? Color.primary : Color.secondary)
            }
            Toggle("Invert left / right", isOn: Binding(get: { m.invertX }, set: { m.invertX = $0; m.actions.setInvertX($0) }))
            Toggle("Invert up / down", isOn: Binding(get: { m.invertY }, set: { m.invertY = $0; m.actions.setInvertY($0) }))
            LabeledContent("Speed") {
                HStack(spacing: 8) {
                    Text("Slow").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { m.gain }, set: { m.gain = $0; m.actions.setGain($0) }), in: 0.5...2.0)
                        .frame(minWidth: 140)
                    Text("Fast").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Smoothing") {
                HStack(spacing: 8) {
                    Text("Raw").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { m.smoothness }, set: { m.smoothness = $0; m.actions.setSmooth($0) }), in: 0...1)
                        .frame(minWidth: 140)
                    Text("Smooth").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Recenter", action: m.actions.recenter).disabled(m.phase != .pointing && m.phase != .practice)
                Button("Recalibrate", action: m.actions.recalibrate).disabled(!m.phase.isActive || m.phase == .connecting)
                if case .calibrating = m.phase { Button("Confirm step", action: m.actions.confirmStep) }
                Spacer()
                if m.phase == .pointing {
                    Button(m.paused ? "Resume" : "Pause", action: m.actions.togglePause)
                }
            }
        }
    }

    private var clickingSection: some View {
        Section("Clicking") {
            Toggle("Click with a knock on the case",
                   isOn: Binding(get: { m.tapThreshold > 0 }, set: { m.actions.setTap($0 ? 0.4 : 0) }))
            if m.tapThreshold > 0 {
                LabeledContent("Sensitivity") {
                    HStack(spacing: 8) {
                        Text("Low").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { 1 - m.tapThreshold }, set: { m.actions.setTap(1 - $0) }), in: 0.2...0.85)
                            .frame(minWidth: 140)
                        Text("High").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Threshold") {
                    Text(String(format: "%.2f g", m.tapThreshold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LabeledContent("Tap test") {
                HStack {
                    if m.phase.isActive {
                        Text(String(format: "last %.2f g \u{00B7} now %.2f g", m.lastKnock, m.noise))
                            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Run\u{2026}", action: m.actions.testTaps)
                        .disabled(!m.phase.isActive || m.phase == .connecting || m.phase == .settling || m.phase == .tapTest)
                }
            }
            Picker("Click by holding still", selection: Binding(get: { m.dwellIdx }, set: { m.dwellIdx = $0; m.actions.setDwell($0) })) {
                ForEach(0..<m.dwellNames.count, id: \.self) { Text(m.dwellNames[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var liveSection: some View {
        Section("Live") {
            PracticePad(m: m)
            LabeledContent("Samples per second") { Text("\(m.rate)").monospacedDigit() }
            LabeledContent("Acceleration") { Text(String(format: "%.2f g", m.accel)).monospacedDigit() }
            LabeledContent("Rotation") { Text(String(format: "%.1f\u{00B0}/s", m.gyro)).monospacedDigit() }
            LabeledContent("Turned from centre") { Text(String(format: "%.0f\u{00B0}", m.turned)).monospacedDigit() }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Accessibility") {
                HStack {
                    Label(m.accessibilityOK ? "Allowed" : "Needed", systemImage: m.accessibilityOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(m.accessibilityOK ? Color.green : Color.orange)
                    if !m.accessibilityOK { Button("Open Settings", action: m.actions.openAccessibility) }
                }
            }
            LabeledContent("Bluetooth") {
                HStack {
                    Label(m.bluetoothStatus, systemImage: m.bluetoothOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(m.bluetoothOK ? Color.green : Color.orange)
                    if !m.bluetoothOK { Button("Open Settings", action: m.actions.openBluetooth) }
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent("Stop everything") { Text("\u{2303}\u{2325}Esc").monospaced() }
            LabeledContent("Pause / resume") { Text("\u{2303}\u{2325}P").monospaced() }
            LabeledContent("Confirm a calibration step") { Text("\u{2303}\u{2325}Space").monospaced() }
        }
    }

    private var testSection: some View {
        Section("Sliding test") {
            Text("Records raw sensor data while you follow a short script of slides across the desk (about 75 seconds). It is only for tuning a sliding mode.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Record a test\u{2026}", action: m.actions.startRecording)
                    .disabled(!m.phase.isActive || m.phase == .connecting || m.recording)
                Spacer()
                if let note = m.recordNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var activitySection: some View {
        Section {
            DisclosureGroup("Activity log") {
                ScrollView {
                    Text(m.log.suffix(80).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.log.joined(separator: "\n"), forType: .string)
                    }
                    Button("Show log file", action: m.actions.openLog)
                    Spacer()
                }
            }
        }
    }
}

// MARK: the card for the current step

private struct StageCard: View {
    @ObservedObject var m: AppModel

    var body: some View {
        if m.recording { RecordCard(m: m) } else { stage }
    }

    @ViewBuilder private var stage: some View {
        switch m.phase {
        case .idle:
            if m.needsPermissions {
                PermissionsCard(m: m)
            } else {
                VStack(spacing: 10) {
                    DemoView(kind: m.mode)
                    Label("If your AirPods are also connected to an iPhone, turn its Bluetooth off first.", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let n = m.notice {
                        Label(n, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
            }
        case .connecting:
            DemoView(fixed: 0, kind: m.mode)
        case .settling:
            VStack(spacing: 10) {
                DemoView(fixed: 2, kind: m.mode)
                ProgressView(value: m.stillProgress) { Text("Keep the case still\u{2026}").font(.callout) }
            }
        case .calibrating(let n):
            if m.mode == 2 { SlideCard(m: m, step: n) } else if m.mode == 1 { GyroCard(m: m, step: n) } else { CalibrationCard(m: m, step: n) }
        case .tapTest:
            TapTestCard(m: m)
        case .practice:
            VStack(spacing: 12) {
                PracticePad(m: m)
                if m.mode == 1 {
                    Text(String(format: "Turning %.0f\u{00B0}/s", m.mouseRate))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if m.mode == 2 {
                    Text("\(m.slideState) \u{00B7} motion \(String(format: "%.2f", m.slideLevel)) g")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if m.mode != 0, let hint = m.mouseHint {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                Text(m.mode == 2
                     ? "Slide the case to move the pointer to a circle, then knock on it (or hold still). They light up when you hit one. Nothing on your Mac is clicked yet."
                     : (m.mode == 1
                        ? "Turn the case to move the pointer to a circle, then knock on it (or hold still). They light up when you hit one. Nothing on your Mac is clicked yet."
                        : "Point at the circles, then knock on the case (or hold still). They light up when you hit one. Nothing on your Mac is clicked yet."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Text("\(m.practiceHits.count) of \(AppModel.practiceTargets.count) hit")
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Spacer()
                    Button("Reset", action: m.actions.resetPractice)
                    if m.mode != 0 { Button("Centre", action: m.actions.recenter) }
                    Button("Recalibrate", action: m.actions.recalibrate)
                    Button("Start pointing", action: m.actions.startLive).buttonStyle(.borderedProminent)
                }
            }
        case .pointing:
            VStack(spacing: 10) {
                Label("Pointing is live", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text("The case now moves your cursor. \u{2303}\u{2325}Esc stops everything.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Back to practice", action: m.actions.backToPractice)
                    Button("Recalibrate", action: m.actions.recalibrate)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: header

private struct Header: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(m.tint.opacity(0.16))
                    Image(systemName: m.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(m.tint)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.title2.weight(.semibold))
                    Text(m.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)

                Button(action: m.actions.toggleConnect) {
                    Text(m.phase == .idle ? "Connect" : "Disconnect").frame(minWidth: 78)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(m.phase == .idle ? Color.accentColor : Color.red)
                .disabled(m.phase == .idle && (m.devices.isEmpty || m.needsPermissions))
            }
            Steps(index: m.setupStep)
        }
        .padding(20)
    }
}

private struct Steps: View {
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepNames.count, id: \.self) { i in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i < index ? Color.green : (i == index ? Color.accentColor : Color.secondary.opacity(0.25)))
                        if i < index {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(i == index ? Color.white : Color.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(stepNames[i])
                        .font(.caption.weight(i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if i < stepNames.count - 1 {
                    Rectangle().fill(i < index ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25)).frame(height: 1)
                }
            }
        }
    }
}
