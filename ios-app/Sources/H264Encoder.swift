import Foundation
import VideoToolbox
import CoreMedia

final class H264Encoder {
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "com.salvador.camlink.h264", qos: .userInteractive)
    var onEncodedFrame: ((Data, UInt64) -> Void)?

    private var width: Int32 = 1080
    private var height: Int32 = 1920
    private var fps: Int = 30
    private var bitrateBps: Int = 8_000_000

    func configure(width: Int32, height: Int32, fps: Int, bitrateMbps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrateBps = bitrateMbps * 1_000_000
            self.rebuildSession()
        }
    }

    private func rebuildSession() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let s = newSession else { return }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        let bytesPerSec = bitrateBps / 8
        let limits = [bytesPerSec * 2, 1] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)

        VTCompressionSessionPrepareToEncodeFrames(s)
        self.session = s
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        queue.async { [weak self] in
            guard let self, let s = self.session else { return }
            VTCompressionSessionEncodeFrame(
                s,
                imageBuffer: imageBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { [weak self] status, _, encodedBuffer in
                guard status == noErr, let encodedBuffer else { return }
                self?.handleEncoded(sampleBuffer: encodedBuffer)
            }
        }
    }

    private func handleEncoded(sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var annexB = Data()

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsPtr: UnsafePointer<UInt8>?
            var spsSize = 0
            var ppsPtr: UnsafePointer<UInt8>?
            var ppsSize = 0

            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let spsPtr {
                annexB.append(contentsOf: startCode)
                annexB.append(spsPtr, count: spsSize)
            }

            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let ppsPtr {
                annexB.append(contentsOf: startCode)
                annexB.append(ppsPtr, count: ppsSize)
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else { return }

        var offset = 0
        while offset + 4 <= totalLength {
            var naluLen: UInt32 = 0
            memcpy(&naluLen, dataPointer + offset, 4)
            naluLen = CFSwapInt32BigToHost(naluLen)
            offset += 4
            guard offset + Int(naluLen) <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(UnsafeBufferPointer(start: UnsafeRawPointer(dataPointer + offset).assumingMemoryBound(to: UInt8.self), count: Int(naluLen)))
            offset += Int(naluLen)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsUs = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000.0)) : 0
        onEncodedFrame?(annexB, tsUs)
    }

    func stop() {
        queue.async { [weak self] in
            if let s = self?.session {
                VTCompressionSessionInvalidate(s)
                self?.session = nil
            }
        }
    }
}
