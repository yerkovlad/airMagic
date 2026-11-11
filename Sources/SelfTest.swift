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

    private static func taps() {
        let d = TapDetector(threshold: 0.25)
        var stamp: UInt64 = 1_000_000
        var fired = 0
        for i in 0..<400 {
            // gentle sway
            let sway = 0.02 * sin(Double(i) * 0.05)
            if d.feed(Sample(service: 11, stamp: stamp, x: raw(sway), y: 0, z: raw(1))) != nil { fired += 1 }
            stamp += 5000
        }
        check(fired == 0, "smooth motion is not a tap")
        let spike = d.feed(Sample(service: 11, stamp: stamp, x: raw(0.8), y: 0, z: raw(1)))
        check(spike != nil, "a knock is a tap")
        stamp += 5000
        check(d.feed(Sample(service: 11, stamp: stamp, x: raw(-0.8), y: 0, z: raw(1))) == nil, "no second tap inside the pause")
        let off = TapDetector(threshold: 0)
        _ = off.feed(Sample(service: 11, stamp: 1, x: 0, y: 0, z: raw(1)))
        check(off.feed(Sample(service: 11, stamp: 5001, x: raw(2), y: 0, z: raw(1))) == nil, "threshold 0 turns taps off")
    }
}
