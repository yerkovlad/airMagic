import Foundation
import IOBluetooth
import CoreBluetooth

// Runs as a child process (`airMagic --link ADDRESS`). It opens the AirPods'
// control channel, starts the accelerometer and gyroscope, keeps the stream
// alive with `Session`, and prints one line per sample on stdout:
//
//     M,<service>,<sensor µs>,<x>,<y>,<z>
//
// Everything else goes to stderr. It stops when stdin closes or says "stop",
// or on SIGTERM, and always stops the sensors first.
//
// This uses private IOBluetooth selectors (the only way to reach PSM 0x1001),
// so each one is checked before it is called.

private func pump(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

private func say(_ text: String) {
    fputs(text + "\n", stderr)
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

private func normalize(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: ":").lowercased()
}

// MARK: private selector helpers

private func object(_ target: NSObject, _ name: String) -> NSObject? {
    let sel = NSSelectorFromString(name)
    guard target.responds(to: sel) else { return nil }
    return target.perform(sel)?.takeUnretainedValue() as? NSObject
}

private func integer(_ target: NSObject, _ name: String) -> Int? {
    let sel = NSSelectorFromString(name)
    guard target.responds(to: sel), let imp = target.method(for: sel) else { return nil }
    typealias F = @convention(c) (AnyObject, Selector) -> Int
    return unsafeBitCast(imp, to: F.self)(target, sel)
}

private func openChannel(_ peer: NSObject, psm: UInt16) {
    let sel = NSSelectorFromString("openL2CAPChannel:")
    guard let imp = peer.method(for: sel) else { return }
    typealias F = @convention(c) (AnyObject, Selector, UInt16) -> Void
    unsafeBitCast(imp, to: F.self)(peer, sel, psm)
}

private func closeChannel(_ peer: NSObject, psm: UInt16) {
    let sel = NSSelectorFromString("closeL2CAPChannel:")
    guard let imp = peer.method(for: sel) else { return }
    typealias F = @convention(c) (AnyObject, Selector, UInt16) -> Void
    unsafeBitCast(imp, to: F.self)(peer, sel, psm)
}

private final class ChannelBox {
    var done = false
    var channel: NSObject?
}

// MARK: link

enum Link {
    private static var terminate = false
    private static var signalSource: DispatchSourceSignal?

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AirMagic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The sensor request number keeps counting across runs.
    private static func nextSequence() -> UInt32 {
        let url = supportDirectory().appendingPathComponent("sensor-sequence.txt")
        let saved = (try? String(contentsOf: url, encoding: .utf8)).flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let value: UInt32 = (saved < 8000 || saved >= 16000) ? 8001 : saved + 1
        try? String(value).write(to: url, atomically: true, encoding: .utf8)
        return value
    }

    private static func write(_ output: OutputStream, _ bytes: [UInt8], _ what: String) -> Bool {
        let deadline = uptime() + 3
        var sent = 0
        while sent < bytes.count && uptime() < deadline {
            let status = output.streamStatus
            if status == .error || status == .atEnd || status == .closed { break }
            if !output.hasSpaceAvailable { pump(0.02); continue }
            let n = bytes[sent...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            sent += n
        }
        if sent != bytes.count { say("write \(what) failed (\(sent)/\(bytes.count))") }
        return sent == bytes.count
    }

    private static func ended(_ s: Stream) -> Bool {
        s.streamStatus == .error || s.streamStatus == .atEnd || s.streamStatus == .closed
    }

    /// Reads "stop" or EOF from stdin without blocking. Returns true when we should stop.
    private static func stdinSaysStop() -> Bool {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n == 0 { return true }
        if n > 0, String(decoding: buf[0..<n], as: UTF8.self).contains("stop") { return true }
        return false
    }

    static func run(address: String) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { terminate = true }
        src.resume()
        signalSource = src
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)

        func finish(_ code: Int32, _ why: String) -> Int32 {
            say("EXIT \(code) \(why)")
            return code
        }

        guard CBManager.authorization == .allowedAlways else { return finish(20, "Bluetooth permission not granted") }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: { normalize($0.addressString ?? "") == normalize(address) })
        else { return finish(22, "AirPods are not paired with this Mac") }

        guard let coordinatorClass = NSClassFromString("IOBluetoothCoreBluetoothCoordinator") as AnyObject?,
              let coordinator = coordinatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject,
              let manager = object(coordinator, "classicManager"),
              device.responds(to: NSSelectorFromString("peer"))
        else { return finish(24, "private Bluetooth API missing") }

        let ready = uptime() + 8
        while integer(manager, "state") != CBManagerState.poweredOn.rawValue && uptime() < ready && !terminate { pump(0.05) }
        guard integer(manager, "state") == CBManagerState.poweredOn.rawValue else { return finish(21, "Bluetooth is not on") }
        if !device.isConnected() {
            // Open lid and nearby: ask macOS to connect them.
            say("AirPods are not connected; trying to connect")
            _ = device.openConnection()
            let until = uptime() + 10
            while !device.isConnected() && uptime() < until && !terminate { pump(0.1) }
        }
        guard device.isConnected() else { return finish(23, "AirPods are not connected to this Mac") }

        if let existing = object(device, "peer") {
            for sel in ["connectL2CAPCallback", "setConnectL2CAPCallback:", "openL2CAPChannel:", "closeL2CAPChannel:"]
            where !existing.responds(to: NSSelectorFromString(sel)) { return finish(24, "peer lacks \(sel)") }
            if existing.perform(NSSelectorFromString("connectL2CAPCallback")) != nil {
                return finish(25, "another client owns the channel")
            }
        }

        // The control channel only answers when it is opened right after a fresh
        // connection, so drop the link and bring it back first.
        say("reconnecting the AirPods")
        _ = device.closeConnection()
        let down = uptime() + 3
        while device.isConnected() && uptime() < down { pump(0.05) }
        var reopened = device.openConnection()
        var tries = 1
        while reopened != kIOReturnSuccess && tries < 3 {
            pump(1)
            reopened = device.openConnection()
            tries += 1
        }
        if reopened != kIOReturnSuccess {
            let wait = uptime() + 2
            while !device.isConnected() && uptime() < wait { pump(0.05) }
            guard device.isConnected() else { return finish(26, "could not reconnect the AirPods") }
        }

        guard let peer = object(device, "peer") else { return finish(27, "no Bluetooth peer after reconnect") }
        let box = ChannelBox()
        let block: @convention(block) (AnyObject?, Int) -> Void = { channel, error in
            box.done = true
            if let channel, error == 0 { box.channel = channel as? NSObject }
        }
        _ = peer.perform(NSSelectorFromString("setConnectL2CAPCallback:"), with: unsafeBitCast(block, to: AnyObject.self))
        openChannel(peer, psm: 0x1001)
        let wait = uptime() + 10
        while !box.done && uptime() < wait && !terminate { pump(0.05) }
        _ = peer.perform(NSSelectorFromString("setConnectL2CAPCallback:"), with: nil)

        var code: Int32 = 27
        var why = "no channel within 10 s"
        if let channel = box.channel,
           let input = channel.value(forKey: "inputStream") as? InputStream,
           let output = channel.value(forKey: "outputStream") as? OutputStream {
            (code, why) = converse(input: input, output: output)
            closeChannel(peer, psm: 0x1001)
            pump(0.2)
        }
        // Never leave the link down if we are the reason it is.
        if !device.isConnected() && !terminate {
            var n = 0
            while !device.isConnected() && n < 3 { _ = device.openConnection(); pump(2); n += 1 }
        }
        return finish(code, why)
    }

    // MARK: conversation

    private static func converse(input: InputStream, output: OutputStream) -> (Int32, String) {
        let parser = Parser()
        let session = Session()
        session.send = { write(output, $0, "message") }
        session.log = { say($0) }

        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open(); output.open()
        pump(0.3)

        parser.trace = { say($0) }
        var rawLogged = 0
        func drain() -> [Event] {
            var out = [Event]()
            var chunk = [UInt8](repeating: 0, count: 16384)
            while input.hasBytesAvailable {
                let n = input.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                if rawLogged < 40 {
                    rawLogged += 1
                    say("RAW \(n) bytes: " + chunk[0..<min(n, 40)].map { String(format: "%02x", $0) }.joined())
                }
                out += parser.feed(Array(chunk[0..<n]))
            }
            return out
        }

        // Session setup, with a pause after each message.
        guard write(output, Wire.handshake, "handshake") else { return (42, "setup write failed") }
        pump(0.4)
        guard write(output, Wire.features, "features") else { return (42, "setup write failed") }
        pump(0.4)
        guard write(output, Wire.notifications, "notifications") else { return (42, "setup write failed") }
        let began = uptime()
        while uptime() - began < 2 && !terminate {
            pump(0.05)
            if parser.controls > 0 && parser.chunks >= 7 && uptime() - began >= 0.5 { break }
            _ = drain().count
        }
        guard parser.controls > 0 else { return (28, "the AirPods did not answer the setup") }

        var accel = false, gyro = false
        let started = write(output, Wire.sensorSetting(service: 11, interval: 5000, sequence: nextSequence()), "accelerometer start")
        accel = started
        pump(0.2)
        let started2 = write(output, Wire.sensorSetting(service: 12, interval: 5000, sequence: nextSequence()), "gyroscope start")
        gyro = started2
        guard accel && gyro else { return (42, "could not start the sensors") }
        say("sensors started")

        var last: [Int: (stamp: UInt64, at: Double)] = [:]
        var fresh: [Int: Int] = [11: 0, 12: 0]
        var verified = false
        var code: Int32 = 0
        var why = "stopped"
        var nextStatus = 0.0

        loop: while true {
            if terminate { code = 52; why = "terminated"; say("terminated"); break }
            if stdinSaysStop() { why = "stop requested"; say("stop requested"); break }
            if ended(input) || ended(output) { code = 44; why = "the AirPods link ended"; say("link ended: input \(input.streamStatus.rawValue) output \(output.streamStatus.rawValue)"); break }
            session.tick()
            pump(0.02)
            for event in drain() {
                switch event {
                case .motion(let s):
                    let previous = last[s.service]
                    if previous == nil || s.stamp > previous!.stamp {
                        last[s.service] = (s.stamp, uptime())
                        fresh[s.service, default: 0] += 1
                        print("M,\(s.service),\(s.stamp),\(s.x),\(s.y),\(s.z)")
                    }
                case .location(let p, let q):
                    say("location \(p) \(q)")
                    session.location(p, q)
                case .uarp(let type, let id, let body):
                    session.handle(type: type, id: id, body: body)
                }
            }
            let now = uptime()
            if let f = session.failure { code = f.code; why = f.reason; say("session failed: \(f.reason) (code \(f.code))"); break loop }
            if !verified, (fresh[11] ?? 0) >= 25, (fresh[12] ?? 0) >= 25 { verified = true; say("motion flowing") }
            if verified {
                for service in [11, 12] where now - (last[service]?.at ?? 0) > 3 { code = 43; why = "motion stopped arriving"; say("motion stopped arriving"); break loop }
            } else if now - began > 15 { code = 30; why = "no motion within 15 s"; break loop }
            if now >= nextStatus { say("STATUS \(session.summary) opcodes \(parser.opcodeSummary)"); nextStatus = now + 5 }
        }

        // Cleanup: sensors first, then the held asset.
        say("stopping")
        _ = write(output, Wire.sensorSetting(service: 11, interval: 0, sequence: nextSequence()), "accelerometer stop")
        _ = write(output, Wire.sensorSetting(service: 12, interval: 0, sequence: nextSequence()), "gyroscope stop")
        session.beginCleanup()
        let until = uptime() + 1.5
        while session.cleanupSent && !session.cleanupAck && uptime() < until && !ended(input) {
            pump(0.02)
            for case .uarp(let type, let id, let body) in drain() { session.handle(type: type, id: id, body: body) }
        }
        if session.accepted && !session.cleanupAck { say("the case did not confirm releasing its asset") }
        input.close(); output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
        return (code, why)
    }
}
