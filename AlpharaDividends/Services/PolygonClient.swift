import Foundation

enum PolygonError: LocalizedError {
    case missingAPIKey
    case rateLimited
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Polygon API key set. Add one in Settings."
        case .rateLimited:
            return "Polygon rate limit reached (free tier is 5 requests/minute). Try again shortly."
        case .http(let code):
            return "Polygon request failed (HTTP \(code))."
        case .invalidResponse:
            return "Received an unexpected response from Polygon."
        }
    }
}

/// Polygon.io REST client. Reads the API key from the Keychain on each call so a
/// freshly-entered key takes effect immediately.
struct PolygonClient: DividendDataSource {
    private let session: URLSession
    private let rateLimiter: RateLimiter?
    private let baseURL = URL(string: "https://api.polygon.io")!

    /// `rateLimiter` is applied to the dividends endpoint only (used by background sync).
    init(session: URLSession = .shared, rateLimiter: RateLimiter? = nil) {
        self.session = session
        self.rateLimiter = rateLimiter
    }

    // MARK: - DividendDataSource

    func searchTickers(query: String) async throws -> [TickerSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("/v3/reference/tickers"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "market", value: "stocks"),
            URLQueryItem(name: "active", value: "true"),
            URLQueryItem(name: "limit", value: "20"),
        ]

        let response: TickersResponse = try await get(components)
        return (response.results ?? []).map {
            TickerSearchResult(ticker: $0.ticker, name: $0.name ?? $0.ticker)
        }
    }

    func fetchUpcomingDividends(ticker: String, from: Date) async throws -> [DividendRecord] {
        await rateLimiter?.waitForSlot()

        var components = URLComponents(url: baseURL.appendingPathComponent("/v3/reference/dividends"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ticker", value: ticker.uppercased()),
            URLQueryItem(name: "ex_dividend_date.gte", value: DateUtil.apiString(from)),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "sort", value: "ex_dividend_date"),
            URLQueryItem(name: "limit", value: "50"),
        ]

        let response: DividendsResponse = try await get(components)
        return (response.results ?? []).compactMap { dto in
            guard let exDate = DateUtil.parse(dto.ex_dividend_date) else { return nil }
            return DividendRecord(
                id: dto.id ?? "\(ticker.uppercased())-\(dto.ex_dividend_date ?? "")",
                ticker: ticker.uppercased(),
                exDate: exDate,
                payDate: DateUtil.parse(dto.pay_date),
                recordDate: DateUtil.parse(dto.record_date),
                declarationDate: DateUtil.parse(dto.declaration_date),
                cashAmount: dto.cash_amount ?? 0,
                currency: dto.currency ?? "USD",
                frequency: dto.frequency ?? 0
            )
        }
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let apiKey = KeychainStore.apiKey, !apiKey.isEmpty else {
            throw PolygonError.missingAPIKey
        }
        var components = components
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "apiKey", value: apiKey)]

        guard let url = components.url else { throw PolygonError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PolygonError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw PolygonError.invalidResponse
            }
        case 401, 403:
            throw PolygonError.missingAPIKey
        case 429:
            throw PolygonError.rateLimited
        default:
            throw PolygonError.http(http.statusCode)
        }
    }
}

// MARK: - Wire types

private struct TickersResponse: Decodable {
    let results: [TickerDTO]?
    struct TickerDTO: Decodable {
        let ticker: String
        let name: String?
    }
}

private struct DividendsResponse: Decodable {
    let results: [DividendDTO]?
    struct DividendDTO: Decodable {
        let id: String?
        let cash_amount: Double?
        let currency: String?
        let declaration_date: String?
        let ex_dividend_date: String?
        let pay_date: String?
        let record_date: String?
        let frequency: Int?
    }
}

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

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string)
    }

    static func apiString(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
