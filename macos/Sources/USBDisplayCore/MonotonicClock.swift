import Foundation
enum MonotonicClock {
    static var microseconds: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }
    static var wireMicroseconds: UInt32 { UInt32(truncatingIfNeeded: microseconds) }
}
