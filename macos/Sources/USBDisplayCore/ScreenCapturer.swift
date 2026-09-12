import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let params: VirtualDisplayParams
    private let onFrame: (CVPixelBuffer,UInt64)->Void
    public var onError: ((Error)->Void)?
    private var stream: SCStream?
    private let queue=DispatchQueue(label:"dev.configcrate.usbdisplay.capture",qos:.userInteractive)
    public init(displayID: CGDirectDisplayID,params: VirtualDisplayParams,
                onFrame: @escaping (CVPixelBuffer,UInt64)->Void) {
        self.displayID=displayID; self.params=params; self.onFrame=onFrame
    }
    /// Call from a worker; main run loop must stay alive.
    public func start() throws {
        let semaphore=DispatchSemaphore(value:0)
        var found: SCDisplay?
        var failure: Error?
        SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly:false) { content,error in
            failure=error
            found=content?.displays.first { $0.displayID==self.displayID }
            semaphore.signal()
        }
        guard semaphore.wait(timeout:.now()+15) == .success else { throw DisplayError.captureUnavailable }
        if let failure { throw failure }
        guard let found else { throw DisplayError.captureUnavailable }
        let config=SCStreamConfiguration()
        config.width=params.width; config.height=params.height
        config.minimumFrameInterval=CMTime(value:1,timescale:Int32(params.refreshRate))
        config.pixelFormat=kCVPixelFormatType_32BGRA
        config.showsCursor=true; config.scalesToFit=true
        config.queueDepth=3; config.capturesAudio=false
        let capture=SCStream(filter:SCContentFilter(display:found,excludingWindows:[]),
                             configuration:config,delegate:self)
        try capture.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        stream=capture
        let started=DispatchSemaphore(value:0)
        var startError: Error?
        capture.startCapture { error in startError=error; started.signal() }
        guard started.wait(timeout:.now()+15) == .success else { throw DisplayError.captureUnavailable }
        if let startError { throw startError }
    }
    public func stop() { stream?.stopCapture { _ in }; stream=nil }
    public func stream(_ stream: SCStream,didOutputSampleBuffer sample: CMSampleBuffer,of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
            let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
            let info=attachments.first, let raw=info[.status] as? Int,
            SCFrameStatus(rawValue:raw) == .complete,
            let buffer=CMSampleBufferGetImageBuffer(sample) else { return }
        onFrame(buffer,MonotonicClock.microseconds)
    }
    public func stream(_ stream: SCStream,didStopWithError error: Error) {
        fputs("Screen capture stopped: \(error.localizedDescription)\n",stderr)
        onError?(error)
    }
}
