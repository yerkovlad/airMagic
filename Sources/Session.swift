import Foundation

// The conversation with the earbud and the charging case, kept free of any I/O
// so it can be tested: bytes go out through `send`, events come in through
// `handle`, and `tick` runs on a timer.
//
// Why there is a conversation at all: with the lid closed, the case would end the
// earbud's sensor stream after about 3.5 s of "nothing selected". Asking it for
// its diagnostic asset ("MTIC") once a second cancels that timer. If the case
// offers the asset we accept it and keep it open instead, and a once-a-second
// model-name query keeps the stream alive. On exit the asset is abandoned,
// which uses up the diagnostic records staged on the case.

final class Session {
    struct Failure { let code: Int32; let reason: String }

    var send: ([UInt8]) -> Bool = { _ in false }
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var log: (String) -> Void = { _ in }

    // earbud (root) state
    private(set) var rootVersionValid = false
    private(set) var rootVerified = false
    private var rootModelSent = false
    private var discoverySent = false
    private var rootPending = false
    private var rootAsked = 0
    private var rootStartupAsked = 0
    private var lastRootAsk = 0.0
    private var nextRootAsk = 0.0
    private var rootModelSince = 0.0
    private var announced = Set<UInt16>()
    private(set) var caseActive = false

    // lid
    private(set) var lidClosed = false
    private var locations = [(t: Double, p: UInt8, s: UInt8)]()

    // case state
    private var caseVersionValid = false
    private var caseVersionAsks = 0
    private var caseModelSent = false
    private(set) var caseVerified = false
    private var caseName: String?
    private var pending: String?
    private var pendingSince = 0.0
    private var nextCaseAsk = 0.0
    private var nextSolicit = 0.0
    private var offer: [UInt8]?
    private var offerInfo: (asset: UInt16, length: UInt32)?
    private(set) var accepted = false
    private var nextIdentity = 0.0
    private var missedIdentity = 0
    private var missedReplies = 0
    private var seenReplies = [UInt16]()
    private var windowStart = 0.0
    private var windowCount = 0

    // cleanup
    private(set) var cleanupSent = false
    private(set) var cleanupAck = false
    private var cleaning = false

    private var rootID: UInt16 = 1
    private var childID: UInt16 = 1
    private(set) var failure: Failure?

    var summary: String {
        "root=\(rootVerified ? "ok" : "-") case=\(caseVerified ? "ok" : "-") lid=\(lidClosed ? "closed" : "open") held=\(accepted ? 1 : 0)"
    }

    private func fail(_ code: Int32, _ reason: String) {
        if failure == nil { failure = Failure(code: code, reason: reason); log("FAIL \(code): \(reason)") }
    }
    private func next(_ id: inout UInt16) -> UInt16 {
        let v = id
        id = id == UInt16.max ? 1 : id + 1
        return v
    }

    // MARK: sending

    private func sendRoot(_ type: UInt16, _ body: [UInt8]) -> Bool {
        log("TX root type=\(type) body=\(body.count)")
        return send(Wire.uarp(type: type, id: next(&rootID), body: body))
    }

    private func sendCase(_ type: UInt16, _ body: [UInt8]) -> Bool {
        let now = clock()
        if now - windowStart >= 60 { windowStart = now; windowCount = 0 }
        // Never flood the case: a minute allows 120 requests, we use about 2 per second at most.
        guard windowCount < 120 else { fail(42, "case request budget used up"); return false }
        windowCount += 1
        log("TX case type=\(type) body=\(body.count)")
        return send(Wire.caseFrame(type: type, childID: next(&childID), body: body, rootID: next(&rootID)))
    }

    private func ask(_ what: String) {
        pending = what
        pendingSince = clock()
    }

    // MARK: lid

    /// Fed with every location report. Code 3 means closed; two (2,2) reports within half
    /// a second are a toggle (lid moved).
    func location(_ p: UInt8, _ s: UInt8) {
        locations.append((clock(), p, s))
        if locations.count > 64 { locations.removeFirst() }
        var closed = false
        var i = 0
        while i < locations.count {
            let r = locations[i]
            if r.p == 3 || r.s == 3 {
                closed = true
            } else if i + 1 < locations.count, r.p == 2, r.s == 2, locations[i + 1].p == 2, locations[i + 1].s == 2,
                      locations[i + 1].t - r.t <= 0.5 {
                closed.toggle()
                i += 2
                continue
            }
            i += 1
        }
        if closed != lidClosed {
            lidClosed = closed
            log("lid \(closed ? "closed" : "open")")
        }
    }

