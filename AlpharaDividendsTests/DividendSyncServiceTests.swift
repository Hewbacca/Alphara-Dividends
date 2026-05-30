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

    func testNewlyAnnouncedDividendIsDetected() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TrackedCompany(ticker: "AAPL", name: "Apple Inc."))

        let mock = MockDataSource(records: [record(id: "q1", daysFromNow: 10)])
        let service = DividendSyncService(dataSource: mock)
        _ = try await service.sync(context: context)

        // A new announcement appears in a later poll.
        mock.records.append(record(id: "q2", daysFromNow: 100))
        let new = try await service.sync(context: context)

        XCTAssertEqual(new.map(\.id), ["q2"])
    }
}

private final class MockDataSource: DividendDataSource {
    var records: [DividendRecord]
    init(records: [DividendRecord]) { self.records = records }

    func searchTickers(query: String) async throws -> [TickerSearchResult] { [] }

    func fetchUpcomingDividends(ticker: String, from: Date) async throws -> [DividendRecord] {
        records
    }
}
