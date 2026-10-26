import XCTest
@testable import LogcatMini

final class MirrorClipboardTests: XCTestCase {
    func testUnicodeClipboardInterleavedWithAcknowledgementsAndKeyboardOutput() throws {
        let text = "手机复制 → Mac\n中文 👋\t第二行"
        var bytes = Data([1]); bytes.mirrorAppend(UInt64(42))
        bytes.append(contentsOf: [2, 0, 1, 0, 3, 7, 8, 9])
        bytes.append(0); bytes.mirrorAppend(UInt32(text.utf8.count)); bytes.append(Data(text.utf8))
        bytes.append(contentsOf: [0, 0, 0, 0, 0])
        var offset = 0
        func read(_ count: Int) throws -> Data {
            guard offset + count <= bytes.count else { throw MirrorError.message("EOF") }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        XCTAssertEqual(try MirrorProtocol.deviceMessage(read: read), .clipboardAcknowledgement(42))
        XCTAssertEqual(try MirrorProtocol.deviceMessage(read: read), .keyboardOutput)
        XCTAssertEqual(try MirrorProtocol.deviceMessage(read: read), .clipboard(text))
        XCTAssertEqual(try MirrorProtocol.deviceMessage(read: read), .clipboard(""))
        XCTAssertEqual(offset, bytes.count)
        XCTAssertEqual(MirrorProtocol.copySelection, Data([8, 1]))
        XCTAssertEqual(MirrorProtocol.getClipboard, Data([8, 0]))
    }

    func testRejectsOversizedTruncatedUnknownAndInvalidUTF8Messages() {
        for bytes in [Data([0, 0xff, 0xff, 0xff, 0xff]), Data([0, 0, 0, 0, 3, 65]),
                      Data([17]), Data([1, 0]), Data([0, 0, 0, 0, 1, 0xff])] {
            var offset = 0
            XCTAssertThrowsError(try MirrorProtocol.deviceMessage { count in
                let size = min(count, bytes.count - offset)
                defer { offset += size }
                return Data(bytes[offset..<(offset + size)])
            })
        }
    }
}
