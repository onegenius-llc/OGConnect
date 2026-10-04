import AVFoundation
import CoreMedia
import UIKit

/// Turns incoming `VideoPacket`s into sample buffers and hands them to a display layer,
/// which does the H.264 decoding.
final class VideoRenderer {
    /// Both callbacks are invoked on the main thread.
    var onVideoSize: ((CGSize) -> Void)?
    var onNeedsKeyframe: (() -> Void)?

    private weak var layer: AVSampleBufferDisplayLayer?  // main thread only

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    /// Drops any decode state, e.g. before a new stream or after the app was in the background.
    func reset() {
        lock.withLock {
            format = nil
            waitingForKeyframe = true
        }
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Called on the connection queue.
    func handle(_ payload: Data) {
        guard let packet = VideoPacket(payload: payload) else { return }

        var newSize: CGSize?
        let format: CMVideoFormatDescription? = lock.withLock {
            if packet.isKeyframe, !packet.parameterSets.isEmpty,
               let description = Self.makeFormat(packet.parameterSets) {
                let old = self.format.map(CMVideoFormatDescriptionGetDimensions)
                let new = CMVideoFormatDescriptionGetDimensions(description)
                if old?.width != new.width || old?.height != new.height {
                    newSize = CGSize(width: Int(new.width), height: Int(new.height))
                }
                self.format = description
                waitingForKeyframe = false
            }
            return waitingForKeyframe ? nil : self.format
        }
        guard let format, let sampleBuffer = Self.makeSampleBuffer(packet.data, format: format) else { return }

        DispatchQueue.main.async {
            self.enqueue(sampleBuffer, isKeyframe: packet.isKeyframe, newSize: newSize)
        }
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool, newSize: CGSize?) {
        guard let renderer = layer?.sampleBufferRenderer else { return }
        if let newSize {
            renderer.flush()
            onVideoSize?(newSize)
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            if !isKeyframe {
                lock.withLock { waitingForKeyframe = true }
                onNeedsKeyframe?()
                return
            }
        }
        renderer.enqueue(sampleBuffer)
    }

    private static func makeFormat(_ parameterSets: [Data]) -> CMVideoFormatDescription? {
        let buffers = parameterSets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }

        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = buffers.map(\.count)
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                                                         parameterSetCount: pointers.count,
                                                                         parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4,
                                                                         formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }

        // This is a live view: show each frame the moment it arrives rather than on a timeline.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
