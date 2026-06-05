import Foundation
import Network
import os

/// One-shot network reachability check used to decide whether a background sync may run
/// under the "Wi-Fi only" preference.
enum NetworkMonitor {
    /// Returns true if the current path is satisfied and NOT expensive (cellular / hotspot).
    /// Low Data Mode (isConstrained) is intentionally not treated as a blocker — it only
    /// signals a user preference for lower data use, not a metered connection, and refusing
    /// it entirely means the app never refreshes on those devices. The timeout fallback
    /// returns true so a momentary NWPathMonitor delay never silently skips a full run.
    static func isUnrestricted(timeout: TimeInterval = 5) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.alphara.dividends.netmonitor")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            @Sendable func finish(_ value: Bool) {
                let shouldResume = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                monitor.cancel()
                continuation.resume(returning: value)
            }

            monitor.pathUpdateHandler = { path in
                let ok = path.status == .satisfied && !path.isExpensive
                finish(ok)
            }
            monitor.start(queue: queue)

            // Safety net: if no path update arrives allow the sync rather than silently skip.
            queue.asyncAfter(deadline: .now() + timeout) { finish(true) }
        }
    }
}
