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

    /// The dividends endpoint is always throttled through the shared limiter so foreground
    /// and background never collectively exceed the free tier's 5 requests/minute.
    /// (Interactive ticker search is intentionally NOT throttled; it's debounced instead.)
    init(session: URLSession = .shared, rateLimiter: RateLimiter? = .polygonShared) {
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

        guard let url = components.url else { throw PolygonError.invalidResponse }
        let response: TickersResponse = try await get(url: url)
        return (response.results ?? []).map {
            TickerSearchResult(ticker: $0.ticker, name: $0.name ?? $0.ticker)
        }
    }

    func fetchUpcomingDividends(
        in range: ClosedRange<Date>,
        matching tickers: Set<String>
    ) async throws -> [DividendRecord] {
        guard !tickers.isEmpty else { return [] }
        let wanted = Set(tickers.map { $0.uppercased() })

        // One market-wide query bounded by ex-dividend date, sorted ascending, paginated.
        var components = URLComponents(url: baseURL.appendingPathComponent("/v3/reference/dividends"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ex_dividend_date.gte", value: DateUtil.apiString(range.lowerBound)),
            URLQueryItem(name: "ex_dividend_date.lte", value: DateUtil.apiString(range.upperBound)),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "sort", value: "ex_dividend_date"),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        guard var nextURL = components.url else { throw PolygonError.invalidResponse }

        var matched: [DividendRecord] = []
        var pages = 0
        let maxPages = 10 // hard safety cap (throttled, so each page costs ~13s)

        while pages < maxPages {
            try Task.checkCancellation()
            await rateLimiter?.waitForSlot()

            let response: DividendsResponse = try await get(url: nextURL)
            pages += 1

            for dto in response.results ?? [] {
                guard let ticker = dto.ticker?.uppercased(), wanted.contains(ticker) else { continue }
                guard let exDate = DateUtil.parse(dto.ex_dividend_date) else { continue }
                matched.append(DividendRecord(
                    id: dto.id ?? "\(ticker)-\(dto.ex_dividend_date ?? "")",
                    ticker: ticker,
                    exDate: exDate,
                    payDate: DateUtil.parse(dto.pay_date),
                    recordDate: DateUtil.parse(dto.record_date),
                    declarationDate: DateUtil.parse(dto.declaration_date),
                    cashAmount: dto.cash_amount ?? 0,
                    currency: dto.currency ?? "USD",
                    frequency: dto.frequency ?? 0
                ))
            }

            // Follow pagination if present (Polygon's next_url is pre-built but unauthenticated).
            guard let next = response.next_url, let url = URL(string: next) else { break }
            nextURL = url
        }

        return matched
    }

    // MARK: - Networking

    private func get<T: Decodable>(url: URL) async throws -> T {
        guard let apiKey = KeychainStore.apiKey, !apiKey.isEmpty else {
            throw PolygonError.missingAPIKey
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PolygonError.invalidResponse
        }
        // Append apiKey (next_url from pagination arrives without it).
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "apiKey" }
        items.append(URLQueryItem(name: "apiKey", value: apiKey))
        components.queryItems = items

        guard let requestURL = components.url else { throw PolygonError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20

        // Retry a transient 429 a couple of times (honoring Retry-After) before giving up,
        // so a brief overlap with another call doesn't fail the whole sync.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PolygonError.invalidResponse }

            switch http.statusCode {
            case 200...299:
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch { throw PolygonError.invalidResponse }
            case 401, 403:
                throw PolygonError.missingAPIKey
            case 429:
                guard attempt < maxAttempts else { throw PolygonError.rateLimited }
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 15
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            default:
                throw PolygonError.http(http.statusCode)
            }
        }
        throw PolygonError.rateLimited
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
    let next_url: String?
    struct DividendDTO: Decodable {
        let id: String?
        let ticker: String?
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