    // MARK: incoming

    func handle(type: UInt16, id: UInt16, body: [UInt8]) {
        let now = clock()
        log("RX type=\(type) id=\(id) body=\(body.count) \(body.prefix(12).map { String(format: "%02x", $0) }.joined())")
        switch type {
        case 0x16:
            if body.count != 2 || Wire.be16(body, 0) != 0 { fail(41, "root discovery refused") }
        case 0x17, 0x19:
            guard body.count == 2 else { fail(41, "malformed endpoint announcement"); return }
            let endpoint = Wire.be16(body, 0)
            if type == 0x17 { announced.insert(endpoint) }
            if announced.contains(endpoint) {
                let ack = [UInt8(0), 0] + Wire.put16(endpoint)
                if !sendRoot(type == 0x17 ? 0x18 : 0x1a, ack) { fail(42, "endpoint ack failed") }
            }
            if endpoint == 1 {
                caseActive = type == 0x17
                if !caseActive { fail(35, "case went away") }
            }
        case 2:
            guard body.count >= 4, Wire.be16(body, 0) == 0, (5...7).contains(Wire.be16(body, 2)) else {
                fail(41, "root version refused"); return
            }
            rootVersionValid = true
            rootPending = false
            rootAsked = 0
            nextRootAsk = now + 1
            if !rootModelSent {
                if sendRoot(3, [0, 0, 0, 2]) { rootModelSent = true; rootModelSince = now } else { fail(42, "root model write failed") }
            }
        case 4 where rootModelSent && !rootVerified:
            let name = Wire.modelName(body) ?? "(invalid)"
            log("earbud model: \(name)")
            if Wire.isEarbud(name) { rootVerified = true } else { fail(32, "earbud model '\(name)' not supported") }
        case 0x1b:
            handleCase(body, now)
        default:
            break
        }
    }

    private func handleCase(_ body: [UInt8], _ now: Double) {
        guard body.count >= 8 else { fail(41, "short case frame"); return }
        guard Wire.be16(body, 0) == 1, caseActive, announced.contains(1) else { return }
        let it = Wire.be16(body, 2), len = Int(Wire.be16(body, 4)), rid = Wire.be16(body, 6)
        guard body.count == len + 8 else { fail(41, "malformed case frame"); return }
        let v = Array(body[8...])

        if it == 5 {   // an asset offer
            guard v.count >= 4, Array(v[0..<4]) == Array("MTIC".utf8) else { return }
            guard let info = Wire.parseOffer(v) else { fail(41, "bad MTIC offer"); return }
            if offer == nil && !cleaning && failure == nil { offer = v; offerInfo = info }
            return
        }
        guard [2, 4, 7, 0x0f, 0x12, 0x13].contains(it) else { return }
        if seenReplies.contains(rid) { log("ignored a repeated case reply"); return }
        seenReplies.append(rid)
        if seenReplies.count > 128 { seenReplies.removeFirst() }

        if it == 0x0f && cleanupSent {
            if v.count == 4, let info = offerInfo, Wire.be16(v, 0) == info.asset, Wire.be16(v, 2) == 3 {
                cleanupAck = true
                pending = nil
            } else { fail(41, "bad abandon ack") }
            return
        }
        if cleaning { return }

        switch (it, pending) {
        case (0x12, "solicit"?):
            if v.count == 8, Wire.be32(v, 0) == 0, Array(v[4..<8]) == Array("MTIC".utf8) {
                pending = nil
                nextSolicit = now + 1
            } else { log("odd keep-alive receipt ignored"); pending = nil; nextSolicit = now + 1 }
        case (0x13, _) where !accepted:
            fail(36, "case declined the diagnostic request")
        case (2, "version"?):
            guard v.count >= 4, Wire.be16(v, 0) == 0, (5...7).contains(Wire.be16(v, 2)) else { fail(41, "bad case version"); return }
            caseVersionValid = true
            pending = nil
        case (4, "model"?):
            caseName = Wire.modelName(v)
            log("case model: \(caseName ?? "(none)")")
            if Wire.isCase(caseName) { caseVerified = true; pending = nil } else { fail(34, "'\(caseName ?? "?")' is not a charging case") }
        case (4, "identity"?):
            let name = Wire.modelName(v)
            if Wire.isCase(name) { pending = nil; missedIdentity = 0 } else { fail(34, "case identity changed") }
        case (4, nil):
            break   // a late reply, harmless
        default:
            log("ignored an unexpected case reply (type \(it))")
        }
    }

