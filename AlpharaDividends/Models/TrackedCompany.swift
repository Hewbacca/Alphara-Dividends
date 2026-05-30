import Foundation
import SwiftData

/// A ticker symbol the user is tracking, resolved to a company name.
@Model
final class TrackedCompany {
    /// Uppercased ticker symbol, e.g. "AAPL". Unique across the store.
    @Attribute(.unique) var ticker: String
    /// Human-readable company name, e.g. "Apple Inc.".
    var name: String
    var dateAdded: Date
    /// When this ticker's dividends were last fetched. nil ⇒ never checked ⇒ stale.
    var lastCheckedAt: Date?

    init(ticker: String, name: String, dateAdded: Date = .now, lastCheckedAt: Date? = nil) {
        self.ticker = ticker.uppercased()
        self.name = name
        self.dateAdded = dateAdded
        self.lastCheckedAt = lastCheckedAt
    }
}
