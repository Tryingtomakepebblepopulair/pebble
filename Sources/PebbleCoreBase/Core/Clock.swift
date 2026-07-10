// Portable monotonic clock (PORTING module 03). CFAbsoluteTimeGetCurrent is
// CoreFoundation-only AND a wall clock (it jumps when the OS adjusts time);
// budgets, profiling, and tick deltas want monotonic seconds instead.

import Foundation
import Dispatch

/// seconds from a monotonic clock — only differences are meaningful
public func monotonicNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
