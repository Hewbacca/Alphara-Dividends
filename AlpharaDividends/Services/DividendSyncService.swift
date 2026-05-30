import Foundation
import SwiftData

/// Core sync engine, shared by foreground refresh and the background task.
///
/// Runs on the main actor and uses the container's main `ModelContext`, which keeps
/// SwiftData access single-threaded and simple for a v1 app.
@MainActor
struct DividendSyncService {
    let dataSource: DividendDataSource

    /// How far ahead to look for upcoming dividends. Announcements rarely land earlier
    /// than ~6 weeks before the ex-date, so a 60-day window keeps the market-wide payload
    /// small (typically 1-3 pages) while still catching everything that's been declared.
    let lookaheadDays: Int

    init(dataSource: DividendDataSource, lookaheadDays: Int = 60) {
        self.dataSource = dataSource
        self.lookaheadDays = lookaheadDays
    }

    /// Fetch upcoming dividends for the whole watchlist in a single market-wide query and
    /// insert any not seen before.
    /// - Returns: the newly-inserted events (each with `notified == false`).
    @discardableResult
    func sync(context: ModelContext) async throws -> [DividendEvent] {
        let companies = try context.fetch(FetchDescriptor<TrackedCompany>())
        guard !companies.isEmpty else { return [] }

        let today = Calendar.current.startOfDay(for: .now)
        let through = Calendar.current.date(byAdding: .day, value: lookaheadDays, to: today) ?? today

        // Ticker → company name (use the user's saved name for notifications/UI).
        let nameByTicker = Dictionary(
            companies.map { ($0.ticker.uppercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let tickers = Set(nameByTicker.keys)

        let records = try await dataSource.fetchUpcomingDividends(in: today...through, matching: tickers)

        let existing = try context.fetch(FetchDescriptor<DividendEvent>())
        var existingIDs = Set(existing.map(\.id))
        var newEvents: [DividendEvent] = []

        for record in records where record.exDate >= today {
            guard !existingIDs.contains(record.id) else { continue }
            let event = DividendEvent(
                id: record.id,
                ticker: record.ticker,
                companyName: nameByTicker[record.ticker.uppercased()] ?? record.ticker,
                exDate: record.exDate,
                payDate: record.payDate,
                recordDate: record.recordDate,
                declarationDate: record.declarationDate,
                cashAmount: record.cashAmount,
                currency: record.currency,
                frequency: record.frequency
            )
            context.insert(event)
            existingIDs.insert(record.id)
            newEvents.append(event)
        }

        if context.hasChanges { try context.save() }
        return newEvents
    }

    /// Sync, then fire a local notification for each new event and mark it notified.
    @discardableResult
    func syncAndNotify(context: ModelContext) async throws -> [DividendEvent] {
        let newEvents = try await sync(context: context)
        let toNotify = newEvents.filter { !$0.notified }
        guard !toNotify.isEmpty else { return newEvents }

        await NotificationManager.notify(toNotify)
        for event in toNotify { event.notified = true }
        if context.hasChanges { try context.save() }
        return newEvents
    }
}
