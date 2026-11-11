import Foundation

/// Offline checks. They need no AirPods; they pin down the wire format, the
/// case conversation, the pose maths and the tap detector.
enum SelfTest {
    private static var failures = 0
    private static var count = 0

    private static func check(_ ok: Bool, _ label: String) {
        count += 1
        if !ok { failures += 1; print("FAIL: \(label)") }
    }

    private static func raw(_ v: Double) -> Int32 { Int32((v * 1e5).rounded()) }

    private static func motionPacket(service: UInt8, stamp: UInt64, x: Int32, y: Int32, z: Int32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        var report = [UInt8](repeating: 0, count: 28)
        report[0] = 1
        report.replaceSubrange(1..<5, with: le32(UInt32(bitPattern: x)))
        report.replaceSubrange(5..<9, with: le32(UInt32(bitPattern: y)))
        report.replaceSubrange(9..<13, with: le32(UInt32(bitPattern: z)))
        report.replaceSubrange(20..<24, with: le32(UInt32(stamp & 0xffff_ffff)))
        report.replaceSubrange(24..<28, with: le32(UInt32(stamp >> 32)))
        let inner: [UInt8] = [8, service, 0x1a, 28] + report
        let outer: [UInt8] = [0x3a, UInt8(inner.count)] + inner
        let n = outer.count
        return [4, 0, 4, 0, 0x17, 0, 0, 0, 0x10, 0, UInt8(n & 255), UInt8(n >> 8)] + outer
    }

