import Foundation

/// Serializes calls so they are spaced at least `minInterval` apart.
///
/// Polygon's free tier allows 5 requests/minute, so the default 12.5s spacing keeps
/// the background sync loop under that ceiling. Interactive ticker search does NOT go
/// through this limiter (it is debounced in the UI instead).
actor RateLimiter {
    private let minInterval: TimeInterval
    private var lastCall: Date?

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    /// Process-wide limiter shared by every Polygon dividends request (foreground AND
    /// background) so the combined call rate stays under the free tier's 5/minute.
    /// 13s spacing ≈ 4.6 req/min, leaving a little headroom for the occasional search call.
    static let polygonShared = RateLimiter(minInterval: 13)

    /// Suspends until enough time has passed since the previous slot.
    func waitForSlot() async {
        if let last = lastCall {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                let delay = minInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lastCall = Date()
    }
}
