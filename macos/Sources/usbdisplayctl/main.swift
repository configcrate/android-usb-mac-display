import Foundation
import CoreGraphics
import USBDisplayCore
import Darwin
import ApplicationServices

func usage() {
    print("""
    usbdisplayctl — experimental Mac → Android USB display
    doctor | probe | run [--width N --height N --fps N --bitrate N --backend capture|virtual]
    Defaults: 1280×720, 30 fps, 8 Mbps, main-screen mirror.
    virtual: experimental extended desktop using private API. No silent fallback.
    Requires macOS 13+, libusb, data cable, Android 8+ APK and USB permission.
    Ctrl-C releases the session. No USB debugging required.
    """)
}
var options=DisplayLinkSession.Options()
let arguments=Array(CommandLine.arguments.dropFirst())
let command=arguments.first ?? "doctor"
var i=1
func number(_ value: String) -> Int {
    guard let n=Int(value) else { fputs("Invalid numeric argument: \(value)\n",stderr); exit(2) }
    return n
}
while i<arguments.count {
    let key=arguments[i]
    if key=="--help" || key=="-h" { usage(); exit(0) }
    guard i+1<arguments.count else { fputs("Missing argument for \(key)\n",stderr); exit(2) }
    let value=arguments[i+1]
    switch key {
    case "--width": options.width=number(value)
    case "--height": options.height=number(value)
    case "--fps": options.fps=number(value)
    case "--bitrate": options.bitrateBps=number(value)
    case "--backend":
        switch value {
        case "capture","sck": options.backend = .captureOnly
        case "virtual": options.backend = .cgVirtualDisplay
        default: fputs("Unknown backend\n",stderr); exit(2)
        }
    default: fputs("Unknown option: \(key)\n",stderr); exit(2)
    }
    i += 2
}
guard (320...3840).contains(options.width), (240...2160).contains(options.height),
    options.width%2==0, options.height%2==0, (1...60).contains(options.fps),
    (1_000_000...40_000_000).contains(options.bitrateBps) else {
    fputs("Use even dimensions 320–3840 × 240–2160, fps 1–60, bitrate 1000000–40000000.\n",stderr); exit(2)
}
switch command {
case "doctor","probe":
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Virtual API available: \(CGVirtualDisplayBackend.isAvailable) (not a hardware test)")
    print("Screen Recording allowed: \(CGPreflightScreenCaptureAccess())")
    print("Accessibility allowed: \(AXIsProcessTrusted())")
    if let d=AOATransport.findAndroidDevice() { print("USB candidate \(d.manufacturer):\(d.product)") }
    else { print("No unique Android candidate. Connect exactly one phone using a data cable.") }
case "run":
    guard CGPreflightScreenCaptureAccess() else {
        CGRequestScreenCaptureAccess()
        fputs("Allow Screen Recording for your terminal in macOS Settings, then restart the terminal and rerun.\n",stderr)
        exit(1)
    }
    let session=DisplayLinkSession(options:options)
    signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN)
    let interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.main)
    let terminate=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
    interrupt.setEventHandler { session.requestStop() }
    terminate.setEventHandler { session.requestStop() }
    interrupt.resume(); terminate.resume()
    DispatchQueue.global(qos:.userInteractive).async {
        var status: Int32=0
        do { try session.start(); session.run(); if session.failure != nil { status=1 } }
        catch { fputs("Start failed: \(error.localizedDescription)\n",stderr); status=1 }
        session.stop()
        exit(status)
    }
    // Required by WindowServer / SCK / native virtual-display callbacks.
    RunLoop.main.run()
case "--help","-h": usage()
default: usage(); exit(2)
}
