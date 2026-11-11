import Foundation

// Wire format of the AirPods control channel (L2CAP PSM 0x1001, "AACP").
//
// Every message starts with the magic 04 00 04 00, followed by a little-endian
// opcode. The opcodes that matter here:
//   0x4f  a UARP envelope (big-endian type / length / identifier + body)
//   0x06  two bytes: where the earbud thinks it is (in ear, in case, lid ...)
//   0x17  a protobuf blob; descriptor 0x100000 carries accelerometer / gyro reports
// Anything else is skipped as a fixed six byte header.

struct Sample {
    var service: Int      // 11 = accelerometer, 12 = gyroscope
    var stamp: UInt64     // sensor clock, microseconds
    var x: Int32
    var y: Int32
    var z: Int32
}

enum Event {
    case uarp(type: UInt16, id: UInt16, body: [UInt8])
    case location(primary: UInt8, secondary: UInt8)
    case motion(Sample)
}

struct PBField {
    let number: Int
    let varint: UInt64?
    let bytes: [UInt8]?
}

enum Wire {
    // MARK: integers

    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func put16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    // MARK: protobuf

    static func varint(_ value: UInt32) -> [UInt8] {
        var v = value, out = [UInt8]()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func readVarint(_ d: [UInt8], _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard i < d.count else { return nil }
            let byte = d[i]; i += 1
            if shift == 63 && byte > 1 { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    static func fields(_ d: [UInt8]) -> [PBField] {
        var out = [PBField]()
        var i = 0
        while i < d.count {
            guard let key = readVarint(d, &i), key >> 3 != 0 else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint(d, &i) else { return out }
                out.append(PBField(number: number, varint: v, bytes: nil))
            case 2:
                guard let n = readVarint(d, &i), n <= UInt64(d.count - i) else { return out }
                out.append(PBField(number: number, varint: nil, bytes: Array(d[i..<(i + Int(n))])))
                i += Int(n)
            case 1, 5:
                let n = (key & 7) == 1 ? 8 : 4
                guard n <= d.count - i else { return out }
                i += n
            default:
                return out
            }
        }
        return out
    }

    // MARK: outgoing messages

    static let handshake: [UInt8] = [0, 0, 4, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let features: [UInt8] = [4, 0, 4, 0, 0x4d, 0, 0xff, 0, 0, 0, 0, 0, 0, 0]
    static let notifications: [UInt8] = [4, 0, 4, 0, 0x0f, 0, 0xff, 0xff, 0xff, 0xff]

    /// Starts (interval > 0, microseconds between reports) or stops (0) one sensor.
    static func sensorSetting(service: UInt8, interval: UInt32, sequence: UInt32) -> [UInt8] {
        let setting: [UInt8] = [8, service, 16, 2, 26, 5, 1,
                                UInt8(interval & 0xff), UInt8((interval >> 8) & 0xff),
                                UInt8((interval >> 16) & 0xff), UInt8((interval >> 24) & 0xff)]
        let message: [UInt8] = [8] + varint(sequence) + [66, UInt8(setting.count)] + setting
        let n = message.count
        return [4, 0, 4, 0, 0x17, 0, 0, 0, 0x10, 0, UInt8(n & 0xff), UInt8(n >> 8)] + message
    }

    /// One UARP envelope on the control channel.
    static func uarp(type: UInt16, id: UInt16, body: [UInt8]) -> [UInt8] {
        let outer = UInt16(6 + body.count)
        return [4, 0, 4, 0, 0x4f, 0, UInt8(outer & 0xff), UInt8(outer >> 8)]
            + put16(type) + put16(UInt16(body.count)) + put16(id) + body
    }

    /// A message for the charging case, tunnelled through the earbud (endpoint 1).
    static func caseFrame(type: UInt16, childID: UInt16, body: [UInt8], rootID: UInt16) -> [UInt8] {
        let inner = put16(type) + put16(UInt16(body.count)) + put16(childID) + body
        return uarp(type: 0x1b, id: rootID, body: [0, 1] + inner)
    }

    /// Decodes a ModelName reply body (property 2), or nil if it is malformed.
    static func modelName(_ body: [UInt8]) -> String? {
        guard body.count >= 10, be16(body, 0) == 0, be32(body, 2) == 2 else { return nil }
        let n = Int(be32(body, 6))
        guard n == body.count - 10, n <= 128 else { return nil }
        return String(bytes: body[10...], encoding: .utf8)
    }

    // MARK: model names

    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).lowercased()
    }
    static func isEarbud(_ name: String) -> Bool {
        let f = fold(name)
        return (f.hasPrefix("airpods pro") || f == "airpods" || f.hasPrefix("airpods 4")) && !f.contains("case")
    }
    static func isCase(_ name: String?) -> Bool {
        guard let name else { return false }
        let f = fold(name)
        return f.contains("case") && (f.hasPrefix("airpods") || f.hasPrefix("charging case")
            || f.hasPrefix("wireless charging case") || f.hasPrefix("magsafe charging case"))
    }

    /// The case offers a 30 byte "MTIC" diagnostic asset; returns its id and length.
    static func parseOffer(_ body: [UInt8]) -> (asset: UInt16, length: UInt32)? {
        guard body.count == 30, Array(body[0..<4]) == Array("MTIC".utf8), be16(body, 4) == 0x0a else { return nil }
        let asset = be16(body, 6), length = be32(body, 24)
        guard asset != 0, asset != 0xffff, length != 0, length <= 65536 else { return nil }
        return (asset, length)
    }
}

/// Splits the byte stream from the channel into events. Feed it whatever arrives.
final class Parser {
    private var buffer = [UInt8]()
    private var scanned = 0
    private(set) var controls = 0
    private(set) var chunks = 0
    private var opcodes: [Int: Int] = [:]
    /// Other devices the AirPods say they are talking to (opcode 0x11 carries a Bluetooth address).
    private(set) var peers = Set<String>()
    var trace: ((String) -> Void)?
    private var traced = 0
    /// e.g. "0x4f:12 0x17:800", for diagnostics.
    var opcodeSummary: String {
        opcodes.sorted { $0.key < $1.key }.map { String(format: "0x%x:%d", $0.key, $0.value) }.joined(separator: " ")
    }