    private static func modelReply(_ name: String) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [0, 0, 0, 0, 0, 2, 0, 0, 0, UInt8(bytes.count)] + bytes
    }

    static func run() -> Int32 {
        wire()
        conversation()
        pose()
        taps()
        gyroMouse()
        slideMouse()
        recorder()
        recordedTaps()
        recordedSlide()
        print(failures == 0 ? "PASS: \(count) checks" : "FAILED: \(failures) of \(count) checks")
        return failures == 0 ? 0 : 1
    }

    // MARK: wire

    private static func wire() {
        // sensor start message, byte for byte
        let expected: [UInt8] = [4, 0, 4, 0, 0x17, 0, 0, 0, 0x10, 0, 16, 0,
                                 8, 0xc1, 0x3e, 66, 11, 8, 11, 16, 2, 26, 5, 1, 0x88, 0x13, 0, 0]
        check(Wire.sensorSetting(service: 11, interval: 5000, sequence: 8001) == expected, "sensor start bytes")
        check(Wire.sensorSetting(service: 12, interval: 0, sequence: 8002).suffix(4) == [0, 0, 0, 0], "sensor stop interval")

        // a motion report split across two reads, preceded by junk
        let packet = motionPacket(service: 11, stamp: 0x1_0000_0002, x: -123_456, y: 7, z: 100_000)
        let parser = Parser()
        var events = parser.feed([9, 9, 9] + Array(packet[0..<10]))
        check(events.isEmpty, "partial packet waits")
        events = parser.feed(Array(packet[10...]))
        if case .motion(let s)? = events.first {
            check(s.service == 11 && s.stamp == 0x1_0000_0002 && s.x == -123_456 && s.y == 7 && s.z == 100_000, "motion fields")
        } else { check(false, "motion decoded") }

        // a report flagged invalid is dropped
        var bad = motionPacket(service: 12, stamp: 5, x: 1, y: 2, z: 3)
        bad[12 + 6 + 4 + 2 - 0] = bad[12 + 6 + 4 + 2 - 0]   // keep layout; flip the valid byte below
        if let i = bad.firstIndex(of: 0x1a) { bad[i + 2] = 0 }
        check(Parser().feed(bad).isEmpty, "invalid report dropped")

        // UARP envelope round trip, and a location report
        let uarp = Wire.uarp(type: 2, id: 77, body: [0, 0, 0, 6])
        let located: [UInt8] = [4, 0, 4, 0, 6, 0, 3, 2]
        let two = Parser().feed(uarp + located)
        check(two.count == 2, "two events")
        if case .uarp(let t, let id, let body)? = two.first { check(t == 2 && id == 77 && body == [0, 0, 0, 6], "uarp fields") } else { check(false, "uarp decoded") }
        if case .location(let p, let s)? = two.last { check(p == 3 && s == 2, "location fields") } else { check(false, "location decoded") }

        // another device reported by the AirPods (opcode 0x11 carries its address, reversed)
        let peerParser = Parser()
        _ = peerParser.feed([4, 0, 4, 0, 0x11, 0, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x83, 0, 1, 0xe5])
        check(peerParser.peers == ["01:23:45:67:89:AB"], "another connected device is noticed")

        // names
        check(Wire.modelName(modelReply("AirPods")) == "AirPods", "model name")
        check(Wire.modelName([0, 0, 0, 0, 0, 2, 0, 0, 0, 9, 65]) == nil, "model name length")
        check(Wire.isEarbud("AirPods") && Wire.isEarbud("AirPods Pro") && !Wire.isEarbud("AirPods Charging Case"), "earbud names")
        check(Wire.isCase("Wireless Charging Case") && Wire.isCase("Charging Case") && !Wire.isCase("AirPods"), "case names")

        // a case frame is wrapped for endpoint 1
        let frame = Wire.caseFrame(type: 3, childID: 9, body: [0, 0, 0, 2], rootID: 4)
        let parsed = Parser().feed(frame)
        if case .uarp(let t, _, let body)? = parsed.first {
            check(t == 0x1b && Array(body[0..<2]) == [0, 1] && Wire.be16(body, 2) == 3 && Wire.be16(body, 6) == 9, "case frame layout")
        } else { check(false, "case frame decoded") }
    }

    // MARK: conversation

    private static func conversation() {
        let s = Session()
        var now = 100.0
        var sent = [[UInt8]]()
        s.clock = { now }
        s.send = { sent.append($0); return true }

        func lastUarp() -> (type: UInt16, body: [UInt8])? {
            guard let last = sent.last, case .uarp(let t, _, let b)? = Parser().feed(last).first else { return nil }
            return (t, b)
        }
        func caseFrameType() -> UInt16? {
            guard let u = lastUarp(), u.type == 0x1b else { return nil }
            return Wire.be16(u.body, 2)
        }
        func caseReply(_ type: UInt16, _ id: UInt16, _ body: [UInt8]) {
            s.handle(type: 0x1b, id: 1, body: [0, 1] + Wire.put16(type) + Wire.put16(UInt16(body.count)) + Wire.put16(id) + body)
        }

        s.tick()
        check(lastUarp()?.type == 1, "heartbeat asks the earbud for its version")
        s.handle(type: 2, id: 1, body: [0, 0, 0, 5])
        check(lastUarp()?.type == 3 && s.rootVersionValid, "then asks for its model")
        s.handle(type: 4, id: 2, body: modelReply("AirPods"))
        check(s.rootVerified, "earbud verified")
        s.tick()
        check(lastUarp()?.type == 0x15, "discovery after verification")
        s.handle(type: 0x17, id: 3, body: [0, 1])
        check(lastUarp()?.type == 0x18 && s.caseActive, "case endpoint acknowledged")

        let before = sent.count
        now += 1; s.tick()
        check(sent.count == before + 1 && lastUarp()?.type == 1, "open lid: only the earbud heartbeat")

        s.location(3, 0)
        check(s.lidClosed, "lid closed on code 3")
        s.tick()
        check(caseFrameType() == 1, "lid closed: case version request")
        caseReply(2, 1, [0, 0, 0, 6])
        now += 0.1; s.tick()
        check(caseFrameType() == 3, "case model request")
        caseReply(4, 2, modelReply("Wireless Charging Case"))
        check(s.caseVerified, "case verified")
        now += 0.1; s.tick()
        check(caseFrameType() == 0x11, "keep-alive solicitation")
        caseReply(0x12, 3, [0, 0, 0, 0] + Array("MTIC".utf8))
        now += 1.1; s.tick()
        check(caseFrameType() == 0x11, "solicitation repeats every second")

        // the case offers an asset: accept it, then keep it open with model queries
        caseReply(0x12, 4, [0, 0, 0, 0] + Array("MTIC".utf8))
        var offer = [UInt8](repeating: 0, count: 30)
        offer.replaceSubrange(0..<4, with: Array("MTIC".utf8))
        offer[5] = 0x0a; offer[7] = 0x21; offer[27] = 0x40
        caseReply(5, 5, offer)
        now += 0.1; s.tick()
        check(caseFrameType() == 0x0d && s.accepted, "offer accepted")
        now += 1.1; s.tick()
        check(caseFrameType() == 3, "model query keeps the stream open")
        caseReply(4, 6, modelReply("Wireless Charging Case"))
        check(s.failure == nil, "no failure so far")

        s.beginCleanup()
        check(caseFrameType() == 9 && s.cleanupSent, "asset released on exit")
        caseReply(0x0f, 7, [0, 0x21, 0, 3])
        check(s.cleanupAck, "release acknowledged")

        // a replayed reply stops the session
        let r = Session()
        r.clock = { 1 }; r.send = { _ in true }
        r.handle(type: 0x17, id: 1, body: [0, 1])
        let wrapped: [UInt8] = [0, 1] + Wire.put16(2) + Wire.put16(4) + Wire.put16(9) + [0, 0, 0, 6]
        r.handle(type: 0x1b, id: 1, body: wrapped)
        r.handle(type: 0x1b, id: 2, body: wrapped)
        check(r.failure == nil, "a repeated reply is ignored")

        // lid toggling by two quick (2,2) reports
        let l = Session()
        var t = 5.0
        l.clock = { t }
        l.location(2, 2); t += 0.2; l.location(2, 2)
        check(l.lidClosed, "double (2,2) toggles closed")
        t += 3; l.location(2, 2); t += 0.2; l.location(2, 2)
        check(!l.lidClosed, "second pair toggles open")
    }

    // MARK: pose

    private static func feedStill(_ o: Orientation, from: UInt64, seconds: Double) -> UInt64 {
        var stamp = from
        let end = from + UInt64(seconds * 1e6)
        while stamp < end {
            o.feed(Sample(service: 11, stamp: stamp, x: 0, y: 0, z: raw(1)))
            o.feed(Sample(service: 12, stamp: stamp + 100, x: 0, y: 0, z: 0))
            stamp += 5000
        }
        return stamp
    }

    private static func pose() {
        let o = Orientation()
        var stamp = feedStill(o, from: 1_000_000, seconds: 1.5)
        check(o.ready, "ready after a still stretch")

        // 90 deg/s about z for one second turns the pose by 90 degrees
        let end = stamp + 1_000_000
        while stamp < end {
            o.feed(Sample(service: 11, stamp: stamp, x: 0, y: 0, z: raw(1)))
            o.feed(Sample(service: 12, stamp: stamp + 100, x: 0, y: 0, z: raw(90)))
            stamp += 5000
        }
        let degrees = o.q.rotationVector.norm * 180 / Double.pi
        check(abs(degrees - 90) < 3, "integrates 90 degrees (got \(degrees))")

        // a gyro that sits at a constant offset is learned and ignored
        let b = Orientation()
        var s2: UInt64 = 1_000_000
        let stillEnd = s2 + 2_000_000
        while s2 < stillEnd {
            b.feed(Sample(service: 11, stamp: s2, x: 0, y: 0, z: raw(1)))
            b.feed(Sample(service: 12, stamp: s2 + 100, x: raw(0.4), y: raw(-0.3), z: raw(0.2)))
            s2 += 5000
        }
        let rest = b.q.rotationVector.norm * 180 / Double.pi
        check(b.ready && rest < 1, "constant gyro offset removed (drift \(rest))")

        // aiming
        let aim = Aim()
        let a0 = Q.identity
        aim.setCenter(a0, referenceGravity: V3(0, 0, 1))
        let right = Q.exp(V3(0, 0.3, 0)), up = Q.exp(V3(0.3, 0, 0))
        do {
            try aim.setEdge(right: true, right)
            try aim.setEdge(right: false, up)
        } catch { check(false, "edges accepted") }
        let c = aim.point(a0), r = aim.point(right), u = aim.point(up)
        check(c != nil && abs(c!.x - 0.5) < 1e-9 && abs(c!.y - 0.5) < 1e-9, "centre maps to the middle")
        check(r != nil && abs(r!.x - 1) < 1e-6 && abs(r!.y - 0.5) < 1e-6, "right edge maps to the right")
        check(u != nil && abs(u!.x - 0.5) < 1e-6 && abs(u!.y - 0) < 1e-6, "top edge maps to the top")
        let half = Q.exp(V3(0, 0.15, 0))
        check(aim.point(half).map { abs($0.x - 0.75) < 1e-3 } == true, "half way maps half way")
        // same direction twice is refused
        let dup = Aim()
        dup.setCenter(a0, referenceGravity: V3(0, 0, 1))
        try? dup.setEdge(right: true, right)
        var refused = false
        do { try dup.setEdge(right: false, Q.exp(V3(0, 0.31, 0))) } catch { refused = true }
        check(refused, "same direction refused")
        // held differently: saved edges are dropped on recentre
        let keep = aim.recenter(Q.exp(V3(0.9, 0, 0)), referenceGravity: V3(0, 0, 1))
        check(!keep && !aim.calibrated, "different grip asks for new edges")
    }

    // MARK: taps

    /// Feeds 200 Hz accelerometer (and optional gyro) samples; returns the knock strengths heard.
    private static func knocks(_ d: TapDetector, seconds: Double, from start: UInt64 = 1_000_000,
                               accel: (Double) -> (Double, Double, Double), gyro: ((Double) -> Double)? = nil) -> [Double] {
        var heard = [Double]()
        var stamp = start
        let end = start + UInt64(seconds * 1e6)
        while stamp < end {
            let t = Double(stamp - start) * 1e-6
            let a = accel(t)
            if let g = gyro { _ = d.feed(Sample(service: 12, stamp: stamp + 100, x: raw(g(t)), y: 0, z: 0)) }
            if let k = d.feed(Sample(service: 11, stamp: stamp, x: raw(a.0), y: raw(a.1), z: raw(a.2))) { heard.append(k) }
            stamp += 5000
        }
        return heard
    }

    private static func taps() {
        // a gentle sway is not a knock
        let sway = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: { (0.03 * sin($0 * 3), 0, 1) })
        check(sway.isEmpty, "gentle sway is not a tap")

        // a narrow spike after a calm stretch is
        let spike: (Double) -> (Double, Double, Double) = { t in (t > 1.0 && t < 1.01 ? 0.9 : 0, 0, 1) }
        let one = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: spike)
        check(one.count == 1 && one[0] > 0.5, "a narrow spike after calm is a tap")

        // a wide bump (the case being swung) is not
        let wide = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: { t in (t > 1.0 && t < 1.2 ? 0.7 : 0, 0, 1) })
        check(wide.isEmpty, "a wide bump is not a tap")

        // a spike while the case is turning fast is not
        let turning = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: spike, gyro: { _ in 120 })
        check(turning.isEmpty, "a spike while turning is not a tap")

        // a spike while it sits still is, even with the gyro running
        let still = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: spike, gyro: { _ in 1 })
        check(still.count == 1, "a spike with a quiet gyro is a tap")

        // two knocks 0.2 s apart count once; 0.8 s apart count twice
        let quick = knocks(TapDetector(threshold: 0.4), seconds: 3, accel: { t in ((t > 1.0 && t < 1.01) || (t > 1.2 && t < 1.21) ? 0.9 : 0, 0, 1) })
        check(quick.count == 1, "quick double knock counts once")
        let apart = knocks(TapDetector(threshold: 0.4), seconds: 3, accel: { t in ((t > 1.0 && t < 1.01) || (t > 1.8 && t < 1.81) ? 0.9 : 0, 0, 1) })
        check(apart.count == 2, "knocks 0.8 s apart count twice")

        // below the threshold, and with taps off
        let soft = knocks(TapDetector(threshold: 0.4), seconds: 2, accel: { t in (t > 1.0 && t < 1.01 ? 0.25 : 0, 0, 1) })
        check(soft.isEmpty, "a soft knock below the threshold is ignored")
        let off = knocks(TapDetector(threshold: 0), seconds: 2, accel: spike)
        check(off.isEmpty, "threshold 0 turns taps off")
    }

    // MARK: gyro mouse

    private static func calibratedMouse() -> GyroMouse {
        let m = GyroMouse()
        m.right = V3(0, 0, 1)        // turning about z moves the pointer right
        m.up = V3(1, 0, 0)           // turning about x moves it up
        return m
    }

    /// Total pixels moved by turning at `gyro` (deg/s) for `seconds`.
    private static func turn(_ m: GyroMouse, _ gyro: V3, seconds: Double) -> (dx: Double, dy: Double) {
        var total = (dx: 0.0, dy: 0.0)
        var t = 0.0
        while t < seconds {
            let d = m.feed(gyro: gyro, dt: 0.005)
            total.dx += d.dx; total.dy += d.dy
            t += 0.005
        }
        return total
    }

    private static func gyroMouse() {
        // turning right moves right, tipping up moves up (negative y on the screen)
        let right = turn(calibratedMouse(), V3(0, 0, 40), seconds: 1)
        check(right.dx > 300 && abs(right.dy) < 1, "turning right moves the pointer right (got \(right))")
        let left = turn(calibratedMouse(), V3(0, 0, -40), seconds: 1)
        check(left.dx < -300 && abs(left.dy) < 1, "turning left moves it left")
        let up = turn(calibratedMouse(), V3(40, 0, 0), seconds: 1)
        check(up.dy < -300 && abs(up.dx) < 1, "tipping up moves the pointer up (got \(up))")

        // slow drift of the gyro is ignored, and a stopped case stops the pointer
        let creep = turn(calibratedMouse(), V3(0, 0, 2), seconds: 5)
        check(abs(creep.dx) < 0.001, "a slow gyro offset does not move it")

        // quick turns go further per degree than slow ones
        let slow = turn(calibratedMouse(), V3(0, 0, 20), seconds: 1).dx / 20
        let fast = turn(calibratedMouse(), V3(0, 0, 120), seconds: 0.2).dx / (120 * 0.2)
        check(fast > slow * 1.4, "a quick turn is accelerated (\(fast) vs \(slow) px/deg)")

        // a knock (a spike of two samples) does not move it
        let knock = calibratedMouse()
        var spike = 0.0
        for i in 0..<200 {
            let rate = (i == 100 || i == 101) ? 250.0 : 0.0
            spike += knock.feed(gyro: V3(0, 0, rate), dt: 0.005).dx
        }
        check(abs(spike) < 1, "a knock's jolt is filtered out (got \(spike))")

        // gain scales the movement
        let fastMouse = calibratedMouse()
        fastMouse.gain = 2
        let doubled = turn(fastMouse, V3(0, 0, 40), seconds: 1)
        check(doubled.dx > right.dx * 1.8, "gain doubles the movement")

        // a calibration turn is found by its axis, and a twitch is not
        let g = GyroMouse()
        var found: V3?
        var t = 0.0
        while t < 1.5 {
            let rate = t > 0.2 && t < 0.7 ? 60.0 : 0.0            // 30 degrees about z
            if let axis = g.trackGesture(gyro: V3(0, 0, rate), dt: 0.005, minimumDegrees: 12) { found = axis }
            t += 0.005
        }
        check(found.map { $0.dot(V3(0, 0, 1)) > 0.99 } == true, "a turn is found by its axis")
        let h = GyroMouse()
        var twitch: V3?
        t = 0.0
        while t < 1.5 {
            let rate = t > 0.2 && t < 0.25 ? 60.0 : 0.0            // 3 degrees
            if let axis = h.trackGesture(gyro: V3(0, 0, rate), dt: 0.005, minimumDegrees: 12) { twitch = axis }
            t += 0.005
        }
        check(twitch == nil, "a twitch is not a turn")
        let reverse = GyroMouse()
        var back: V3?
        t = 0.0
        while t < 1.5 {
            let rate = t > 0.2 && t < 0.7 ? -60.0 : 0.0
            if let axis = reverse.trackGesture(gyro: V3(0, 0, rate), dt: 0.005, minimumDegrees: 12) { back = axis }
            t += 0.005
        }
        check(back.map { $0.dot(V3(0, 0, -1)) > 0.99 } == true, "a turn the other way gives the opposite axis")
        check(abs(GyroMouse.anyPerpendicular(to: V3(0, 0, 1)).dot(V3(0, 0, 1))) < 1e-9, "a perpendicular axis is perpendicular")

        // inverting an axis flips the aim
        let aim = Aim()
        aim.setCenter(.identity, referenceGravity: V3(0, 0, 1))
        try? aim.setEdge(right: true, Q.exp(V3(0, 0.3, 0)))
        try? aim.setEdge(right: false, Q.exp(V3(0.3, 0, 0)))
        aim.invertX = true
        let flipped = aim.point(Q.exp(V3(0, 0.3, 0)))
        check(flipped.map { abs($0.x - 0) < 1e-6 && abs($0.y - 0.5) < 1e-6 } == true, "invert left/right flips x")
        aim.invertX = false; aim.invertY = true
        let flippedY = aim.point(Q.exp(V3(0.3, 0, 0)))
        check(flippedY.map { abs($0.x - 0.5) < 1e-6 && abs($0.y - 1) < 1e-6 } == true, "invert up/down flips y")
    }

    // MARK: slide mouse

    /// Feeds the sliding mouse at 200 Hz: `profile(t)` gives the extra acceleration (g) on top of the rest reading.
    private static func drive(_ m: SlideMouse, rest: V3, seconds: Double, gyro: V3 = V3(),
                              profile: (Double) -> V3) -> (dx: Double, dy: Double) {
        var total = (dx: 0.0, dy: 0.0)
        var t = 0.0
        while t < seconds {
            let step = m.feed(accel: rest + profile(t), gyro: gyro, dt: 0.005)
            total.dx += step.dx; total.dy += step.dy
            t += 0.005
        }
        return total
    }

    private static func push(_ axis: V3, _ strength: Double, from: Double = 1.0) -> (Double) -> V3 {
        { t in
            if t > from && t < from + 0.3 { return axis * strength }
            if t >= from + 0.3 && t < from + 0.6 { return axis * (-strength) }
            return V3()
        }
    }

    private static func slideMouse() {
        let rest = V3(0.1, 0.0, 0.99)
        func calibrated() -> SlideMouse {
            let m = SlideMouse()
            m.right = V3(1, 0, 0); m.forward = V3(0, 1, 0)
            return m
        }
        // right moves right, away moves up (negative y)
        let right = drive(calibrated(), rest: rest, seconds: 3, profile: push(V3(1, 0, 0), 0.1))
        check(right.dx > 150 && abs(right.dy) < 20, "sliding right moves the pointer right (got \(right))")
        let left = drive(calibrated(), rest: rest, seconds: 3, profile: push(V3(-1, 0, 0), 0.1))
        check(left.dx < -150, "sliding left moves it left")
        let away = drive(calibrated(), rest: rest, seconds: 3, profile: push(V3(0, 1, 0), 0.1))
        check(away.dy < -150 && abs(away.dx) < 20, "sliding away moves it up (got \(away))")

        // at rest, with sensor noise and a slow tilt, it does not creep
        var seed: UInt64 = 7
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.017          // about 0.005 g
        }
        let creep = drive(calibrated(), rest: rest, seconds: 20, profile: { t in V3(noise() + 0.004 * t / 20, noise(), noise()) })
        check(abs(creep.dx) < 30 && abs(creep.dy) < 30, "at rest it does not creep (got \(creep))")

        // a hard bump straight up and down pauses it instead of moving it
        let bump = drive(calibrated(), rest: rest, seconds: 2, profile: { t in
            t > 1.0 && t < 1.02 ? V3(0.2, 0, 0.9) : (t >= 1.02 && t < 1.04 ? V3(-0.2, 0, -0.9) : V3())
        })
        check(abs(bump.dx) < 15, "a bump is not a slide (got \(bump))")

        // a gentle stroke with noise is still seen; the calibration reads its direction
        let found = SlideMouse()
        _ = drive(found, rest: V3(0, 0, 1), seconds: 3, profile: { t in
            let direction = V3(0.6, 0.8, 0)
            let p = push(direction, 0.12)(t)
            return V3(p.x + noise(), p.y + noise(), p.z + noise())
        })
        let stroke = found.takeStroke()
        check(stroke.map { $0.dot(V3(0.6, 0.8, 0)) > 0.95 } == true, "a calibration stroke gives its direction")
        let back = SlideMouse()
        _ = drive(back, rest: V3(0, 0, 1), seconds: 3, profile: push(V3(0.6, 0.8, 0), -0.12))
        check(back.takeStroke().map { $0.dot(V3(-0.6, -0.8, 0)) > 0.95 } == true, "the opposite stroke gives the opposite direction")
        let twitch = SlideMouse()
        _ = drive(twitch, rest: V3(0, 0, 1), seconds: 3, profile: push(V3(1, 0, 0), 0.03))
        check(twitch.takeStroke() == nil, "a tiny twitch is not a stroke")

        // gain scales the movement
        let strong = calibrated()
        strong.gain = 2
        let doubled = drive(strong, rest: rest, seconds: 3, profile: push(V3(1, 0, 0), 0.1))
        check(doubled.dx > right.dx * 1.8, "gain doubles the movement")
    }

    /// With AIRMAGIC_SLIDE_CSV=/path/slide-test.csv, runs the sliding mouse over a real recording and prints
    /// the movement per step of the script (cm along the two surface axes), to compare with the prototype.
    private static func recordedSlide() {
        guard let path = ProcessInfo.processInfo.environment["AIRMAGIC_SLIDE_CSV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var samples: [Sample] = []
        var markers: [(stamp: UInt64, label: String)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: ",")
            if f[0] == "S", f.count == 6, let sv = Int(f[1]), let us = UInt64(f[2]), let x = Int32(f[3]), let y = Int32(f[4]), let z = Int32(f[5]) {
                samples.append(Sample(service: sv, stamp: us, x: x, y: y, z: z))
            } else if f[0] == "M", f.count == 3, let us = UInt64(f[1]) {
                markers.append((us, String(f[2])))
            }
        }
        guard let first = samples.first else { return }
        if !markers.isEmpty { markers[0].stamp = first.stamp }
        // rest reading and gyro offset from the first stretch (0.5 s to 4.5 s)
        let early = samples.filter { $0.stamp >= first.stamp + 500_000 && $0.stamp < first.stamp + 4_500_000 }
        let acc = early.filter { $0.service == 11 }, gyr = early.filter { $0.service == 12 }
        func avg(_ v: [Sample]) -> V3 {
            V3(v.map { Double($0.x) }.reduce(0, +), v.map { Double($0.y) }.reduce(0, +), v.map { Double($0.z) }.reduce(0, +)) * (1e-5 / Double(v.count))
        }
        let rest = avg(acc), gyroOffset = avg(gyr)
        let up = rest.unit
        let e1 = up.cross(V3(1, 0, 0)).unit
        let e2 = up.cross(e1).unit
        let m = SlideMouse()
        m.right = e2; m.forward = e1            // the axes the prototype used: right is e2, away is e1
        var gyro = V3()
        var last: UInt64 = 0
        var cumulative = [(stamp: UInt64, e1: Double, e2: Double)]()
        var px = (e1: 0.0, e2: 0.0)
        for s in samples {
            let v = V3(Double(s.x), Double(s.y), Double(s.z)) * 1e-5
            if s.service == 12 { gyro = v - gyroOffset; continue }
            let dt = last == 0 ? 0.005 : Double(s.stamp - last) * 1e-6
            last = s.stamp
            let step = m.feed(accel: v, gyro: gyro, dt: dt)
            px.e2 += step.dx / (SlideMouse.pixelsPerMetre * m.gain) * 100
            px.e1 += -step.dy / (SlideMouse.pixelsPerMetre * m.gain) * 100
            cumulative.append((s.stamp, px.e1, px.e2))
        }
        var previous = (e1: 0.0, e2: 0.0)
        print("recorded slide test, movement per step (cm): e1 e2")
        for (i, mk) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].stamp : (samples.last?.stamp ?? 0)
            guard let at = cumulative.last(where: { $0.stamp <= end - 50_000 }) else { continue }
            print(String(format: "  %-18@ %7.1f %7.1f", mk.label as NSString, at.e1 - previous.e1, at.e2 - previous.e2))
            previous = (at.e1, at.e2)
        }
    }

    // MARK: recorder

    private static func recorder() {
        let r = SlideRecorder()
        r.begin(now: 0)
        var stamp: UInt64 = 1000
        var prompts = Set<String>()
        var now = 0.0
        while let step = r.tick(now: now) {
            prompts.insert(step.prompt)
            r.add([Sample(service: 11, stamp: stamp, x: 1, y: 2, z: 3), Sample(service: 12, stamp: stamp + 100, x: 4, y: 5, z: 6)])
            stamp += 5000
            now += 0.5
        }
        check(now >= SlideRecorder.duration - 1 && now <= SlideRecorder.duration + 1, "the script runs for its length")
        check(prompts.count >= 12, "the script gives many different prompts")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airmagic-recorder-test.csv")
        try? r.write(to: url)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        check(lines.first?.hasPrefix("# ") == true, "the file starts with a comment")
        check(lines.filter { $0.hasPrefix("S,") }.count == r.samples.count, "every sample is written")
        check(lines.filter { $0.hasPrefix("M,") }.count == SlideRecorder.script.count, "every step has a marker")
        check(text.contains("M,") && text.contains(",diag-away-right"), "markers carry their labels")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: recorded taps (optional)

    /// With AIRMAGIC_TAP_FIXTURES=/path/TapFixtures.csv (segment,service,µs,x,y,z), runs the detector on
    /// real recordings: 15 soft taps on a closed case in the hand, and handling with no taps.
    private static func recordedTaps() {
        guard let path = ProcessInfo.processInfo.environment["AIRMAGIC_TAP_FIXTURES"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var segments: [String: [Sample]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: ",")
            guard f.count == 6, let service = Int(f[1]), let us = UInt64(f[2]),
                  let x = Int32(f[3]), let y = Int32(f[4]), let z = Int32(f[5]) else { continue }
            segments[String(f[0]), default: []].append(Sample(service: service, stamp: us, x: x, y: y, z: z))
        }
        func count(_ name: String, _ threshold: Double) -> Int {
            let d = TapDetector(threshold: threshold)
            return (segments[name] ?? []).reduce(0) { $0 + (d.feed($1) == nil ? 0 : 1) }
        }
        let held = count("held", 0.4)
        check(held == 15, "recorded: all 15 soft taps on the closed case found (got \(held))")
        let walking = count("pointing", 0.4)
        check(walking <= 2, "recorded: aiming around makes at most 2 false taps (got \(walking))")
        let others = segments.keys.filter { $0.contains("-") }.reduce(0) { $0 + count($1, 0.4) }
        print("recorded: held \(held)/15, pointing \(walking), other handling \(others) false taps")
    }
}
