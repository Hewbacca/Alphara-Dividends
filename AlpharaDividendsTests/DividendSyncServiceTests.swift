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

    private func record(id: String, ticker: String = "AAPL", daysFromNow: Int) -> DividendRecord {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: .now)!
        return DividendRecord(
            id: id, ticker: ticker, exDate: date,
            payDate: nil, recordDate: nil, declarationDate: nil,
            cashAmount: 0.25, currency: "USD", frequency: 4
        )
    }

    private func record(id: String, ticker: String = "AAPL", exDays: Int, payDays: Int) -> DividendRecord {
        let cal = Calendar.current
        return DividendRecord(
            id: id, ticker: ticker,
            exDate: cal.date(byAdding: .day, value: exDays, to: .now)!,
            payDate: cal.date(byAdding: .day, value: payDays, to: .now)!,
            recordDate: nil, declarationDate: nil,
            cashAmount: 0.25, currency: "USD", frequency: 4
        )
    }

    // Always-stale service so single/repeat syncs re-check every ticker.
    private func service(_ mock: MockDataSource) -> DividendSyncService {
        DividendSyncService(dataSource: mock, staleAfter: 0)
    }

    func testOnlyFutureUnseenEventsAreInserted() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [
            record(id: "past", daysFromNow: -5),   // already ex-dividend, no pay date -> ignored
            record(id: "future", daysFromNow: 10), // upcoming -> inserted
        ])

        let new = try await service(mock).sync(context: context)

        XCTAssertEqual(new.map(\.id), ["future"])
        let stored = try context.fetch(FetchDescriptor<DividendEvent>())
        XCTAssertEqual(stored.map(\.id), ["future"])
    }

    func testSecondSyncDoesNotReinsertOrRenotify() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [record(id: "future", daysFromNow: 10)])
        let svc = service(mock)

        _ = try await svc.sync(context: context)
        let secondRun = try await svc.sync(context: context)

        XCTAssertTrue(secondRun.isEmpty, "Known dividend ids must not be inserted twice")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DividendEvent>()).count, 1)
    }

    func testEveryTickerIsQueried() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let tickers = (1...30).map { "T\($0)" }
        for t in tickers { context.insert(TrackedCompany(ticker: t, name: "Company \(t)")) }

        let recs = tickers.map { record(id: "\($0)-div", ticker: $0, daysFromNow: 20) }
        let mock = MockDataSource(records: recs)

        let new = try await service(mock).sync(context: context)

        XCTAssertEqual(new.count, 30, "Every tracked ticker must be checked")
        XCTAssertEqual(Set(mock.queriedTickers), Set(tickers), "Each ticker queried exactly once")
        XCTAssertEqual(mock.queriedTickers.count, 30)
    }

    /// Regression for the V / TGT bug: ex-dividend already passed, but payment is still
    /// upcoming, so it must appear.
    func testPastExDateWithFuturePaymentIsShown() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "V", name: "Visa Inc."))

        // Mirrors Visa: ex-date 18 days ago, pays in 2 days.
        let mock = MockDataSource(records: [record(id: "v-jun", ticker: "V", exDays: -18, payDays: 2)])

        let new = try await service(mock).sync(context: context)
        XCTAssertEqual(new.map(\.id), ["v-jun"])
    }

    func testFullyPaidDividendIsExcluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        // Ex-dividend and payment both in the past — done, should not appear.
        let mock = MockDataSource(records: [record(id: "paid", exDays: -20, payDays: -2)])

        let new = try await service(mock).sync(context: context)
        XCTAssertTrue(new.isEmpty)
    }

    func testNewlyAnnouncedDividendIsDetected() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [record(id: "q1", daysFromNow: 10)])
        let svc = service(mock)
        _ = try await svc.sync(context: context)

        // A new announcement appears in a later poll.
        mock.records.append(record(id: "q2", daysFromNow: 30))
        let new = try await svc.sync(context: context)

        XCTAssertEqual(new.map(\.id), ["q2"])
    }

    func testFreshTickersAreSkippedUnlessForced() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        // Checked just now -> fresh.
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc.", lastCheckedAt: .now))

        let mock = MockDataSource(records: [record(id: "future", daysFromNow: 10)])
        // 6-hour staleness window (the default).
        let svc = DividendSyncService(dataSource: mock)

        let skipped = try await svc.sync(context: context, force: false)
        XCTAssertTrue(skipped.isEmpty, "A recently-checked ticker should be skipped")
        XCTAssertEqual(mock.queriedTickers.count, 0)

        let forced = try await svc.sync(context: context, force: true)
        XCTAssertEqual(forced.map(\.id), ["future"], "force should re-check even fresh tickers")
        XCTAssertEqual(mock.queriedTickers, ["AAPL"])
    }

    // MARK: - Dividend change vs. previous payment

    private func record(
        id: String, ticker: String = "AAPL",
        exDays: Int, payDays: Int, amount: Double, frequency: Int = 4
    ) -> DividendRecord {
        let cal = Calendar.current
        return DividendRecord(
            id: id, ticker: ticker,
            exDate: cal.date(byAdding: .day, value: exDays, to: .now)!,
            payDate: cal.date(byAdding: .day, value: payDays, to: .now)!,
            recordDate: nil, declarationDate: nil,
            cashAmount: amount, currency: "USD", frequency: frequency
        )
    }

    /// Containers must outlive the events they vend (their context references the container).
    private var retainedContainers: [ModelContainer] = []

    /// Insert one upcoming dividend whose batch also contains the given priors; return it.
    private func syncUpcoming(
        upcoming: DividendRecord, priors: [DividendRecord]
    ) async throws -> DividendEvent {
        let container = try makeContainer()
        retainedContainers.append(container) // keep alive for the duration of the test
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: upcoming.ticker, name: "Test"))
        let mock = MockDataSource(records: [upcoming] + priors)
        let new = try await service(mock).sync(context: context)
        return try XCTUnwrap(new.first)
    }

    func testChangeIncreased() async throws {
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.26),
            priors: [record(id: "p", exDays: -85, payDays: -80, amount: 0.25)]
        )
        XCTAssertEqual(event.previousAmount, 0.25)
        XCTAssertEqual(event.change, .increased)
    }

    func testChangeDecreased() async throws {
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.20),
            priors: [record(id: "p", exDays: -85, payDays: -80, amount: 0.25)]
        )
        XCTAssertEqual(event.change, .decreased)
    }

    func testChangeUnchanged() async throws {
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.25),
            priors: [record(id: "p", exDays: -85, payDays: -80, amount: 0.25)]
        )
        XCTAssertEqual(event.change, .unchanged)
    }

    func testNoPriorIsNew() async throws {
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.25),
            priors: []
        )
        XCTAssertNil(event.previousAmount)
        XCTAssertEqual(event.change, .new)
    }

    func testSpecialDividendIgnoredInComparison() async throws {
        // Upcoming regular 0.26; an interleaved one-time special (freq 0, $1.00) should be
        // ignored, so it compares to the previous regular 0.25 ⇒ increased.
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.26, frequency: 4),
            priors: [
                record(id: "special", exDays: -30, payDays: -25, amount: 1.00, frequency: 0),
                record(id: "reg", exDays: -85, payDays: -80, amount: 0.25, frequency: 4),
            ]
        )
        XCTAssertEqual(event.previousAmount, 0.25)
        XCTAssertEqual(event.change, .increased)
    }

    func testNotificationBodyIncludesChange() async throws {
        let event = try await syncUpcoming(
            upcoming: record(id: "up", exDays: 5, payDays: 10, amount: 0.26),
            priors: [record(id: "p", exDays: -85, payDays: -80, amount: 0.25)]
        )
        let body = NotificationManager.body(for: event)
        XCTAssertTrue(body.contains("increased"), body)
        XCTAssertTrue(body.contains("from"), body)
    }
}

private final class MockDataSource: DividendDataSource {
    var records: [DividendRecord]
    private(set) var queriedTickers: [String] = []
    init(records: [DividendRecord]) { self.records = records }

    func searchTickers(query: String) async throws -> [TickerSearchResult] { [] }

    func fetchDividends(ticker: String) async throws -> [DividendRecord] {
        queriedTickers.append(ticker.uppercased())
        return records.filter { $0.ticker.uppercased() == ticker.uppercased() }
    }
}