    func feed(_ chunk: [UInt8]) -> [Event] {
        chunks += 1
        buffer += chunk
        if buffer.count > 262_144 { buffer.removeAll(); scanned = 0; return [] }
        var events = [Event]()
        let b = buffer
        let count = b.count
        while scanned + 6 <= count {
            let i = scanned
            guard b[i] == 4, b[i + 1] == 0, b[i + 2] == 4, b[i + 3] == 0 else { scanned += 1; continue }
            let opcode = Wire.le16(b, i + 4)
            opcodes[opcode, default: 0] += 1
            if opcode == 0x4f {
                if i + 8 > count { break }
                let size = Wire.le16(b, i + 6)
                if size > 32768 { scanned += 1; continue }
                if i + 8 + size > count { break }
                if size >= 6 {
                    let u = Array(b[(i + 8)..<(i + 8 + size)])
                    let length = Int(Wire.be16(u, 2))
                    if size == length + 6 {
                        events.append(.uarp(type: Wire.be16(u, 0), id: Wire.be16(u, 4), body: Array(u[6...])))
                    }
                }
                controls += 1
                scanned += 8 + size
            } else if opcode == 0x06 {
                if i + 8 > count { break }
                events.append(.location(primary: b[i + 6], secondary: b[i + 7]))
                controls += 1
                scanned += 8
            } else if opcode == 0x17 {
                if i + 12 > count { break }
                let descriptor = Wire.le32(b, i + 6)
                let size = Wire.le16(b, i + 10)
                if i + 12 + size > count { break }
                if descriptor == 0x100000 {
                    let payload = Array(b[(i + 12)..<(i + 12 + size)])
                    for outer in Wire.fields(payload) where outer.number == 7 {
                        guard let inner = outer.bytes else { continue }
                        var service: UInt64?
                        var report: [UInt8]?
                        for f in Wire.fields(inner) {
                            if f.number == 1 { service = f.varint }
                            if f.number == 3 { report = f.bytes }
                        }
                        guard let s = service, s == 11 || s == 12, let r = report, r.count == 28, r[0] == 1 else { continue }
                        let stamp = UInt64(Wire.le32(r, 20)) | UInt64(Wire.le32(r, 24)) << 32
                        guard stamp > 0 else { continue }
                        events.append(.motion(Sample(service: Int(s), stamp: stamp,
                                                     x: Int32(bitPattern: Wire.le32(r, 1)),
                                                     y: Int32(bitPattern: Wire.le32(r, 5)),
                                                     z: Int32(bitPattern: Wire.le32(r, 9)))))
                    }
                }
                controls += 1
                scanned += 12 + size
            } else {
                if opcode == 0x11, i + 12 <= count {
                    peers.insert((0..<6).map { String(format: "%02X", b[i + 11 - $0]) }.joined(separator: ":"))
                }
                if [2, 4, 8, 12, 14, 43, 46, 79].contains(opcode) { controls += 1 }
                else if traced < 80 {
                    traced += 1
                    let tail = b[i..<min(count, i + 16)].map { String(format: "%02x", $0) }.joined()
                    trace?("odd opcode 0x\(String(opcode, radix: 16)): \(tail)")
                }
                scanned += 6
            }
        }
        if scanned > 0 { buffer.removeFirst(min(scanned, buffer.count)); scanned = 0 }
        return events
    }
}
