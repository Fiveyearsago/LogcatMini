import AppKit
import AVFoundation
import ImageIO

/// Decode small previews off the main thread, with bounded work and memory while scrolling.
final class MediaThumbnailLoader: @unchecked Sendable {
    static let shared = MediaThumbnailLoader()
    private let queue: OperationQueue
    private let cache = NSCache<NSString, CGImage>()

    init(queue: OperationQueue = OperationQueue()) {
        self.queue = queue
        queue.name = "LogcatMini.MediaThumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for record: CaptureRecord, maxPixelSize: Int) async -> CGImage? {
        let request = Request()
        let size = min(512, max(32, maxPixelSize))
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.addOperation { [self] in
                    // URL resourceValues may reuse cached metadata after replacement or deletion.
                    guard !request.cancelled, record.url.isFileURL,
                          let attributes = try? FileManager.default.attributesOfItem(atPath: record.url.resolvingSymlinksInPath().path),
                          attributes[.type] as? FileAttributeType == .typeRegular else { continuation.resume(returning: nil); return }
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let key = "\(record.url.absoluteString)|\(record.kind.rawValue)|\(size)|\(modified)|\(attributes[.size] ?? 0)|\(attributes[.systemFileNumber] ?? 0)" as NSString
                    let result: CGImage? = autoreleasepool {
                        if let image = cache.object(forKey: key) { return image }
                        guard !request.cancelled else { return nil }
                        let image = Self.decode(record, size: size)
                        if let image, !request.cancelled {
                            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                        }
                        return image
                    }
                    continuation.resume(returning: request.cancelled ? nil : result)
                }
            }
        }, onCancel: { request.cancel() })
    }

    private static func decode(_ record: CaptureRecord, size: Int) -> CGImage? {
        if record.kind == .screenshot {
            guard let source = CGImageSourceCreateWithURL(record.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ] as CFDictionary)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: record.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
    }
}
