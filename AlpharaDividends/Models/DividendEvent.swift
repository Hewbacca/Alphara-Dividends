import Foundation
import SwiftData

/// A single dividend distribution discovered for a tracked company.
@Model
final class DividendEvent {
    /// Polygon's stable dividend id. Unique — used to dedupe across syncs.
    @Attribute(.unique) var id: String
    var ticker: String
    var companyName: String
    var exDate: Date
    var payDate: Date?
    var recordDate: Date?
    var declarationDate: Date?
    var cashAmount: Double
    var currency: String
    /// Polygon dividend frequency (0/1/2/4/12 = one-time/annual/semi/quarterly/monthly).
    var frequency: Int
    /// Amount of the previous comparable (same-cadence) dividend, for change detection.
    /// nil ⇒ no baseline ⇒ "New".
    var previousAmount: Double?
    /// True once a local notification has been fired for this event.
    var notified: Bool
    var discoveredAt: Date

    init(
        id: String,
        ticker: String,
        companyName: String,
        exDate: Date,
        payDate: Date? = nil,
        recordDate: Date? = nil,
        declarationDate: Date? = nil,
        cashAmount: Double,
        currency: String = "USD",
        frequency: Int = 0,
        previousAmount: Double? = nil,
        notified: Bool = false,
        discoveredAt: Date = .now
    ) {
        self.id = id
        self.ticker = ticker.uppercased()
        self.companyName = companyName
        self.exDate = exDate
        self.payDate = payDate
        self.recordDate = recordDate
        self.declarationDate = declarationDate
        self.cashAmount = cashAmount
        self.currency = currency
        self.frequency = frequency
        self.previousAmount = previousAmount
        self.notified = notified
        self.discoveredAt = discoveredAt
    }

    /// How this dividend compares to the previous comparable payment.
    var change: DividendChange {
        guard let prev = previousAmount else { return .new }
        let delta = cashAmount - prev
        if abs(delta) < 0.0001 { return .unchanged }
        return delta > 0 ? .increased : .decreased
    }
}

/// Direction of a dividend versus the company's previous comparable payment.
/// Foundation-only (no SwiftUI) so the model layer stays UI-agnostic — views map this
/// to colors/symbols, notifications map it to words.
enum DividendChange: Equatable {
    case new        // no comparable prior payment
    case unchanged
    case increased
    case decreased

    /// Word used in notification text.
    var word: String {
        switch self {
        case .new: return "new"
        case .unchanged: return "unchanged"
        case .increased: return "increased"
        case .decreased: return "cut"
        }
    }
}
