import Foundation

// Turns raw accelerometer / gyroscope samples into a pose, the pose into a screen
// position, and sudden jolts into taps.
//
// Raw units: every sample component is an Int32 scaled by 1e-5, so accelerometer
// values are in g and gyroscope values are in degrees per second.

struct V3 {
    var x = 0.0, y = 0.0, z = 0.0
    init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, k: Double) -> V3 { V3(a.x * k, a.y * k, a.z * k) }
    var norm: Double { (x * x + y * y + z * z).squareRoot() }
    var unit: V3 { let n = norm; return n < 1e-12 ? self : self * (1 / n) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var array: [Double] { [x, y, z] }
    init?(_ a: [Double]?) {
        guard let a, a.count == 3, a.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(a[0], a[1], a[2])
    }
}

struct Q {
    var w = 1.0, x = 0.0, y = 0.0, z = 0.0
    static let identity = Q()
    var inverse: Q { Q(w: w, x: -x, y: -y, z: -z) }
    static func * (a: Q, b: Q) -> Q {
        Q(w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
          x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
          y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
          z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }
    var normalized: Q {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return n < 1e-12 ? .identity : Q(w: w / n, x: x / n, y: y / n, z: z / n)
    }
    func rotate(_ v: V3) -> V3 {
        let r = self * Q(w: 0, x: v.x, y: v.y, z: v.z) * inverse
        return V3(r.x, r.y, r.z)
    }
    /// Rotation by `rate` (radians) about its own direction.
    static func exp(_ rate: V3) -> Q {
        let angle = rate.norm
        if angle < 1e-12 { return .identity }
        let a = rate * (1 / angle)
        let s = sin(angle / 2)
        return Q(w: cos(angle / 2), x: a.x * s, y: a.y * s, z: a.z * s)
    }
    /// The rotation as a vector (axis * angle, radians).
    var rotationVector: V3 {
        var q = self
        if q.w < 0 { q = Q(w: -q.w, x: -q.x, y: -q.y, z: -q.z) }
        let v = V3(q.x, q.y, q.z), n = v.norm
        return n < 1e-10 ? V3() : v * (2 * atan2(n, q.w) / n)
    }
}

// MARK: orientation

final class Orientation {
    private(set) var q = Q.identity
    private(set) var ready = false
    private(set) var bias = V3()
    private(set) var referenceGravity = V3(0, 0, 1)
    /// 0...1 progress of the first still stretch (for the setup prompt).
    private(set) var settling = 0.0
    /// Latest readings, for on-screen diagnostics: accelerometer size in g, gyro size (offset removed) in deg/s.
    private(set) var accelSize = 0.0
    private(set) var gyroSize = 0.0
    private(set) var pairs = 0
    /// Size of gravity as the accelerometer reads it at rest, in g.
    private(set) var referenceMagnitude = 1.0
    /// Seconds covered by the last pose update.
    private(set) var lastDt = 0.0
    /// Rotation rate in the case's frame with the resting offset removed, deg/s.
    private(set) var gyroBody = V3()
    /// The raw accelerometer reading in the case's frame, in g.
    private(set) var accelBody = V3()
    /// How far the accelerometer may be from 1 g and still correct the tilt. Sliding needs this tight.
    var gravityTolerance = 0.15
    /// The direction "up" (against gravity) in the case's frame right now.
    var upBody: V3 { q.inverse.rotate(referenceGravity).unit }
    /// Spread of the latest still window (gyro deg/s, accel g), for diagnostics.
    private(set) var spreadGyro = 0.0
    private(set) var spreadAccel = 0.0

    private var accel: (v: V3, stamp: UInt64)?
    private var lastGyro: UInt64?
    private var window: [(stamp: UInt64, gyro: V3, accel: V3)] = []
    private var seeded = false

    private let firstSpan = 1.2e6, firstGyro = 2.0, firstAccel = 0.08
    private let steadySpan = 1.8e6, steadyGyro = 0.8, steadyAccel = 0.04

    init(seedBias: V3? = nil) {
        if let seedBias, seedBias.norm < 5 { bias = seedBias; seeded = true }
    }

