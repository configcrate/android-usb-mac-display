import Foundation
import CoreVideo
import CoreGraphics

public final class DisplayLinkSession {
    public struct Options {
        public var width=1280
        public var height=720
        public var fps=30
        public var bitrateBps=8_000_000
        public var backend: VirtualDisplayBackend = .captureOnly
        public init() {}
    }
    private let options: Options
    private let transport=AOATransport()
    private let framer: FrameFramer
    private let encoder: H264Encoder
    private let injector=InputInjector()
    private var display: VirtualDisplay?
    private var capturer: ScreenCapturer?
    private var displayID: CGDirectDisplayID?
    private let lock=NSLock()
    private var running=false
    private var ready=false
    private var requestIDR=true
    private var latest: CVPixelBuffer?
    private var peer=PeerStats()
    private var rtt: UInt32=0
    private var pingToken: UInt32=0
    private var pingSent: UInt64=0
    private var stopped=false
    private var cancelled=false
    private var currentBitrate: Int
    private var previousDrops: UInt32=0
    public private(set) var failure: Error?
    public init(options: Options = Options()) {
        self.options=options; currentBitrate=options.bitrateBps
        framer=FrameFramer(sink:transport)
        encoder=H264Encoder(config:.init(width:options.width,height:options.height,
            fps:options.fps,bitrateBps:options.bitrateBps))
    }
    public func start() throws {
        do {
            try transport.handshake { self.log($0) }
            lock.lock(); let cancelledAtStart=cancelled; lock.unlock()
            if cancelledAtStart { stop(); return }
            transport.delegate=self
            try encoder.start()
            encoder.onEncodedFrame={ [weak self] bytes,key,ts in
                guard let self else { return }
                self.lock.lock(); let active=self.running; self.lock.unlock()
                if active { self.framer.sendVideo(bytes,keyframe:key,timestampUs:ts) }
            }
            lock.lock(); running=true; lock.unlock()
            transport.start()
            let params=VirtualDisplayParams(width:options.width,height:options.height,refreshRate:options.fps)
            if options.backend == .cgVirtualDisplay {
                let virtual=CGVirtualDisplayBackend(params:params)
                display=virtual
                try virtual.start { [weak self] pb,ts in self?.captured(pb,ts) }
                displayID=virtual.displayID
                log("Experimental extended desktop created")
            } else {
                let id=CGMainDisplayID()
                let capture=ScreenCapturer(displayID:id,params:params) { [weak self] pb,ts in self?.captured(pb,ts) }
                capture.onError={ [weak self] error in
                    guard let self else { return }
                    self.frameSource(self.transport,didFail:error)
                }
                capturer=capture
                try capture.start()
                displayID=id
                log("Mirror mode: this does not create an extra desktop")
            }
            sendConfig()
            log("Waiting for Android decoder readiness. Allow USB permission on the phone.")
        } catch { stop(); throw error }
    }
    private func sendConfig() {
        framer.sendConfig(.init(epoch:1,width:UInt16(options.width),height:UInt16(options.height),
            fps:UInt16(options.fps),bitrateBps:UInt32(currentBitrate)))
    }
    private func captured(_ buffer: CVPixelBuffer,_ ts: UInt64) {
        lock.lock(); latest=buffer
        let active=running && ready
        let force=requestIDR
        if active { requestIDR=false }
        lock.unlock()
        guard active else { return }
        if !encoder.encode(pixelBuffer:buffer,captureTimestampUs:ts,forceKeyframe:force) && force {
            lock.lock(); requestIDR=true; lock.unlock()
        }
    }
    /// Main thread must keep its run loop alive; call run() from a worker.
    public func run() {
        var next=Date.distantPast
        while true {
            lock.lock(); let active=running; let peerReady=ready; lock.unlock()
            guard active else { break }
            if Date()>=next {
                next=Date().addingTimeInterval(1)
                if !peerReady { sendConfig() }
                lock.lock()
                pingToken &+= 1; let token=pingToken; pingSent=MonotonicClock.microseconds
                lock.unlock()
                framer.sendPing(timestampUs:token)
                adapt()
                // SCK may stop emitting when content is static. Reuse the retained
                // final frame for initial IDR and periodic resync.
                lock.lock(); let buffer=latest; let needs=requestIDR; lock.unlock()
                if let buffer, peerReady, needs { captured(buffer,MonotonicClock.microseconds) }
            }
            Thread.sleep(forTimeInterval:0.02)
        }
    }
    private func adapt() {
        lock.lock(); let stats=peer; let recentRTT=rtt; lock.unlock()
        var local=PeerStats(); local.rttUs=recentRTT; local.encodeUs=encoder.encodeDurationP50
        framer.sendStats(local)
        var target=currentBitrate
        let newDrops=stats.droppedFrames &- previousDrops
        previousDrops=stats.droppedFrames
        if newDrops>0 || stats.queueFrames>2 { target=Int(Double(currentBitrate)*0.8) }
        else if stats.targetBitrateBps>0 { target=Int(stats.targetBitrateBps) }
        // No automatic bitrate increase based solely on RTT: it isn't display latency.
        target=max(1_000_000,min(target,options.bitrateBps))
        if abs(target-currentBitrate)>=max(1,currentBitrate/20) {
            currentBitrate=target; encoder.updateBitrate(target)
            log("Bitrate: \(target/1_000_000) Mbps")
        }
    }
    public func requestStop() { lock.lock(); cancelled=true; running=false; lock.unlock() }
    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped=true; running=false; ready=false; latest=nil
        lock.unlock()
        transport.stop()
        capturer?.stop(); capturer=nil
        display?.stop(); display=nil
        encoder.stop()
        injector.releasePointer()
        log("Session stopped; USB and virtual display released")
    }
    private func log(_ s: String) { fputs("[usbdisplay] \(s)\n",stderr) }
}
extension DisplayLinkSession: FrameSourceDelegate {
    public func frameSource(_ source: FrameSource,didReceive frame: ReceivedFrame) {
        switch frame.header.type {
        case USBD.typeTouch:
            guard let touch=TouchEvent.decode(frame.payload), let id=displayID else { return }
            let bounds=CGDisplayBounds(id)
            injector.updateTarget(size:bounds.size,origin:bounds.origin)
            injector.handle(touch)
        case USBD.typeRequestKeyframe:
            lock.lock(); ready=true; requestIDR=true; lock.unlock()
        case USBD.typePong:
            guard frame.payload.count==8 else { return }
            let token=readU32(frame.payload,0)
            lock.lock()
            if token==pingToken { rtt=UInt32(clamping:MonotonicClock.microseconds-pingSent) }
            lock.unlock()
        case USBD.typeStats:
            lock.lock(); peer=PeerStats(payload:frame.payload); lock.unlock()
        case USBD.typePing:
            guard frame.payload.count==4 else { return }
            var payload=frame.payload
            var now=MonotonicClock.wireMicroseconds.littleEndian
            withUnsafeBytes(of:&now) { payload.append(contentsOf:$0) }
            framer.sendMessage(type:USBD.typePong,payload:payload)
        default: break
        }
    }
    public func frameSource(_ source: FrameSource,didFail error: Error) {
        lock.lock(); failure=error; running=false; lock.unlock()
        log("Disconnected: \(error.localizedDescription). Reconnect the cable and run again.")
    }
}
