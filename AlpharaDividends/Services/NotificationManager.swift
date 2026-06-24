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
        let (title, body) = paydayContent(for: events)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "payday-\(dayKey)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Pre-schedule a payday notification to fire at `fireDate` (8:30 am local on the pay
    /// date). Adding a request with the same identifier replaces any existing one, so
    /// calling this repeatedly with the same `dayKey` is idempotent.
    static func schedulePayday(events: [DividendEvent], dayKey: String, fireDate: Date) async {
        guard !events.isEmpty else { return }
        let (title, body) = paydayContent(for: events)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "payday-\(dayKey)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Cancel all pending `payday-*` requests (e.g. when the user disables the setting or
    /// when rescheduling from scratch to drop stale requests).
    static func removePendingPaydayNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix("payday-") }.map(\.identifier)
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Pure helper: build the title and body for a payday notification given the set of
    /// events that share a pay date. Used by both the immediate and pre-scheduled paths so
    /// they produce identical copy.
    static func paydayContent(for events: [DividendEvent]) -> (title: String, body: String) {
        let sorted = events.sorted { $0.ticker < $1.ticker }
        if let only = sorted.first, sorted.count == 1 {
            return (
                title: "Dividend payment today",
                body: "\(only.companyName) (\(only.ticker)) pays "
                    + "\(CurrencyFormat.string(only.cashAmount, currency: only.currency))/share today."
            )
        } else {
            return (
                title: "\(sorted.count) dividend payments today",
                body: sorted
                    .map { "\($0.ticker) \(CurrencyFormat.string($0.cashAmount, currency: $0.currency))" }
                    .joined(separator: ", ")
            )
        }
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
