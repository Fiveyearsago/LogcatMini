import XCTest
import AVFoundation
import ImageIO
@testable import LogcatMini

final class MediaThumbnailTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaThumbnailTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func record(_ url: URL, kind: CaptureKind = .screenshot) -> CaptureRecord {
        CaptureRecord(id: UUID(), kind: kind, url: url, createdAt: Date(), deviceName: "QA", serial: "qa", duration: nil)
    }
    private func writeImage(_ url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func testScreenshotDownsamplesAndHonorsOrientation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rotated.jpg")
        try writeImage(url, width: 2400, height: 1200, orientation: 6)
        let result = await MediaThumbnailLoader().image(for: record(url), maxPixelSize: 200)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 200)
    }
    func testReplacementAndDeletionDoNotReuseStaleThumbnail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.jpg"), loader = MediaThumbnailLoader()
        try writeImage(url, width: 100, height: 200)
        let first = await loader.image(for: record(url), maxPixelSize: 200)
        XCTAssertEqual(first?.height, 200)
        try writeImage(url, width: 400, height: 100)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        let replacement = await loader.image(for: record(url), maxPixelSize: 200)
        XCTAssertEqual(replacement?.width, 200); XCTAssertEqual(replacement?.height, 50)
        try FileManager.default.removeItem(at: url)
        let missing = await loader.image(for: record(url), maxPixelSize: 200)
        XCTAssertNil(missing)
    }
    func testCorruptFilesAndCancelledQueuedLoadReturnWithoutImage() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("corrupt.mp4")
        try Data("not media".utf8).write(to: url)
        let loader = MediaThumbnailLoader()
        for kind in CaptureKind.allCases {
            let result = await loader.image(for: record(url, kind: kind), maxPixelSize: 200)
            XCTAssertNil(result)
        }
        try writeImage(url, width: 100, height: 200)
        let queue = OperationQueue(); queue.isSuspended = true
        let queuedLoader = MediaThumbnailLoader(queue: queue), item = record(url)
        let work = Task { await queuedLoader.image(for: item, maxPixelSize: 200) }
        work.cancel(); queue.isSuspended = false
        let result = await work.value
        XCTAssertNil(result)
    }
    func testRecordingProducesBoundedTransformedPoster() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 256, AVVideoHeightKey: 128
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 256, kCVPixelBufferHeightKey as String: 128
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 256, 128, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(adapter.append(pixels, withPresentationTime: .zero))
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        let result = await MediaThumbnailLoader().image(for: record(url, kind: .recording), maxPixelSize: 100)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 50); XCTAssertEqual(image.height, 100)
    }
}
