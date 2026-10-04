import CoreMedia
import Foundation
import VideoToolbox

/// Low-latency H.264 encoder. Call `encode` and `invalidate` from a single queue;
/// `onPacket` fires on a VideoToolbox thread with an encoded `VideoPacket` payload.
final class H264Encoder {
    var onPacket: ((Data) -> Void)?

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0

    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var force = forceKeyframe
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
            force = true
        }
        guard let session else { return }

        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        duration: .invalid,
                                        frameProperties: properties,
                                        infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func makeSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        self.width = width
        self.height = height

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &newSession)
        guard status == noErr, let newSession else { return }

        // Screen content is mostly text, so spend bits generously; a wired/Wi-Fi LAN can take it.
        let bitrate = min(max(width * height * 4, 4_000_000), 30_000_000)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 3600,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(newSession, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer {
                    parameterSets.append(Data(bytes: pointer, count: size))
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }

        onPacket?(VideoPacket(isKeyframe: isKeyframe, parameterSets: parameterSets, data: data).encoded())
    }
}
