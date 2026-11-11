import Foundation

// MARK: sliding mouse (experimental)

/// Moves the pointer when the case is slid across a surface, like a mouse. Experimental: an accelerometer
/// cannot measure distance directly, so this is a best effort tuned on recordings of real slides.
///
/// What it does, and why:
///  - The resting reading (gravity plus the sensor's offset) is learned whenever the case is still, and
///    subtracted. The offset shifts a little after every move, so it is learned again after each stop.
///  - A median filter over five samples drops the knocks and stick-slip spikes of sliding on a hard desk.
///  - A stroke starts when the acceleration along the surface rises, and ends when it has been quiet for 0.1 s.
///    Velocity leaks away slowly (a case with no push cannot keep going) and is forced to zero at the end.
///  - A hard bump (a sharp push up or down) or fast tipping pauses it for 0.4 s: that is a lift or an impact,
///    not a slide.
///  - Directions are fixed in the case's own frame, like the axes of a real mouse: two calibration strokes
///    (right, then away from you) find them, from the main axis of the acceleration and its first push.
final class SlideMouse {
    /// Unit vectors in the case's frame: sliding along `right` moves the pointer right, along `forward`
    /// (away from you) moves it up.
    var right: V3?
    var forward: V3?
    /// Gravity (the rest reading, unit) in the case's frame when calibrated.
    var held: V3?
    var gain = 1.0

    var calibrated: Bool { right != nil && forward != nil }

    /// How far the pointer goes for each metre the case is judged to have moved. The estimate runs short of
    /// the true distance, so this is larger than a real mouse's.
    static let pixelsPerMetre = 4000.0

    private let window = 5
    private let onset = 0.025            // g of acceleration along the surface that starts a stroke
    private let quiet = 0.015            // g below which a stroke is ending
    private let quietTime = 0.10
    private let tau = 0.8                // velocity leak, seconds (picked on recordings of real slides)
    private let maxSpeed = 1.0           // m/s
    private let bumpLimit = 0.3          // g pushing up or down that pauses it
    private let tipLimit = 150.0         // deg/s of tipping that pauses it

    private var bias = V3()
    private var average = V3()
    private var seeded = false
    private var buffers: [[Double]] = [[], [], []]
    private var level = 0.0              // smoothed acceleration along the surface, g
    private(set) var active = false
    private var quietFor = 0.0
    private var frozen = 0.0
    private var velocity = V3()

    // the stroke in progress
    private var cov = [Double](repeating: 0, count: 6)
    private var onsetImpulse = V3()
    private var strokeAge = 0.0
    private var strokePeak = 0.0
    private var finished: V3?

    /// Smoothed acceleration along the surface (g), and a word for the window.
    var activity: Double { level }
    var stateText: String {
        if frozen > 0 { return "Bump or lift: paused" }
        return active ? "Moving" : "Still"
    }

    func reset() {
        seeded = false
        buffers = [[], [], []]
        level = 0; active = false; quietFor = 0; frozen = 0; velocity = V3()
        clearStroke()
        finished = nil
    }

    private func clearStroke() {
        cov = [Double](repeating: 0, count: 6)
        onsetImpulse = V3(); strokeAge = 0; strokePeak = 0
    }

