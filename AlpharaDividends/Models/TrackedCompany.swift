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

    init(ticker: String, name: String, dateAdded: Date = .now) {
        self.ticker = ticker.uppercased()
        self.name = name
        self.dateAdded = dateAdded
    }
}
