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
        self.notified = notified
        self.discoveredAt = discoveredAt
    }
}
