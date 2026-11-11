import Foundation

/// Records the raw motion samples while you follow a script of slides across the desk. The file is for tuning the
/// sliding mode from real data: the markers say what you were asked to do when, and the distances are known
/// (about 10 cm), so a candidate algorithm can be scored against them.
///
/// File format (one record per line): `S,service,stamp_us,x,y,z` for a sample, `M,stamp_us,label` for the moment
/// a step of the script began.
final class SlideRecorder {
    struct Step {
        let label: String
        let seconds: Double
        let prompt: String
    }

    static let script: [Step] = [
        Step(label: "still", seconds: 5, prompt: "Lay the case flat on the desk and keep it still"),
        Step(label: "right", seconds: 4, prompt: "Slide it RIGHT about 10 cm, then stop"),
        Step(label: "left", seconds: 4, prompt: "Slide it LEFT back, about 10 cm, then stop"),
        Step(label: "away", seconds: 4, prompt: "Slide it AWAY from you about 10 cm, then stop"),
        Step(label: "toward", seconds: 4, prompt: "Slide it back TOWARD you, about 10 cm, then stop"),
        Step(label: "right", seconds: 4, prompt: "Slide it RIGHT about 10 cm, then stop"),
        Step(label: "left", seconds: 4, prompt: "Slide it LEFT back, about 10 cm, then stop"),
        Step(label: "away", seconds: 4, prompt: "Slide it AWAY from you about 10 cm, then stop"),
        Step(label: "toward", seconds: 4, prompt: "Slide it back TOWARD you, about 10 cm, then stop"),
        Step(label: "diag-away-right", seconds: 4, prompt: "Slide it diagonally AWAY and RIGHT, about 10 cm"),
        Step(label: "diag-toward-left", seconds: 4, prompt: "Slide it diagonally back TOWARD you and LEFT"),
        Step(label: "slow-right", seconds: 5, prompt: "Slide it RIGHT slowly, 10 cm over about 3 seconds"),
        Step(label: "slow-left", seconds: 5, prompt: "Slide it LEFT slowly, 10 cm over about 3 seconds"),
        Step(label: "fast-right", seconds: 3, prompt: "Slide it RIGHT quickly, about 10 cm"),
        Step(label: "fast-left", seconds: 3, prompt: "Slide it LEFT quickly, about 10 cm"),
        Step(label: "desk-taps", seconds: 5, prompt: "Keep the case still and tap the desk next to it"),
        Step(label: "lift", seconds: 6, prompt: "Pick the case up, move it around, put it back down"),
        Step(label: "still", seconds: 4, prompt: "Keep it still"),
    ]

    static var duration: Double { script.reduce(0) { $0 + $1.seconds } }

    private(set) var samples: [Sample] = []
    private var markers: [(stamp: UInt64, label: String)] = []
    private var lastStamp: UInt64 = 0
    private var start = 0.0
    private var stepIndex = -1

    func begin(now: Double) {
        start = now
        stepIndex = -1
        samples = []
        markers = []
    }

    func add(_ new: [Sample]) {
        samples += new
        if let last = new.last { lastStamp = last.stamp }
    }

    /// Advances the script. Returns the current prompt, overall progress (0...1) and seconds left; nil when the
    /// script is over.
    func tick(now: Double) -> (prompt: String, progress: Double, remaining: Double)? {
        let elapsed = now - start
        guard elapsed < Self.duration else { return nil }
        var t = 0.0
        for (i, step) in Self.script.enumerated() {
            if elapsed < t + step.seconds {
                if i != stepIndex {
                    stepIndex = i
                    markers.append((lastStamp, step.label))
                }
                return (step.prompt, elapsed / Self.duration, Self.duration - elapsed)
            }
            t += step.seconds
        }
        return nil
    }

    func write(to url: URL) throws {
        var text = "# AirMagic sliding test: S,service,stamp_us,x,y,z (raw, 1e-5 g or deg/s) and M,stamp_us,label\n"
        var next = 0
        for s in samples {
            while next < markers.count, markers[next].stamp <= s.stamp {
                text += "M,\(markers[next].stamp),\(markers[next].label)\n"
                next += 1
            }
            text += "S,\(s.service),\(s.stamp),\(s.x),\(s.y),\(s.z)\n"
        }
        while next < markers.count {
            text += "M,\(markers[next].stamp),\(markers[next].label)\n"
            next += 1
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
