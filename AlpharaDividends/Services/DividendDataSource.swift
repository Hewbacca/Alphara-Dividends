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

    /// Fetch the most recent dividends for a single ticker (newest first).
    ///
    /// One small, complete request per ticker. This is immune to the truncation problems of
    /// a market-wide scan (Polygon's universe is huge and clustered, and its dividends
    /// endpoint has no multi-ticker filter), so every watchlist ticker reliably gets its
    /// data. The caller decides which records are still "upcoming".
    func fetchDividends(ticker: String) async throws -> [DividendRecord]
}
