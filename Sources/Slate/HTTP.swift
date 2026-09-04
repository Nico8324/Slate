import Foundation

public enum SlateError: Error, Sendable, Equatable {
    /// The provider has no API key, or the one it has was rejected.
    case missingCredential(Provider)
    /// A non-2xx response, with the first 512 bytes of the body for context.
    case http(status: Int, body: String)
    /// Still rate limited after every retry. Distinct from ``http`` so a caller
    /// can tell "slow down" from "this will never work".
    case rateLimited(retryAfter: TimeInterval?)
    case malformedURL
}

/// Paces requests so a library scan does not get itself throttled.
///
/// AniList allows about ninety requests a minute and answers 429 after that.
/// Organising a few hundred titles is well over a thousand requests — three for
/// a corrected show, a fourth for its artwork — so without pacing the failures
/// arrive in a wall that looks like the provider is broken.
actor RateLimiter {
    private let interval: Duration
    private var nextTurn: ContinuousClock.Instant?

    init(requestsPerSecond: Double) {
        self.interval = .seconds(1 / max(requestsPerSecond, 0.01))
    }

    /// Returns when it is this caller's turn. Turns are handed out in order, so
    /// a burst is spread rather than dropped.
    func waitForTurn() async {
        let now = ContinuousClock.now
        let start = max(now, nextTurn ?? now)
        nextTurn = start.advanced(by: interval)
        if start > now {
            try? await Task.sleep(until: start, clock: .continuous)
        }
    }
}

/// The smallest thing that can fetch and decode JSON, plus the two things every
/// caller would otherwise have to reinvent: pacing and retries.
struct HTTP: Sendable {
    var session: URLSession = .shared
    var limiter: RateLimiter?
    /// Total tries, not retries. Three is enough for a transient 429 or a 502
    /// and short enough that a genuinely broken provider fails quickly.
    var attempts: Int = 3

    func json<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        decoder: @Sendable () -> JSONDecoder = { JSONDecoder() }
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if body != nil, headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var lastRetryAfter: TimeInterval?

        for attempt in 1...max(attempts, 1) {
            await limiter?.waitForTurn()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return try decoder().decode(Response.self, from: data)
            }

            if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                let retryAfter = Self.retryAfter(http)
                lastRetryAfter = retryAfter
                guard attempt < attempts else { break }
                // The server's own number where it gave one — it knows when the
                // window resets and guessing shorter just burns the next attempt.
                try? await Task.sleep(for: .seconds(retryAfter ?? Self.backoff(attempt)))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SlateError.http(status: http.statusCode,
                                      body: String(decoding: data.prefix(512), as: UTF8.self))
            }
            return try decoder().decode(Response.self, from: data)
        }
        throw SlateError.rateLimited(retryAfter: lastRetryAfter)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces))
        else { return nil }
        // A server having a bad day can ask for minutes; waiting that long inside
        // one lookup is worse than reporting it and letting the caller decide.
        return min(seconds, 30)
    }

    static func backoff(_ attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt - 1)), 8)
    }
}

extension URL {
    static func build(_ base: String, path: String, query: [String: String?] = [:]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw SlateError.malformedURL }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        guard let url = components.url else { throw SlateError.malformedURL }
        return url
    }
}

extension String {
    /// `"2019-04-06"` and `"2019"` both appear in provider payloads.
    var asReleaseDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: self) { return date }
        }
        return nil
    }
}
