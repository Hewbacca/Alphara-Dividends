import Foundation
import SwiftData

/// Core sync engine, shared by foreground refresh and the background task.
///
/// Runs on the main actor and uses the container's main `ModelContext`, which keeps
/// SwiftData access single-threaded and simple for a v1 app.
///
/// Strategy: one small, complete request **per ticker** (reliable, immune to market-wide
/// truncation), paced by the shared rate limiter inside `PolygonClient`. A normal sync only
/// re-checks **stale** tickers so it finishes quickly; `force: true` re-checks all.
@MainActor
struct DividendSyncService {
    let dataSource: DividendDataSource

    /// A ticker checked more recently than this is skipped on a non-forced sync.
    let staleAfter: TimeInterval

    init(dataSource: DividendDataSource, staleAfter: TimeInterval = 6 * 60 * 60) {
        self.dataSource = dataSource
        self.staleAfter = staleAfter
    }

    /// Fetch dividends for each (stale, unless `force`) tracked company and insert any not
    /// seen before. Saves incrementally per ticker so the UI fills in live and partial
    /// progress survives interruption.
    /// - Returns: the newly-inserted events (each with `notified == false`).
    @discardableResult
    func sync(
        context: ModelContext,
        force: Bool = false,
        onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [DividendEvent] {
        let allCompanies = try context.fetch(FetchDescriptor<TrackedCompany>())
        let now = Date()
        let candidates = force ? allCompanies : allCompanies.filter { isStale($0, now: now) }
        // Most-stale-first: nil (never checked) sorts before any date. This ensures background
        // runs with a short budget advance through the longest-waiting tickers each time rather
        // than repeatedly hitting the front of the list while the tail starves.
        let companies = candidates.sorted {
            switch ($0.lastCheckedAt, $1.lastCheckedAt) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (a?, b?): return a < b
            }
        }
        guard !companies.isEmpty else { return [] }

        let today = DateUtil.startOfTodayUTC()
        var existingByID = Dictionary(
            try context.fetch(FetchDescriptor<DividendEvent>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var newEvents: [DividendEvent] = []
        let total = companies.count

        for (index, company) in companies.enumerated() {
            try Task.checkCancellation() // honor the background-task budget

            let records: [DividendRecord]
            do {
                records = try await dataSource.fetchDividends(ticker: company.ticker)
            } catch let error as PolygonError where error.isFatalForAllTickers {
                throw error // missing key affects every ticker — surface it
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue // transient: skip this ticker, leave it stale for a retry
            }

            // Keep a dividend while it is not yet paid (payment today/future), or — if no
            // payment date is published — while its ex-date is still upcoming.
            for record in records where (record.payDate ?? record.exDate) >= today {
                let prev = Self.previousComparableAmount(for: record, in: records)

                if let existing = existingByID[record.id] {
                    // Refresh data fields (so the change indicator reclassifies and any
                    // provider corrections propagate) but preserve notification state.
                    existing.previousAmount = prev
                    existing.cashAmount = record.cashAmount
                    existing.exDate = record.exDate
                    existing.payDate = record.payDate
                    existing.recordDate = record.recordDate
                    existing.declarationDate = record.declarationDate
                    existing.frequency = record.frequency
                    existing.currency = record.currency
                } else {
                    let event = DividendEvent(
                        id: record.id,
                        ticker: record.ticker,
                        companyName: company.name,
                        exDate: record.exDate,
                        payDate: record.payDate,
                        recordDate: record.recordDate,
                        declarationDate: record.declarationDate,
                        cashAmount: record.cashAmount,
                        currency: record.currency,
                        frequency: record.frequency,
                        previousAmount: prev
                    )
                    context.insert(event)
                    existingByID[record.id] = event
                    newEvents.append(event)
                }
            }

            company.lastCheckedAt = now
            if context.hasChanges { try context.save() } // incremental: list updates live
            onProgress?(index + 1, total)
        }

        return newEvents
    }

    /// Sync, then fire a local notification for each new event and mark it notified.
    @discardableResult
    func syncAndNotify(
        context: ModelContext,
        force: Bool = false,
        onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [DividendEvent] {
        let newEvents = try await sync(context: context, force: force, onProgress: onProgress)
        let toNotify = newEvents.filter { !$0.notified }
        if !toNotify.isEmpty {
            await NotificationManager.notify(toNotify)
            for event in toNotify { event.notified = true }
            if context.hasChanges { try context.save() }
        }

        // Separately: anything paying today gets a shared "paid today" notification.
        await Self.notifyPaydays(context: context)
        return newEvents
    }

    /// Dividends paying **today** (UTC). Returns the full same-day set plus the subset that
    /// still needs a payday notification (not yet notified today). Pure → unit-testable.
    /// `today` here is `.now` — passed explicitly so tests can control it.
    /// Uses local-timezone day comparison so the payday window aligns with the user's
    /// calendar day rather than UTC midnight.
    static func paydayEvents(
        in events: [DividendEvent], today: Date
    ) -> (payingToday: [DividendEvent], needingNotification: [DividendEvent]) {
        let payingToday = events.filter { event in
            guard let pay = event.payDate else { return false }
            return DateUtil.isLocalToday(pay)
        }
        let needingNotification = payingToday.filter { event in
            guard let last = event.lastPaydayNotifiedOn else { return true }
            // The stamp is a live Date.now instant — compare using the local calendar
            // so "notified today" means "notified during today in the user's timezone".
            return !Calendar.current.isDateInToday(last)
        }
        return (payingToday, needingNotification)
    }

    /// Scan stored events and, if any pay today (local time) and haven't been payday-notified
    /// yet today, fire one shared notification and stamp them. Network-free.
    static func notifyPaydays(context: ModelContext) async {
        let now = Date.now
        guard let events = try? context.fetch(FetchDescriptor<DividendEvent>()) else { return }
        let (payingToday, needing) = paydayEvents(in: events, today: now)
        guard !needing.isEmpty else { return }

        await NotificationManager.notifyPayday(payingToday, dayKey: DateUtil.localTodayString())
        for event in payingToday { event.lastPaydayNotifiedOn = now }
        try? context.save()
    }

    private func isStale(_ company: TrackedCompany, now: Date) -> Bool {
        guard let last = company.lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= staleAfter
    }

    /// Amount of the most recent *comparable* prior dividend: same cadence (`frequency`) and
    /// currency, with an earlier ex-date. Returns nil for one-time specials (`frequency == 0`)
    /// and when no like-for-like predecessor exists in the fetched batch — both render as "New".
    static func previousComparableAmount(for r: DividendRecord, in records: [DividendRecord]) -> Double? {
        guard r.frequency != 0 else { return nil }
        return records
            .filter { $0.exDate < r.exDate && $0.frequency == r.frequency && $0.currency == r.currency }
            .max { $0.exDate < $1.exDate }?
            .cashAmount
    }
}

private extension PolygonError {
    /// Errors that mean every ticker would fail, so we should stop rather than loop.
    var isFatalForAllTickers: Bool {
        switch self {
        case .missingAPIKey, .rateLimited: return true
        case .http, .invalidResponse: return false
        }
    }
}
