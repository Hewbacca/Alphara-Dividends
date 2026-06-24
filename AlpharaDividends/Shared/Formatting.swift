import Foundation

enum CurrencyFormat {
    static func string(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}

enum DateFormat {
    /// Dividend dates are floating calendar dates parsed at UTC midnight, so they must be
    /// formatted in UTC too — otherwise a date renders as the previous day in time zones
    /// behind UTC (e.g. the US).
    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()

    static func medium(_ date: Date) -> String {
        display.string(from: date)
    }
}
