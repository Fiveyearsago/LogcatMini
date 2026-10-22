import AVFoundation
import VideoToolbox

/// Runs on the stream reader only. VideoToolbox decodes off the UI thread.
final class MirrorDecoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    var onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) { self.onFrame = onFrame }
    deinit { reset() }

    func reset() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; sps = nil; pps = nil
    }

    func consume(_ packet: Data, configuration: Bool, presentationTime: UInt64) throws {
        let units = MirrorProtocol.nalUnits(packet)
        guard !units.isEmpty else { throw MirrorError.message("无法解析手机的视频数据。") }
        if configuration {
            for unit in units {
                if unit.first.map({ $0 & 0x1f }) == 7 { sps = unit }
                if unit.first.map({ $0 & 0x1f }) == 8 { pps = unit }
            }
            if let sps, let pps { try configure(sps: sps, pps: pps) }
            return
        }
        guard let format, let session else { throw MirrorError.message("手机未提供 H.264 解码配置。") }
        var avcc = Data()
        for unit in units { avcc.mirrorAppend(UInt32(unit.count)); avcc.append(unit) }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: avcc.count, flags: 0, blockBufferOut: &block))
        guard let block else { return }
        try avcc.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count))
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(presentationTime), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count, sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        if let sample {
            try check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil))
        }
    }

    private func configure(sps: Data, pps: Data) throws {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil
        try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                try check(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                             parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                             nalUnitHeaderLength: 4, formatDescriptionOut: &format))
            }
        }
        guard let format else { return }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard status == noErr, let ref, let image else { return }
            Unmanaged<MirrorDecoder>.fromOpaque(ref).takeUnretainedValue().onFrame(image)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                              imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                                      kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                              outputCallback: &callback, decompressionSessionOut: &session))
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw MirrorError.message("投屏视频解码失败（\(status)），请重连投屏。") }
    }
}
