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

    static func body(for event: DividendEvent) -> String {
        let amount = CurrencyFormat.string(event.cashAmount, currency: event.currency)
        var parts = ["\(event.ticker) \(amount)/share"]
        parts.append("ex-div \(DateFormat.medium(event.exDate))")
        if let pay = event.payDate {
            parts.append("pays \(DateFormat.medium(pay))")
        }
        return parts.joined(separator: " · ")
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
    static func medium(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}