    func reset() {
        q = .identity; ready = false; window = []; lastGyro = nil; settling = 0
    }

    private func stillStretch(span: Double, gyroLimit: Double, accelLimit: Double) -> (bias: V3, gravity: V3)? {
        guard let first = window.first, let last = window.last, Double(last.stamp - first.stamp) >= span else { return nil }
        let n = Double(window.count)
        let g = window.reduce(V3()) { $0 + $1.gyro } * (1 / n)
        let a = window.reduce(V3()) { $0 + $1.accel } * (1 / n)
        let sg = (window.reduce(0.0) { $0 + ($1.gyro - g).norm * ($1.gyro - g).norm } / n).squareRoot()
        let sa = (window.reduce(0.0) { $0 + ($1.accel - a).norm * ($1.accel - a).norm } / n).squareRoot()
        spreadGyro = sg; spreadAccel = sa
        return sg <= gyroLimit && sa <= accelLimit ? (g, a) : nil
    }

    /// Returns true when the pose was advanced.
    @discardableResult
    func feed(_ s: Sample) -> Bool {
        let v = V3(Double(s.x), Double(s.y), Double(s.z)) * 1e-5
        if s.service == 11 { accel = (v, s.stamp); accelSize = v.norm; accelBody = v; return false }
        guard s.service == 12, let a = accel, abs(Int64(s.stamp) - Int64(a.stamp)) < 100_000 else { return false }

        var dt = 0.0
        if let last = lastGyro {
            guard s.stamp > last else { return false }
            dt = Double(s.stamp - last) * 1e-6
            if dt > 0.2 {            // a gap: hold briefly, start over if long
                lastGyro = s.stamp
                if dt >= 2 { reset(); lastGyro = s.stamp }
                return false
            }
        }
        lastGyro = s.stamp
        let g = a.v, magnitude = g.norm
        gyroSize = (v - bias).norm
        gyroBody = v - bias
        pairs += 1

        // Collect still samples: they give the gyro's resting offset.
        if magnitude < 0.85 || magnitude > 1.15 || v.norm > 5 {
            window = []; if !ready { settling = 0 }
        } else {
            window.append((s.stamp, v, g))
            let span = ready ? steadySpan : firstSpan
            while let f = window.first, Double(s.stamp - f.stamp) > span + 0.4e6 { window.removeFirst() }
            if !ready, let f = window.first { settling = min(1, Double(s.stamp - f.stamp) / firstSpan) }
        }

        if !ready {
            if seeded, magnitude > 0.95, magnitude < 1.05 {
                referenceGravity = g.unit; referenceMagnitude = magnitude; ready = true; window = []
                return true
            }
            if let still = stillStretch(span: firstSpan, gyroLimit: firstGyro, accelLimit: firstAccel) {
                bias = still.bias; referenceGravity = still.gravity.unit; referenceMagnitude = still.gravity.norm
                seeded = true; ready = true; window = []
                return true
            }
            return false
        }

        if let still = stillStretch(span: steadySpan, gyroLimit: steadyGyro, accelLimit: steadyAccel) {
            // move the offset halfway, never more than 0.1 deg/s, so a slow turn can't pass for drift
            let step = still.bias - bias
            let k = min(0.5, 0.1 / max(step.norm, 1e-9))
            bias = bias + step * k
            window = []
        }
        guard dt > 0 else { return false }
        var omega = (v - bias) * (Double.pi / 180)
        if abs(magnitude - referenceMagnitude) < gravityTolerance {
            let expected = q.inverse.rotate(referenceGravity)
            omega = omega + g.unit.cross(expected) * 0.5      // pull toward gravity
        }
        q = (q * Q.exp(omega * dt)).normalized
        lastDt = dt
        return true
    }
}

// MARK: aiming

/// Maps a pose to a screen position. `center` is where the case points at the screen
/// middle; `right` and `up` are the rotation vectors that reach the middle of the right
/// and top screen edges.
final class Aim {
    var center: Q?
    var right: V3?
    var up: V3?
    /// Gravity in the case's frame at the centre pose; tells whether it is held the same way.
    var held: V3?
    /// How far the pointer travels for a given turn: above 1 is faster.
    var gain = 1.0
    var invertX = false
    var invertY = false

