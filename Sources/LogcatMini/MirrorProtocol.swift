import Foundation
import CoreGraphics

/// Wire format is pinned to the bundled scrcpy 5.0.1 server. It is not a public API.
enum MirrorProtocol {
    static let serverVersion = "5.0.1"
    static let maximumPacketSize = 8 * 1024 * 1024
    static let maximumClipboardSize = (1 << 18) - 5

    enum DeviceMessage: Equatable {
        case clipboard(String)
        case clipboardAcknowledgement(UInt64)
        case keyboardOutput
    }

    /// Exact reads preserve framing across fragmented/coalesced TCP packets.
    static func deviceMessage(read: (Int) throws -> Data) throws -> DeviceMessage {
        func exact(_ count: Int) throws -> Data {
            let data = try read(count)
            guard data.count == count else { throw MirrorError.message("手机控制消息不完整。") }
            return data
        }
        switch try exact(1)[0] {
        case 0:
            let size = Int(try exact(4).mirrorInteger(at: 0, bytes: 4))
            guard size <= maximumClipboardSize else { throw MirrorError.message("手机剪贴板消息过大。") }
            guard let text = String(data: try exact(size), encoding: .utf8) else {
                throw MirrorError.message("手机剪贴板文字编码无效。")
            }
            return .clipboard(text)
        case 1:
            return .clipboardAcknowledgement(try exact(8).mirrorInteger(at: 0, bytes: 8))
        case 2:
            let header = try exact(4)
            _ = try exact(Int(header.mirrorInteger(at: 2, bytes: 2)))
            return .keyboardOutput
        default:
            throw MirrorError.message("手机返回了不支持的控制消息，请重新连接投屏。")
        }
    }

    static let copySelection = Data([8, 1]) // GET_CLIPBOARD with COPY key
    static let getClipboard = Data([8, 0])

    enum Packet: Equatable {
        case session(width: Int, height: Int)
        case media(size: Int, configuration: Bool, presentationTime: UInt64)
    }

    static func packetHeader(_ data: Data) throws -> Packet {
        guard data.count == 12 else { throw MirrorError.message("投屏数据头不完整。") }
        if data[0] & 0x80 != 0 {
            let width = Int(data.mirrorInteger(at: 4, bytes: 4))
            let height = Int(data.mirrorInteger(at: 8, bytes: 4))
            guard (1...8192).contains(width), (1...8192).contains(height) else {
                throw MirrorError.message("投屏画面尺寸无效。")
            }
            return .session(width: width, height: height)
        }
        let size = Int(data.mirrorInteger(at: 8, bytes: 4))
        guard (1...maximumPacketSize).contains(size) else { throw MirrorError.message("投屏数据包大小无效。") }
        return .media(size: size, configuration: data[0] & 0x40 != 0,
                      presentationTime: data.mirrorInteger(at: 0, bytes: 8) & 0x1fff_ffff_ffff_ffff)
    }

    /// Annex B (3- or 4-byte start codes) to individual NAL units.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = [], start: Int?, index = 0
        while index + 2 < bytes.count {
            var prefix = 0
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { prefix = 3 }
                else if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 { prefix = 4 }
            }
            if prefix > 0 {
                if let start, start < index { units.append(Data(bytes[start..<index])) }
                index += prefix; start = index
            } else { index += 1 }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    static func key(_ code: UInt32) -> Data {
        var data = Data()
        for action: UInt8 in [0, 1] {
            data.append(contentsOf: [0, action]); data.mirrorAppend(code)
            data.mirrorAppend(UInt32(0)); data.mirrorAppend(UInt32(0))
        }
        return data
    }

    // KEYCODE_WAKEUP is idempotent: an already-awake phone stays awake.
    // Do not use KEYCODE_POWER here, which would toggle the display off.
    static let wakeUp = key(224)

    static func touch(action: UInt8, point: CGPoint, size: CGSize) -> Data {
        var data = Data([2, action])
        data.mirrorAppend(UInt64.max - 1) // POINTER_ID_GENERIC_FINGER
        appendPosition(point, size: size, to: &data)
        data.mirrorAppend(action == 1 || action == 3 ? UInt16(0) : UInt16.max)
        data.mirrorAppend(UInt32(0)); data.mirrorAppend(UInt32(0))
        return data
    }

    static func scroll(point: CGPoint, size: CGSize, horizontal: Double, vertical: Double) -> Data {
        var data = Data([3]); appendPosition(point, size: size, to: &data)
        for value in [horizontal, vertical] {
            let fixed = Int16(max(-32768, min(32767, value * 2048)))
            data.mirrorAppend(UInt16(bitPattern: fixed))
        }
        data.mirrorAppend(UInt32(0)); return data
    }

    static func text(_ text: String, paste: Bool) -> Data? {
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty, utf8.count <= (paste ? 64_000 : 300) else { return nil }
        var data = Data([paste ? 9 : 1])
        if paste { data.mirrorAppend(UInt64(0)); data.append(1) }
        data.mirrorAppend(UInt32(utf8.count)); data.append(utf8); return data
    }

    /// A temporary physical keyboard lets Android suppress the IME while clipboard input stays usable.
    /// Standard USB HID boot-keyboard descriptor; no key reports are sent by this device.
    static func keyboardCreate(name: String) -> Data {
        let descriptor = Data([
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, // Generic Desktop / Keyboard
            0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, 0x95, 0x08, 0x81, 0x02, // eight modifier bits
            0x75, 0x08, 0x95, 0x01, 0x81, 0x01, // reserved byte
            0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65,
            0x75, 0x08, 0x95, 0x06, 0x81, 0x00, 0xc0 // six key codes
        ])
        // The session supplies a short ASCII name; constrain it to scrcpy's 127-byte maximum.
        let label = Data(name.utf8.prefix(127))
        var data = Data([12]); data.mirrorAppend(UInt16(1)) // session-local UHID id
        data.mirrorAppend(UInt16(0)); data.mirrorAppend(UInt16(0)) // vendor / product
        data.append(UInt8(label.count)); data.append(label)
        data.mirrorAppend(UInt16(descriptor.count)); data.append(descriptor)
        return data
    }

    static let keyboardDestroy = Data([14, 0, 1])
    static let openKeyboardSettings = Data([15])

    private static func appendPosition(_ point: CGPoint, size: CGSize, to data: inout Data) {
        data.mirrorAppend(UInt32(max(0, min(size.width - 1, point.x))))
        data.mirrorAppend(UInt32(max(0, min(size.height - 1, point.y))))
        data.mirrorAppend(UInt16(clamping: Int(size.width)))
        data.mirrorAppend(UInt16(clamping: Int(size.height)))
    }

    static func contentRect(in bounds: CGRect, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0 else { return .zero }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func devicePoint(_ point: CGPoint, in bounds: CGRect, video: CGSize, clamp: Bool = false) -> CGPoint? {
        let rect = contentRect(in: bounds, video: video)
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: max(0, min(video.width - 1, (point.x - rect.minX) * video.width / rect.width)),
                       y: max(0, min(video.height - 1, (point.y - rect.minY) * video.height / rect.height)))
    }
}

enum MirrorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

extension Data {
    mutating func mirrorAppend<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func mirrorInteger(at offset: Int, bytes: Int) -> UInt64 {
        self[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
