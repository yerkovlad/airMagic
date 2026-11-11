import SwiftUI

/// Where the session is, as the window shows it.
enum Phase: Equatable {
    case idle, connecting, settling, calibrating(Int), tapTest, practice, pointing

    var isActive: Bool { self != .idle }
}

struct DeviceInfo: Identifiable, Equatable {
    let id: String        // Bluetooth address
    let name: String
    let connected: Bool
}

/// A click made in the practice pad (the real cursor is not touched).
struct PracticeClick: Equatable {
    let id: Int
    let pos: CGPoint      // 0...1 on the pad
    let time: Date
}

/// What the window can ask the app to do.
struct Actions {
    var toggleConnect: () -> Void = {}
    var confirmStep: () -> Void = {}
    var recenter: () -> Void = {}
    var recalibrate: () -> Void = {}
    var togglePause: () -> Void = {}
    var testTaps: () -> Void = {}
    var skipTapTest: () -> Void = {}
    var startLive: () -> Void = {}
    var backToPractice: () -> Void = {}
    var resetPractice: () -> Void = {}
    var setTap: (Double) -> Void = { _ in }
    var setDwell: (Int) -> Void = { _ in }
    var setGain: (Double) -> Void = { _ in }
    var setSmooth: (Double) -> Void = { _ in }
    var setMode: (Int) -> Void = { _ in }
    var setInvertX: (Bool) -> Void = { _ in }
    var setInvertY: (Bool) -> Void = { _ in }
    var selectDevice: (String) -> Void = { _ in }
    var openAccessibility: () -> Void = {}
    var openBluetooth: () -> Void = {}
    var openLog: () -> Void = {}
    var startRecording: () -> Void = {}
    var stopRecording: () -> Void = {}
}

/// Everything the window shows. The app delegate owns the truth and copies it here.
final class AppModel: ObservableObject {
    @Published var phase = Phase.idle
    @Published var paused = false
    @Published var notice: String?
    @Published var devices: [DeviceInfo] = []
    @Published var selectedAddress = ""
    @Published var lidClosed = false

    @Published var calibrated = false
    @Published var stillProgress = 0.0
    @Published var holdProgress = 0.0

    @Published var tapThreshold = 0.25
    @Published var dwellIdx = 0
    @Published var gain = 1.0
    @Published var smoothness = 0.7
    /// 0 aim in the air, 1 gyro mouse (turn the case, relative), 2 slide on a surface (experimental).
    @Published var mode = 0
    @Published var invertX = false
    @Published var invertY = false
    /// Mouse mode: a hint after a calibration turn, how fast the case is turning now (deg/s) and how far it has
    /// turned in the current calibration gesture (deg).
    @Published var mouseHint: String?
    @Published var mouseRate = 0.0
    @Published var mouseSpin = 0.0
    /// Slide mode: what the sliding mouse sees now ("Still", "Moving"...) and the motion along the surface (g).
    @Published var slideState = ""
    @Published var slideLevel = 0.0
    @Published var lastKnock = 0.0
    @Published var noise = 0.0
    @Published var tapTestCount = 0

    @Published var rate = 0
    @Published var accel = 0.0
    @Published var gyro = 0.0
    @Published var turned = 0.0
    @Published var pos: CGPoint?
    @Published var practiceHits: Set<Int> = []
    @Published var practiceClick: PracticeClick?

    @Published var recording = false
    @Published var recordPrompt = ""
    @Published var recordProgress = 0.0
    @Published var recordRemaining = 0.0
    @Published var recordNote: String?

    @Published var accessibilityOK = false
    @Published var bluetoothStatus = "Unknown"
    @Published var bluetoothOK = false

    @Published var log: [String] = []

    let dwellNames = ["Off", "0.7 s", "1.0 s", "1.5 s"]
    var actions = Actions()

    /// Circles to point at in the practice pad (0...1 on a 16:10 screen).
    static let practiceTargets: [CGPoint] = [
        CGPoint(x: 0.14, y: 0.22), CGPoint(x: 0.50, y: 0.18), CGPoint(x: 0.86, y: 0.22),
        CGPoint(x: 0.14, y: 0.78), CGPoint(x: 0.50, y: 0.82), CGPoint(x: 0.86, y: 0.78),
    ]
}
