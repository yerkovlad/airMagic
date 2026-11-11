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
        if s.service == 11 { accel = (v, s.stamp); accelSize = v.norm; return false }
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
                referenceGravity = g.unit; ready = true; window = []
                return true
            }
            if let still = stillStretch(span: firstSpan, gyroLimit: firstGyro, accelLimit: firstAccel) {
                bias = still.bias; referenceGravity = still.gravity.unit
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
        if magnitude > 0.85 && magnitude < 1.15 {
            let expected = q.inverse.rotate(referenceGravity)
            omega = omega + g.unit.cross(expected) * 0.5      // pull toward gravity
        }
        q = (q * Q.exp(omega * dt)).normalized
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
        return (0.5 + x / 2, 0.5 - y / 2)
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

// MARK: taps

/// Spots a sharp knock on the case: the accelerometer jumps while the case is otherwise
/// moving smoothly. `threshold` is in g (of high-passed acceleration).
final class TapDetector {
    var threshold: Double
    private var smooth: V3?
    private var lastStamp: UInt64 = 0
    private var lastTap: UInt64 = 0
    private(set) var lastPeak = 0.0

    init(threshold: Double) { self.threshold = threshold }

    /// Feed accelerometer samples. Returns the tap strength when one fires.
    func feed(_ s: Sample) -> Double? {
        guard s.service == 11 else { return nil }
        let a = V3(Double(s.x), Double(s.y), Double(s.z)) * 1e-5
        guard let base = smooth, s.stamp > lastStamp else { smooth = a; lastStamp = s.stamp; return nil }
        let dt = Double(s.stamp - lastStamp) * 1e-6
        lastStamp = s.stamp
        guard dt > 0, dt < 0.1 else { smooth = a; return nil }
        // low-pass with a ~60 ms time constant; what is left is the knock
        let k = dt / (0.06 + dt)
        smooth = base + (a - base) * k
        let peak = (a - base).norm
        lastPeak = peak
        guard threshold > 0, peak > threshold, s.stamp > lastTap + 450_000 else { return nil }
        lastTap = s.stamp
        return peak
    }
}
