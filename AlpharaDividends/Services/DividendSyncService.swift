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
        let companies = force ? allCompanies : allCompanies.filter { isStale($0, now: now) }
        guard !companies.isEmpty else { return [] }

        let today = Calendar.current.startOfDay(for: .now)
        var existingIDs = Set(try context.fetch(FetchDescriptor<DividendEvent>()).map(\.id))
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
                guard !existingIDs.contains(record.id) else { continue }
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
                    previousAmount: Self.previousComparableAmount(for: record, in: records)
                )
                context.insert(event)
                existingIDs.insert(record.id)
                newEvents.append(event)
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
        guard !toNotify.isEmpty else { return newEvents }

        await NotificationManager.notify(toNotify)
        for event in toNotify { event.notified = true }
        if context.hasChanges { try context.save() }
        return newEvents
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
