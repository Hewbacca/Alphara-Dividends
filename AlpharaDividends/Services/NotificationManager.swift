import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter` for authorization and firing local notifications
/// about newly-discovered dividends.
enum NotificationManager {
    /// Ask for permission. Safe to call repeatedly; iOS only prompts once.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Fire one local notification per event (delivered immediately).
    static func notify(_ events: [DividendEvent]) async {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "New dividend: \(event.companyName)"
            content.body = body(for: event)
            content.sound = .default

            // Use the dividend id as the request id so the same event never
            // produces two notifications.
            let request = UNNotificationRequest(
                identifier: "dividend-\(event.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Fire ONE notification covering all dividends paying on the same day. A stable
    /// per-day identifier means at most one payday banner exists per day (a later add with
    /// the same id replaces it), so multiple same-day payments share one notification.
    static func notifyPayday(_ events: [DividendEvent], dayKey: String) async {
        guard !events.isEmpty else { return }
        let sorted = events.sorted { $0.ticker < $1.ticker }

        let content = UNMutableNotificationContent()
        if let only = sorted.first, sorted.count == 1 {
            content.title = "Dividend payment today"
            content.body = "\(only.companyName) (\(only.ticker)) pays "
                + "\(CurrencyFormat.string(only.cashAmount, currency: only.currency))/share today."
        } else {
            content.title = "\(sorted.count) dividend payments today"
            content.body = sorted
                .map { "\($0.ticker) \(CurrencyFormat.string($0.cashAmount, currency: $0.currency))" }
                .joined(separator: ", ")
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "payday-\(dayKey)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func body(for event: DividendEvent) -> String {
        let amount = CurrencyFormat.string(event.cashAmount, currency: event.currency)
        var parts = ["\(event.ticker) \(amount)/share (\(changeClause(for: event)))"]
        parts.append("ex-div \(DateFormat.medium(event.exDate))")
        if let pay = event.payDate {
            parts.append("pays \(DateFormat.medium(pay))")
        }
        return parts.joined(separator: " · ")
    }

    /// e.g. "increased from $0.25", "cut from $0.25", "unchanged", "new".
    static func changeClause(for event: DividendEvent) -> String {
        switch event.change {
        case .new, .unchanged:
            return event.change.word
        case .increased, .decreased:
            let prev = event.previousAmount.map { CurrencyFormat.string($0, currency: event.currency) }
            return prev.map { "\(event.change.word) from \($0)" } ?? event.change.word
        }
    }
}

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