    var calibrated: Bool { center != nil && right != nil && up != nil }

    func relative(_ q: Q) -> V3? {
        guard let c = center else { return nil }
        return (c.inverse * q).rotationVector
    }

    func setCenter(_ q: Q, referenceGravity: V3) {
        center = q
        held = q.inverse.rotate(referenceGravity).unit
    }

    /// Re-centres keeping the saved edges when the case is held the same way.
    func recenter(_ q: Q, referenceGravity: V3) -> Bool {
        let now = q.inverse.rotate(referenceGravity).unit
        let keep = calibrated && (held.map { $0.dot(now) >= cos(35 * Double.pi / 180) } ?? false)
        center = q
        if !keep { right = nil; up = nil; held = now }
        return keep
    }

    enum AimError: Error { case tooSmall, sameDirection }

    func setEdge(right isRight: Bool, _ q: Q) throws {
        guard let v = relative(q) else { return }
        let degrees = v.norm * 180 / Double.pi
        guard degrees >= 10, degrees <= 70 else { throw AimError.tooSmall }
        let other = isRight ? up : right
        if let o = other, abs(v.dot(o)) / (v.norm * o.norm) > 0.88 { throw AimError.sameDirection }
        if isRight { right = v } else { up = v }
    }

    /// Screen position in 0...1 (x to the right, y downward), or nil before calibration.
    func point(_ q: Q) -> (x: Double, y: Double)? {
        guard let v = relative(q), let r = right, let u = up else { return nil }
        let rr = r.dot(r), uu = u.dot(u), ru = r.dot(u)
        let d = rr * uu - ru * ru
        guard abs(d) > 1e-9 else { return nil }
        let x = (v.dot(r) * uu - v.dot(u) * ru) / d
        let y = (v.dot(u) * rr - v.dot(r) * ru) / d
        return (0.5 + (invertX ? -1 : 1) * gain * x / 2, 0.5 - (invertY ? -1 : 1) * gain * y / 2)
    }

    // saved between runs
    func save(_ defaults: UserDefaults = .standard) {
        if let r = right, let u = up, let h = held {
            defaults.set(r.array, forKey: "aim.right"); defaults.set(u.array, forKey: "aim.up"); defaults.set(h.array, forKey: "aim.held")
        }
    }
    func load(_ defaults: UserDefaults = .standard) {
        right = V3(defaults.array(forKey: "aim.right") as? [Double])
        up = V3(defaults.array(forKey: "aim.up") as? [Double])
        held = V3(defaults.array(forKey: "aim.held") as? [Double])
        // edges outside a sensible range come from a bad calibration: drop them
        for e in [right, up] {
            guard let e else { continue }
            let deg = e.norm * 180 / Double.pi
            if deg < 10 || deg > 70 { forget(defaults); return }
        }
    }
    func forget(_ defaults: UserDefaults = .standard) {
        right = nil; up = nil; held = nil
        for k in ["aim.right", "aim.up", "aim.held"] { defaults.removeObject(forKey: k) }
    }
}

// MARK: smoothing

/// One Euro filter: steady when slow, quick when fast.
final class OneEuro {
    var minCutoff: Double
    let beta: Double
    private var x: Double?
    private var dx = 0.0
    private var t = 0.0

    init(minCutoff: Double = 1.2, beta: Double = 0.05) { self.minCutoff = minCutoff; self.beta = beta }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        1 / (1 + (1 / (2 * Double.pi * cutoff)) / dt)
    }

    func filter(_ value: Double, at time: Double) -> Double {
        guard let previous = x else { x = value; t = time; return value }
        let dt = max(time - t, 0.001)
        t = time
        dx += alpha(1, dt) * ((value - previous) / dt - dx)
        let result = previous + alpha(minCutoff + beta * abs(dx), dt) * (value - previous)
        x = result
        return result
    }

