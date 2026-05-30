import Foundation
import SwiftData

/// Core sync engine, shared by foreground refresh and the background task.
///
/// Runs on the main actor and uses the container's main `ModelContext`, which keeps
/// SwiftData access single-threaded and simple for a v1 app.
@MainActor
struct DividendSyncService {
    let dataSource: DividendDataSource

    init(dataSource: DividendDataSource) {
        self.dataSource = dataSource
    }

    /// Fetch dividends for every tracked company and insert any not seen before.
    /// - Returns: the newly-inserted events (each with `notified == false`).
    @discardableResult
    func sync(context: ModelContext) async throws -> [DividendEvent] {
        let companies = try context.fetch(FetchDescriptor<TrackedCompany>())
        guard !companies.isEmpty else { return [] }

        let today = Calendar.current.startOfDay(for: .now)
        let existing = try context.fetch(FetchDescriptor<DividendEvent>())
        var existingIDs = Set(existing.map(\.id))

        var newEvents: [DividendEvent] = []

        for company in companies {
            if Task.isCancelled { break }

            let records: [DividendRecord]
            do {
                records = try await dataSource.fetchUpcomingDividends(ticker: company.ticker, from: today)
            } catch let error as PolygonError {
                // A missing key or rate limit affects every ticker — surface it.
                switch error {
                case .missingAPIKey, .rateLimited:
                    throw error
                default:
                    continue // transient: skip this ticker, keep going
                }
            } catch is CancellationError {
                break
            } catch {
                continue
            }

            for record in records where record.exDate >= today {
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
                    frequency: record.frequency
                )
                context.insert(event)
                existingIDs.insert(record.id)
                newEvents.append(event)
            }
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