    private func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }

    /// A finished stroke's direction in the case's frame (unit), once, for the calibration steps.
    func takeStroke() -> V3? {
        defer { finished = nil }
        return finished
    }

    /// One step. `accel` is the raw accelerometer reading (g, case frame), `gyro` the rotation rate (deg/s) with its
    /// offset removed. Returns the pointer movement in pixels (x right, y down); zero until calibrated.
    func feed(accel: V3, gyro: V3, dt: Double) -> (dx: Double, dy: Double) {
        guard dt > 0, dt < 0.1 else { velocity = V3(); return (0, 0) }
        if !seeded { bias = accel; average = accel; seeded = true }
        let upDirection = bias.unit
        let lin = accel - bias
        for (i, c) in [lin.x, lin.y, lin.z].enumerated() {
            buffers[i].append(c)
            if buffers[i].count > window { buffers[i].removeFirst() }
        }
        let m = V3(median(buffers[0]), median(buffers[1]), median(buffers[2]))
        let vertical = m.dot(upDirection)
        let flat = m - upDirection * vertical
        level += (flat.norm - level) * dt / (0.05 + dt)
        let tip = max(0, gyro.dot(gyro) - pow(gyro.dot(upDirection), 2)).squareRoot()

        if abs(vertical) > bumpLimit || tip > tipLimit {
            frozen = 0.4
        }
        if frozen > 0 {
            frozen -= dt
            velocity = V3()
            if active { endStroke() }
            active = false
            return (0, 0)
        }

        if !active {
            average = average + (accel - average) * (dt / (0.3 + dt))
            if level > onset {
                active = true; quietFor = 0; clearStroke()
            } else {
                bias = bias + (average - bias) * min(1, dt / 0.3)      // learn the resting reading
            }
        }
        guard active else { return (0, 0) }

        strokeAge += dt
        strokePeak = max(strokePeak, flat.norm)
        if flat.norm > 0.015 {
            cov[0] += flat.x * flat.x; cov[1] += flat.x * flat.y; cov[2] += flat.x * flat.z
            cov[3] += flat.y * flat.y; cov[4] += flat.y * flat.z; cov[5] += flat.z * flat.z
            if strokeAge < 0.2 { onsetImpulse = onsetImpulse + flat * dt }
        }
        velocity = velocity * exp(-dt / tau) + flat * (9.81 * dt)
        if velocity.norm > maxSpeed { velocity = velocity * (maxSpeed / velocity.norm) }
        let step = velocity * dt

        quietFor = level < quiet ? quietFor + dt : 0
        if quietFor >= quietTime {
            active = false
            velocity = V3()
            endStroke()
        }
        guard let r = right, let f = forward else { return (0, 0) }
        let k = Self.pixelsPerMetre * gain
        return (step.dot(r) * k, -step.dot(f) * k)
    }

    private func endStroke() {
        defer { clearStroke() }
        guard strokePeak >= 0.06, strokeAge >= 0.15 else { return }
        let up = bias.unit
        func flatten(_ v: V3) -> V3 { v - up * v.dot(up) }
        func times(_ v: V3) -> V3 {
            V3(cov[0] * v.x + cov[1] * v.y + cov[2] * v.z,
               cov[1] * v.x + cov[3] * v.y + cov[4] * v.z,
               cov[2] * v.x + cov[4] * v.y + cov[5] * v.z)
        }
        let start = flatten(onsetImpulse)
        guard start.norm > 1e-9 else { return }
        var axis = start.unit
        for _ in 0..<40 {
            let next = flatten(times(axis))
            if next.norm < 1e-12 { return }
            axis = next.unit
        }
        if axis.dot(start) < 0 { axis = axis * -1 }               // pointing the way the first push went
        finished = axis
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let r = right, let f = forward, let h = held else { return }
        defaults.set(r.array, forKey: "slide.right"); defaults.set(f.array, forKey: "slide.forward"); defaults.set(h.array, forKey: "slide.held")
    }
    func load(_ defaults: UserDefaults = .standard) {
        right = V3(defaults.array(forKey: "slide.right") as? [Double])
        forward = V3(defaults.array(forKey: "slide.forward") as? [Double])
        held = V3(defaults.array(forKey: "slide.held") as? [Double])
        if right == nil || forward == nil || held == nil { forget(defaults) }
    }
    func forget(_ defaults: UserDefaults = .standard) {
        right = nil; forward = nil; held = nil
        for k in ["slide.right", "slide.forward", "slide.held"] { defaults.removeObject(forKey: k) }
    }
}