    func reset() { x = nil; dx = 0 }
}

// MARK: gyro mouse

/// A relative pointer, like an air mouse: turning the case moves the pointer, and when it stops turning the
/// pointer stops. Two turning axes are found once (turn it to the right, tip it up); after that the pointer
/// moves by the rotation rate about each, with a small dead zone, a short median filter that drops the jolt of
/// a knock, and a gentle acceleration curve (quick turns go further, slow ones stay precise).
final class GyroMouse {
    /// Unit rotation axes in the case's frame: turning about `right` (right-hand rule) moves the pointer to the
    /// right, turning about `up` moves it up.
    var right: V3?
    var up: V3?
    /// Gravity (the accelerometer's rest reading, unit) in the case's frame when calibrated.
    var held: V3?
    var gain = 1.0
    /// Seconds of low-pass on the rotation rate; 0 is raw.
    var smoothing = 0.0

    var calibrated: Bool { right != nil && up != nil }

    static let deadZone = 2.5              // deg/s: slower turning is ignored
    private let pixelsPerDegree = 14.0

    private var recent: [(r: Double, u: Double)] = []
    private var filtered = (r: 0.0, u: 0.0)
    private(set) var spin = V3()           // radians turned in the current gesture
    private var active = false
    private var quiet = 0.0

    var spinDegrees: Double { spin.norm * 180 / Double.pi }

    func resetGesture() { spin = V3(); active = false; quiet = 0 }
    func resetMotion() { recent = []; filtered = (0, 0) }

    private func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    /// Pointer movement in pixels (x right, y down) for one step of rotation `gyro` (deg/s, case frame).
    func feed(gyro: V3, dt: Double) -> (dx: Double, dy: Double) {
        guard let r = right, let u = up, dt > 0, dt < 0.1 else { return (0, 0) }
        recent.append((gyro.dot(r), gyro.dot(u)))
        if recent.count > 5 { recent.removeFirst() }
        // a knock is a spike of a few samples; the median of the last five passes real turning and drops it
        var wr = median(recent.map { $0.r }), wu = median(recent.map { $0.u })
        if smoothing > 0 {
            let k = dt / (smoothing + dt)
            filtered.r += (wr - filtered.r) * k
            filtered.u += (wu - filtered.u) * k
            wr = filtered.r; wu = filtered.u
        }
        func dead(_ w: Double) -> Double { abs(w) <= Self.deadZone ? 0 : w - (w > 0 ? Self.deadZone : -Self.deadZone) }
        wr = dead(wr); wu = dead(wu)
        let speed = (wr * wr + wu * wu).squareRoot()
        let k = pixelsPerDegree * gain * (1 + speed / 90) * dt
        return (wr * k, -wu * k)
    }

    /// Calibration: follows a turn of the case. Returns its axis (unit, right-hand rule) once the case has turned
    /// at least `minimumDegrees` and been held still for 0.3 s. A twitch is forgotten.
    func trackGesture(gyro: V3, dt: Double, minimumDegrees: Double) -> V3? {
        let speed = gyro.norm
        if speed > 15 { active = true }
        guard active else { return nil }
        if speed >= 6 {
            quiet = 0
            spin = spin + gyro * (Double.pi / 180 * dt)
            return nil
        }
        quiet += dt
        guard quiet >= 0.3 else { return nil }
        let turned = spin
        resetGesture()
        return turned.norm * 180 / Double.pi >= minimumDegrees ? turned.unit : nil
    }

    /// Some unit vector perpendicular to `v`.
    static func anyPerpendicular(to v: V3) -> V3 {
        let probe = abs(v.x) < 0.8 ? V3(1, 0, 0) : V3(0, 1, 0)
        return v.cross(probe).unit
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let r = right, let u = up, let h = held else { return }
        defaults.set(r.array, forKey: "gyro.right"); defaults.set(u.array, forKey: "gyro.up"); defaults.set(h.array, forKey: "gyro.held")
    }
    func load(_ defaults: UserDefaults = .standard) {
        right = V3(defaults.array(forKey: "gyro.right") as? [Double])
        up = V3(defaults.array(forKey: "gyro.up") as? [Double])
        held = V3(defaults.array(forKey: "gyro.held") as? [Double])
        if right == nil || up == nil || held == nil { forget(defaults) }
    }
    func forget(_ defaults: UserDefaults = .standard) {
        right = nil; up = nil; held = nil
        for k in ["gyro.right", "gyro.up", "gyro.held"] { defaults.removeObject(forKey: k) }
    }
}

