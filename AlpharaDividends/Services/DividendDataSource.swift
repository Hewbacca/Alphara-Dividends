import Foundation

/// A ticker search hit: a symbol and its company name.
struct TickerSearchResult: Identifiable, Hashable {
    let ticker: String
    let name: String
    var id: String { ticker }
}

/// A raw dividend record from the data source (value type, decoupled from SwiftData).
struct DividendRecord: Hashable {
    let id: String
    let ticker: String
    let exDate: Date
    let payDate: Date?
    let recordDate: Date?
    let declarationDate: Date?
    let cashAmount: Double
    let currency: String
    let frequency: Int
}

/// Abstraction over the market-data provider. Implemented by `PolygonClient`.
///
/// Keeping this as a protocol lets us (a) unit-test the sync logic with a mock and
/// (b) swap in a different provider — or a future server-backed source — without
/// touching the rest of the app.
protocol DividendDataSource {
    /// Search for tickers by symbol or company name (ticker → company name matching).
    func searchTickers(query: String) async throws -> [TickerSearchResult]

    /// Fetch dividends for a ticker with an ex-dividend date on or after `from`.
    func fetchUpcomingDividends(ticker: String, from: Date) async throws -> [DividendRecord]
}
