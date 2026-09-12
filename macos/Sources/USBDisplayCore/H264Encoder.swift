import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

public final class H264Encoder {
    public struct Config {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrateBps: Int
        public init(width: Int, height: Int, fps: Int = 30, bitrateBps: Int = 8_000_000) {
            self.width=width; self.height=height; self.fps=fps; self.bitrateBps=bitrateBps
        }
    }
    public private(set) var config: Config
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "dev.configcrate.usbdisplay.encoder")
    private let lock = NSLock()
    private var inFlight = false
    private var active = false
    private var durations: [UInt32] = []
    public var onEncodedFrame: (([UInt8], Bool, UInt64) -> Void)?
    public init(config: Config) { self.config=config }
    public func start() throws {
        try queue.sync {
            var output: VTCompressionSession?
            let rc = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(config.width), height: Int32(config.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
                    guard let refcon else { return }
                    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                    defer { encoder.lock.lock(); encoder.inFlight=false; encoder.lock.unlock() }
                    guard status == noErr, let sample else { return }
                    encoder.handleEncoded(sample)
                }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &output)
            guard rc == noErr, let output else { throw EncoderError.creationFailed(rc) }
            session=output
            set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1))
            set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: config.bitrateBps))
            set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps))
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: config.fps * 2))
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
            VTCompressionSessionPrepareToEncodeFrames(output)
            lock.lock(); active=true; lock.unlock()
        }
    }
    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let rc=VTSessionSetProperty(session,key:key,value:value)
        if rc != noErr { fputs("VideoToolbox property not supported: \(key), \(rc)\n",stderr) }
    }
    public func updateBitrate(_ bps: Int) {
        queue.async {
            self.config.bitrateBps=bps
            self.set(kVTCompressionPropertyKey_AverageBitRate,NSNumber(value:bps))
        }
    }
    /// Only one frame in flight including USB delivery: skip captures, never
    /// discard half an encoded message or accumulate an unbounded queue.
    @discardableResult
    public func encode(pixelBuffer: CVPixelBuffer, captureTimestampUs: UInt64, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        guard active, !inFlight else { lock.unlock(); return false }
        inFlight=true; lock.unlock()
        queue.async {
            guard let session=self.session else {
                self.lock.lock(); self.inFlight=false; self.lock.unlock(); return
            }
            let pts=CMTime(value:Int64(captureTimestampUs),timescale:1_000_000)
            let props: CFDictionary? = forceKeyframe ?
                [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let rc=VTCompressionSessionEncodeFrame(session,imageBuffer:pixelBuffer,
                presentationTimeStamp:pts,duration:CMTime(value:1,timescale:Int32(self.config.fps)),
                frameProperties:props,sourceFrameRefcon:nil,infoFlagsOut:nil)
            if rc != noErr {
                fputs("Encode failed: \(rc)\n",stderr)
                self.lock.lock(); self.inFlight=false; self.lock.unlock()
            }
        }
        return true
    }
    public func drain() { queue.sync { if let session { VTCompressionSessionCompleteFrames(session,untilPresentationTimeStamp:.invalid) } } }
    public func stop() {
        lock.lock(); active=false; lock.unlock()
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session,untilPresentationTimeStamp:.invalid)
                VTCompressionSessionInvalidate(session)
            }
            session=nil
        }
    }
    private func handleEncoded(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), let data=CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var length=0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(data,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,
            dataPointerOut:&pointer)==kCMBlockBufferNoErr, let pointer else { return }
        let bytes=Array(UnsafeBufferPointer(start:UnsafeRawPointer(pointer).assumingMemoryBound(to:UInt8.self),count:length))
        var annex: [UInt8]=[]
        var headerLength: Int32=4
        if let format=CMSampleBufferGetFormatDescription(sample) {
            var count=0
            let rc=CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,parameterSetIndex:0,
                parameterSetPointerOut:nil,parameterSetSizeOut:nil,parameterSetCountOut:&count,nalUnitHeaderLengthOut:&headerLength)
            if rc==noErr && keyframe {
                for index in 0..<count {
                    var p: UnsafePointer<UInt8>?
                    var size=0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,parameterSetIndex:index,
                        parameterSetPointerOut:&p,parameterSetSizeOut:&size,parameterSetCountOut:nil,nalUnitHeaderLengthOut:nil)==noErr,
                        let p {
                        annex += [0,0,0,1]; annex += Array(UnsafeBufferPointer(start:p,count:size))
                    }
                }
            }
        }
        guard headerLength==4 else { return }
        var offset=0
        while offset+4<=bytes.count {
            let n=(Int(bytes[offset])<<24)|(Int(bytes[offset+1])<<16)|(Int(bytes[offset+2])<<8)|Int(bytes[offset+3])
            offset += 4
            guard n>0, n<=bytes.count-offset else { return }
            annex += [0,0,0,1]; annex += bytes[offset..<(offset+n)]; offset += n
        }
        guard offset==bytes.count, !annex.isEmpty else { return }
        let ts=UInt64(max(0,CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))*1_000_000)
        let now=MonotonicClock.microseconds
        lock.lock()
        durations.append(UInt32(clamping:now>=ts ? now-ts:0))
        if durations.count>120 { durations.removeFirst() }
        lock.unlock()
        onEncodedFrame?(annex,keyframe,ts)
    }
    public var encodeDurationP50: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return durations.isEmpty ? 0:durations.sorted()[durations.count/2]
    }
}
public enum EncoderError: LocalizedError {
    case creationFailed(OSStatus)
    public var errorDescription: String? { if case .creationFailed(let rc)=self { return "VideoToolbox creation failed: \(rc)" }; return nil }
}