// MARK: taps

/// Spots a knock on the case. Tuned on recordings of real taps (and of handling that is
/// not a tap): a knock is a short, sharp spike in the accelerometer after a calm
/// stretch, while aiming and handling make wider bumps while the case is moving.
///
///  - the spike (high-passed acceleration) must exceed `threshold` (in g),
///  - it must be narrow: at most 10 samples (about 50 ms at 200 Hz) above 40% of its peak,
///  - the case must have been calm just before: small acceleration wobble and slow rotation.
///
/// The verdict comes 100 ms after the impact, so a click uses where the pointer was before it.
final class TapDetector {
    var threshold: Double
    private var smooth: V3?
    private var lastStamp: UInt64 = 0
    private var hp: [(t: Double, v: Double)] = []
    private var gyro: [(t: Double, v: Double)] = []
    private var candidate: (t0: Double, peak: Double)?
    private var lastTap = -1e9
    /// The current high-passed acceleration size, in g.
    private(set) var lastPeak = 0.0
    /// The largest bump in roughly the last half second (for on-screen feedback).
    private(set) var recentPeak = 0.0

    init(threshold: Double) { self.threshold = threshold }

    /// Feed every accelerometer and gyroscope sample. Returns the knock strength when one is confirmed.
    func feed(_ s: Sample) -> Double? {
        let t = Double(s.stamp) * 1e-6
        if s.service == 12 {
            gyro.append((t, V3(Double(s.x), Double(s.y), Double(s.z)).norm * 1e-5))
            while let f = gyro.first, t - f.t > 0.6 { gyro.removeFirst() }
            return nil
        }
        guard s.service == 11 else { return nil }
        let a = V3(Double(s.x), Double(s.y), Double(s.z)) * 1e-5
        guard let base = smooth, s.stamp > lastStamp else { smooth = a; lastStamp = s.stamp; return nil }
        let dt = Double(s.stamp - lastStamp) * 1e-6
        lastStamp = s.stamp
        guard dt > 0, dt < 0.1 else { smooth = a; candidate = nil; return nil }

        // low-pass with a ~60 ms time constant; what is left is the knock
        let k = dt / (0.06 + dt)
        smooth = base + (a - base) * k
        let v = (a - base).norm
        lastPeak = v
        recentPeak = max(recentPeak * pow(0.5, dt / 0.4), v)
        hp.append((t, v))
        while let f = hp.first, t - f.t > 0.6 { hp.removeFirst() }
        guard threshold > 0 else { candidate = nil; return nil }

        if var c = candidate {
            c.peak = max(c.peak, v)
            candidate = c
            guard t - c.t0 >= 0.1 else { return nil }
            candidate = nil
            return judge(c)
        }
        if v > threshold, t > lastTap + 0.45 { candidate = (t, v) }
        return nil
    }

    private func judge(_ c: (t0: Double, peak: Double)) -> Double? {
        let width = hp.filter { abs($0.t - c.t0) <= 0.1 && $0.v > 0.4 * c.peak }.count
        let before = hp.filter { $0.t >= c.t0 - 0.25 && $0.t < c.t0 - 0.03 }.map { $0.v }
        let turning = gyro.filter { $0.t >= c.t0 - 0.25 && $0.t < c.t0 - 0.03 }.map { $0.v }
        let wobble = before.isEmpty ? 0 : before.reduce(0, +) / Double(before.count)
        let rotation = turning.isEmpty ? 0 : turning.reduce(0, +) / Double(turning.count)
        guard width <= 10, wobble <= 0.08, rotation <= 25 else { return nil }
        lastTap = c.t0
        return c.peak
    }
}
