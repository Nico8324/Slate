import Foundation
import os

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
    private var pausedUntil: ContinuousClock.Instant?

    /// Holds every caller until `instant` — a 429 is about the client, not the one request that
    /// happened to receive it, and the requests already queued would otherwise each run into the
    /// same wall and spend their attempts on it.
    func pause(until instant: ContinuousClock.Instant) {
        pausedUntil = max(pausedUntil ?? instant, instant)
    }

    init(requestsPerSecond: Double) {
        self.interval = .seconds(1 / max(requestsPerSecond, 0.01))
    }

    /// Returns when it is this caller's turn. Turns are handed out in order, so
    /// a burst is spread rather than dropped.
    func waitForTurn() async {
        let now = ContinuousClock.now
        let start = max(now, nextTurn ?? now, pausedUntil ?? now)
        nextTurn = start.advanced(by: interval)
        if start > now {
            try? await Task.sleep(until: start, clock: .continuous)
        }
    }
}

/// Remembers responses for the life of the process.
///
/// A show page opened twice is two identical requests, and a library scan asks
/// for the same franchise, the same season and the same id bridge repeatedly.
/// In memory only and never written to disk: staleness is then bounded by how
/// long the app runs, which needs no policy and cannot be wrong after a restart.
actor ResponseCache {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 256) { self.limit = limit }

    func data(for key: String) -> Data? { entries[key] }

    func store(_ data: Data, for key: String) {
        if entries.updateValue(data, forKey: key) == nil { order.append(key) }
        // Oldest out first. A metadata cache has no hot set worth tracking —
        // the request that matters is the one a person just made.
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

/// The smallest thing that can fetch and decode JSON, plus the two things every
/// caller would otherwise have to reinvent: pacing and retries.
struct HTTP: Sendable {
    var session: URLSession = .shared
    var limiter: RateLimiter?
    var cache: ResponseCache?
    /// Total tries, not retries. Three is enough for a transient 429 or a 502
    /// and short enough that a genuinely broken provider fails quickly.
    var attempts: Int = 3
    /// Who is being asked, so a rejected key can be reported as the credential problem it is
    /// rather than as a bare 401.
    var provider: Provider?

    func json<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if body != nil, headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Keyed by method, URL and body: AniList is a POST whose URL never
        // changes, so the URL alone would collapse every query into one entry.
        // The body verbatim, not its hash: a hash collision would hand back
        // another query's JSON, and nothing downstream could tell.
        let key = "\(method) \(url.absoluteString) \(body?.base64EncodedString() ?? "")"
        let endpoint = Log.redactingQuery(url)
        if let cached = await cache?.data(for: key) {
            Log.http.debug("cache hit \(method, privacy: .public) \(endpoint, privacy: .public)")
            return try JSONDecoder().decode(Response.self, from: cached)
        }

        var lastRetryAfter: TimeInterval?
        var lastStatus = 0
        var lastBody = Data()

        let started = ContinuousClock.now
        for attempt in 1...max(attempts, 1) {
            // Deliberately never the headers and never the query: one carries
            // the bearer token, the other carries what a person searched for.
            Log.http.debug(
                "\(method, privacy: .public) \(endpoint, privacy: .public) attempt \(attempt, privacy: .public)/\(max(self.attempts, 1), privacy: .public)"
            )
            await limiter?.waitForTurn()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Log.http.debug("\(endpoint, privacy: .public) — no HTTP response, decoding anyway")
                return try JSONDecoder().decode(Response.self, from: data)
            }

            if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                let retryAfter = Self.retryAfter(http)
                lastRetryAfter = retryAfter
                lastStatus = http.statusCode
                lastBody = data
                if http.statusCode == 429 {
                    await limiter?.pause(until: .now.advanced(by: .seconds(retryAfter ?? Self.backoff(attempt))))
                }
                guard attempt < attempts else {
                    Log.http.error(
                        "\(endpoint, privacy: .public) — HTTP \(http.statusCode, privacy: .public) on the last of \(max(self.attempts, 1), privacy: .public) attempts, giving up"
                    )
                    break
                }
                Log.http.notice(
                    "\(endpoint, privacy: .public) — HTTP \(http.statusCode, privacy: .public), retrying in \(retryAfter ?? Self.backoff(attempt), privacy: .public)s"
                )
                // The server's own number where it gave one — it knows when the
                // window resets and guessing shorter just burns the next attempt.
                // A 429 already paused the limiter until that instant, and
                // `waitForTurn()` on the next attempt honours it — sleeping here
                // too would serve the wait twice.
                if limiter == nil || http.statusCode != 429 {
                    try? await Task.sleep(for: .seconds(retryAfter ?? Self.backoff(attempt)))
                }
                continue
            }
            if [401, 403].contains(http.statusCode), let provider {
                Log.http.error("\(endpoint, privacy: .public) — HTTP \(http.statusCode, privacy: .public), the credential was refused")
                throw SlateError.missingCredential(provider)
            }
            guard (200..<300).contains(http.statusCode) else {
                Log.http.error(
                    "\(endpoint, privacy: .public) — HTTP \(http.statusCode, privacy: .public), \(data.count, privacy: .public) bytes"
                )
                throw SlateError.http(status: http.statusCode,
                                      body: String(decoding: data.prefix(512), as: UTF8.self))
            }
            let decoded: Response
            do {
                decoded = try JSONDecoder().decode(Response.self, from: data)
            } catch {
                // The failure a caller cannot diagnose from the outside: a 200
                // whose shape changed. Says which type failed to decode, never
                // the body — that is the provider's payload about a title.
                Log.http.error(
                    "\(endpoint, privacy: .public) — HTTP 200 but \(String(describing: Response.self), privacy: .public) did not decode: \(Log.describe(error), privacy: .public)"
                )
                throw error
            }
            Log.http.debug(
                "\(endpoint, privacy: .public) — \(http.statusCode, privacy: .public), \(data.count, privacy: .public) bytes in \(started.duration(to: .now).milliseconds, privacy: .public)ms"
            )
            // Stored only after decoding: a body that does not parse is not an
            // answer, and caching it would repeat the failure without the round
            // trip that might have fixed it.
            await cache?.store(data, for: key)
            return decoded
        }
        // Rate limited only if that is what the last answer was. A server failing with 5xx on
        // every attempt is "this is broken", which callers treat differently from "slow down".
        guard lastStatus == 429 else {
            Log.http.error("\(endpoint, privacy: .public) — HTTP \(lastStatus, privacy: .public) on every attempt")
            throw SlateError.http(status: lastStatus, body: String(decoding: lastBody.prefix(512), as: UTF8.self))
        }
        Log.http.error("\(endpoint, privacy: .public) — still rate limited after every attempt")
        throw SlateError.rateLimited(retryAfter: lastRetryAfter)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces) else { return nil }
        // Seconds, or an HTTP date — both are allowed, and the date form fell back to guessing.
        let seconds = TimeInterval(value) ?? httpDate.date(from: value).map { $0.timeIntervalSinceNow }
        guard let seconds else { return nil }
        // A server having a bad day can ask for minutes; waiting that long inside one lookup is
        // worse than reporting it. Sixty, not thirty: AniList's window is a minute, and a retry
        // sent before it resets only spends the attempt.
        return min(max(seconds, 0), 60)
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

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
        for formatter in Self.releaseDateFormatters {
            if let date = formatter.date(from: self) { return date }
        }
        return nil
    }

    /// One formatter per format, built once: constructing a `DateFormatter` is
    /// expensive and this runs for every date of every snapshot. Two of them
    /// rather than one whose `dateFormat` is reassigned — that mutation is what
    /// makes a shared formatter unsafe to hold.
    private static let releaseDateFormatters: [DateFormatter] = ["yyyy-MM-dd", "yyyy"].map { format in
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