    // MARK: timers

    func tick() {
        let now = clock()
        if cleaning || failure != nil { return }

        // earbud heartbeat
        if rootModelSent && !rootVerified && now - rootModelSince >= 8 { fail(31, "earbud never named itself"); return }
        let age = now - lastRootAsk
        if rootPending && age >= 8 {
            if rootVersionValid && rootAsked >= 3 { fail(40, "earbud stopped answering"); return }
            if !rootVersionValid && rootStartupAsked >= 20 { fail(40, "earbud never answered"); return }
        }
        if (!rootPending && now >= nextRootAsk) || (rootPending && age >= 8) {
            if sendRoot(1, [0, 7]) {
                rootPending = true; lastRootAsk = now; rootAsked += 1
                if !rootVersionValid { rootStartupAsked += 1 }
            } else { fail(42, "heartbeat write failed"); return }
        }
        if rootVerified && !discoverySent {
            if sendRoot(0x15, []) { discoverySent = true } else { fail(42, "discovery write failed"); return }
        }

        // case conversation starts only once the lid is shut
        guard lidClosed, rootVerified, caseActive, announced.contains(1) else { return }

        if let p = pending {
            let limit: Double = p == "identity" ? 5 : 5
            if now - pendingSince >= limit {
                // A missed reply is asked again; only a case that keeps ignoring us ends the session.
                missedReplies += 1
                log("case \(p) reply missed (\(missedReplies))")
                if missedReplies >= 6 { fail(40, "case stopped answering"); return }
                pending = nil
                if p == "model" { caseModelSent = false }
                if p == "solicit" { nextSolicit = now + 1 }
            }
            return
        }

        if !caseVersionValid {
            if caseVersionAsks < 2 && now >= nextCaseAsk {
                if sendCase(1, [0, 7]) { caseVersionAsks += 1; nextCaseAsk = now + 8; ask("version") } else { fail(42, "case version write failed") }
            } else if caseVersionAsks >= 2 && now >= nextCaseAsk { fail(40, "case never answered") }
            return
        }
        if !caseModelSent {
            if sendCase(3, [0, 0, 0, 2]) { caseModelSent = true; ask("model") } else { fail(42, "case model write failed") }
            return
        }
        guard caseVerified else { return }

        if offer == nil {
            if now >= nextSolicit {
                if sendCase(0x11, Array("MTIC".utf8)) { ask("solicit") } else { fail(42, "keep-alive write failed") }
            }
            return
        }
        if !accepted, let offer {
            if sendCase(0x0d, offer) {
                accepted = true
                nextIdentity = now + 1
                log("holding diagnostic asset \(offerInfo?.asset ?? 0)")
            } else { fail(42, "asset accept failed") }
            return
        }
        if accepted && now >= nextIdentity {
            if sendCase(3, [0, 0, 0, 2]) { ask("identity"); nextIdentity = now + 1 } else { fail(42, "identity query failed") }
        }
    }

    // MARK: cleanup

    /// Releases the held asset (call after the sensors were stopped).
    func beginCleanup() {
        cleaning = true
        guard accepted, caseActive, let info = offerInfo else { return }
        cleanupSent = sendCaseForCleanup(Wire.put16(info.asset) + [0, 3])
        if cleanupSent { pending = "abandon" }
    }

    private func sendCaseForCleanup(_ body: [UInt8]) -> Bool {
        send(Wire.caseFrame(type: 9, childID: next(&childID), body: body, rootID: next(&rootID)))
    }
}
