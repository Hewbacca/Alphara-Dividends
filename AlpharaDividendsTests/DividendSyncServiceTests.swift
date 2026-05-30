import XCTest
import SwiftData
@testable import AlpharaDividends

@MainActor
final class DividendSyncServiceTests: XCTestCase {

    /// In-memory SwiftData container so tests never touch disk.
    /// IMPORTANT: callers must keep the returned container alive for the whole test —
    /// its `mainContext` becomes invalid the moment the container deallocates.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TrackedCompany.self, DividendEvent.self,
            configurations: config
        )
    }

    private func record(id: String, daysFromNow: Int) -> DividendRecord {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: .now)!
        return DividendRecord(
            id: id, ticker: "AAPL", exDate: date,
            payDate: nil, recordDate: nil, declarationDate: nil,
            cashAmount: 0.25, currency: "USD", frequency: 4
        )
    }

    private func record(id: String, exDays: Int, payDays: Int) -> DividendRecord {
        let cal = Calendar.current
        return DividendRecord(
            id: id, ticker: "AAPL",
            exDate: cal.date(byAdding: .day, value: exDays, to: .now)!,
            payDate: cal.date(byAdding: .day, value: payDays, to: .now)!,
            recordDate: nil, declarationDate: nil,
            cashAmount: 0.25, currency: "USD", frequency: 4
        )
    }

    func testOnlyFutureUnseenEventsAreInserted() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [
            record(id: "past", daysFromNow: -5),   // already ex-dividend -> ignored
            record(id: "future", daysFromNow: 10), // upcoming -> inserted
        ])
        let service = DividendSyncService(dataSource: mock)

        let new = try await service.sync(context: context)

        XCTAssertEqual(new.map(\.id), ["future"])
        let stored = try context.fetch(FetchDescriptor<DividendEvent>())
        XCTAssertEqual(stored.map(\.id), ["future"])
    }

    func testSecondSyncDoesNotReinsertOrRenotify() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [record(id: "future", daysFromNow: 10)])
        let service = DividendSyncService(dataSource: mock)

        _ = try await service.sync(context: context)
        let secondRun = try await service.sync(context: context)

        XCTAssertTrue(secondRun.isEmpty, "Known dividend ids must not be inserted twice")
        let stored = try context.fetch(FetchDescriptor<DividendEvent>())
        XCTAssertEqual(stored.count, 1)
    }

    func testWholeWatchlistCoveredInOneFetch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        // Many tracked companies...
        let tickers = (1...30).map { "T\($0)" }
        for t in tickers { context.insert(TrackedCompany(ticker: t, name: "Company \(t)")) }

        // ...each with an upcoming dividend in a single market-wide result set.
        let recs = tickers.map { t in
            DividendRecord(id: "\(t)-div", ticker: t,
                           exDate: Calendar.current.date(byAdding: .day, value: 20, to: .now)!,
                           payDate: nil, recordDate: nil, declarationDate: nil,
                           cashAmount: 0.1, currency: "USD", frequency: 4)
        }
        let mock = MockDataSource(records: recs)
        let service = DividendSyncService(dataSource: mock)

        let new = try await service.sync(context: context)

        XCTAssertEqual(new.count, 30, "Every tracked ticker should be checked, not just the first few")
        XCTAssertEqual(mock.fetchCallCount, 1, "Watchlist must be covered by a single market-wide call")
    }

    func testDividendBeyondLookaheadWindowIsIgnored() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [
            record(id: "soon", daysFromNow: 30),  // inside 60-day window
            record(id: "later", daysFromNow: 90), // outside window
        ])
        let service = DividendSyncService(dataSource: mock, lookaheadDays: 60)

        let new = try await service.sync(context: context)
        XCTAssertEqual(new.map(\.id), ["soon"])
    }

    func testPastExDateButPendingPaymentIsIncluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        // Already went ex-dividend 5 days ago, but pays in 10 days — still upcoming.
        let mock = MockDataSource(records: [record(id: "pending", exDays: -5, payDays: 10)])
        let service = DividendSyncService(dataSource: mock)

        let new = try await service.sync(context: context)
        XCTAssertEqual(new.map(\.id), ["pending"])
    }

    func testFullyPaidDividendIsExcluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        // Ex-dividend and payment both in the past — done, should not appear.
        let mock = MockDataSource(records: [record(id: "paid", exDays: -20, payDays: -2)])
        let service = DividendSyncService(dataSource: mock)

        let new = try await service.sync(context: context)
        XCTAssertTrue(new.isEmpty)
    }

    func testNewlyAnnouncedDividendIsDetected() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [record(id: "q1", daysFromNow: 10)])
        let service = DividendSyncService(dataSource: mock)
        _ = try await service.sync(context: context)

        // A new announcement appears in a later poll (within the look-ahead window).
        mock.records.append(record(id: "q2", daysFromNow: 45))
        let new = try await service.sync(context: context)

        XCTAssertEqual(new.map(\.id), ["q2"])
    }
}

private final class MockDataSource: DividendDataSource {
    var records: [DividendRecord]
    /// Records counts as the data source sees them, to assert call-count independence.
    private(set) var fetchCallCount = 0
    init(records: [DividendRecord]) { self.records = records }

    func searchTickers(query: String) async throws -> [TickerSearchResult] { [] }

    func fetchUpcomingDividends(
        in range: ClosedRange<Date>,
        matching tickers: Set<String>
    ) async throws -> [DividendRecord] {
        fetchCallCount += 1
        let wanted = Set(tickers.map { $0.uppercased() })
        // Emulate the real client: market-wide rows filtered to the watchlist and window.
        return records.filter { wanted.contains($0.ticker.uppercased()) && range.contains($0.exDate) }
    }
}
