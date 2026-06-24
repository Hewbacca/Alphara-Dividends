import Foundation

/// Polygon emits `YYYY-MM-DD` calendar dates. Parse/format them in UTC so a date
/// never drifts a day across time zones.
enum DateUtil {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// UTC calendar so "today" aligns with the UTC-midnight dividend dates.
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Start of the current day in UTC — the threshold for "still upcoming".
    static func startOfTodayUTC() -> Date {
        utcCalendar.startOfDay(for: .now)
    }

    /// Whether two instants fall on the same UTC calendar day.
    static func isSameUTCDay(_ a: Date, _ b: Date) -> Bool {
        utcCalendar.isDate(a, inSameDayAs: b)
    }

    /// Whether `date` is the current UTC calendar day.
    static func isTodayUTC(_ date: Date) -> Bool {
        isSameUTCDay(date, .now)
    }

    /// Whether the canonical YYYY-MM-DD of a UTC-stored dividend date matches today's
    /// date in the user's **local** timezone.
    ///
    /// Dividend dates like "2026-06-01" are stored as UTC-midnight instants. Comparing
    /// them in UTC means the "today" window closes at UTC midnight, which is 6pm MT —
    /// far too early. Instead we extract the year/month/day that Polygon originally sent
    /// (UTC components) and compare against the user's local calendar date, so the row
    /// stays highlighted until midnight in the user's own timezone.
    static func isLocalToday(_ date: Date) -> Bool {
        let utcParts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        let localParts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return utcParts.year == localParts.year &&
               utcParts.month == localParts.month &&
               utcParts.day == localParts.day
    }

    /// Local-date string (YYYY-MM-DD) for today in the user's timezone, used as the
    /// payday notification identifier so it aligns with the local calendar day.
    static func localTodayString() -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// The UTC-midnight instant whose YYYY-MM-DD in UTC equals today's local calendar date.
    /// Use this to create test pay dates that `isLocalToday` recognises as "today" regardless
    /// of the difference between local and UTC dates.
    static func startOfLocalTodayAsUTC() -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        var utcParts = DateComponents()
        utcParts.year = parts.year; utcParts.month = parts.month; utcParts.day = parts.day
        return utcCalendar.date(from: utcParts) ?? startOfTodayUTC()
    }

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string)
    }

    static func apiString(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
