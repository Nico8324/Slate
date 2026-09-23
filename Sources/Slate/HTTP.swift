import Foundation
import os

public enum SlateError: Error, Sendable, Equatable {
    /// The provider has no API key, or the one it has was rejected.
    case missingCredential(Provider)
    /// A non-2xx response, with the first 512 bytes of the body for context.
    case http(status: Int, body: String)
    /// Still rate limited after every retry. Distinct from ``SlateError/http(status:body:)`` so a caller
    /// can tell "slow down" from "this will never work".
    case rateLimited(retryAfter: TimeInterval?)
    /// Invalid mutable identifiers, a year outside 1…9999, or a negative season.
    case invalidLookup
    /// A provider returned an identifier that contradicts an explicit lookup ID.
    case conflictingMatch(Provider)
    /// A GraphQL error or missing response data, including failures sent with HTTP 200.
    case graphQL(Provider)
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
    func waitForTurn() async throws {
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            let start = max(now, nextTurn ?? now, pausedUntil ?? now)
            nextTurn = start.advanced(by: interval)
            if start > now {
                try await Task.sleep(until: start, clock: .continuous)
            }
            // A 429 may have arrived while this turn was sleeping. Requeue
            // behind the pause, keeping the resumed requests spaced apart.
            if let pausedUntil, pausedUntil > start { continue }
            return
        }
    }
}

/// Bounded, expiring responses and one shared fetch per request key.
actor ResponseCache {
    private var entries: [String: (data: Data, expires: ContinuousClock.Instant)] = [:]
    private var order: [String] = []
    private let limit: Int
    /// A ceiling in bytes as well as entries: a long anime's credits run to
    /// megabytes, and 256 of those is not a cache anyone budgeted for.
    private let byteLimit: Int
    private var bytes = 0
    let lifetime: Duration
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Data, any Error>]
    }
    private var flights: [String: Flight] = [:]
    var waiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }

    init(limit: Int = 256, ttl: TimeInterval = 3600, byteLimit: Int = 32 * 1024 * 1024) {
        self.limit = max(0, limit)
        self.byteLimit = max(0, byteLimit)
        lifetime = .seconds(ttl.isFinite ? min(max(0, ttl), 31_536_000) : 3600)
    }

    func data(for key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        guard entry.expires > .now else {
            bytes -= entry.data.count
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        // Least recently used goes first, not least recently fetched: a title opened again and
        // again stays while the rest of a busy hour passes through.
        if order.last != key, let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry.data
    }

    func store(_ data: Data, for key: String) {
        // "Zero disables retention" — storing an entry already expired still
        // held the body in memory until something evicted it.
        guard lifetime > .zero, data.count <= byteLimit else { return }
        if let previous = entries.updateValue((data, .now.advanced(by: lifetime)), forKey: key) {
            bytes -= previous.data.count
        } else {
            order.append(key)
        }
        bytes += data.count
        while order.count > limit || bytes > byteLimit, !order.isEmpty {
            if let evicted = entries.removeValue(forKey: order.removeFirst()) { bytes -= evicted.data.count }
        }
    }

    func data(for key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        if let cached = data(for: key) { return cached }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var flight = flights[key] {
                    flight.waiters[waiter] = continuation
                    flights[key] = flight
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<Data, any Error>
                        do { result = .success(try await load()) }
                        catch { result = .failure(error) }
                        finish(key, id: id, result: result)
                    }
                    flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
    }

    private func finish(_ key: String, id: UUID, result: Result<Data, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        if case .success(let data) = result { store(data, for: key) }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights[key] = nil
        } else {
            flights[key] = flight
        }
    }

    /// Invalidated requests cannot repopulate the cache, even if transport ignores cancellation.
    func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
        let pending = flights.values
        flights.removeAll()
        for flight in pending {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
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

    func json<Response: Decodable & SendableMetatype>(
        _ type: Response.Type,
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if body != nil, headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Headers distinguish credentials and representations. Keys stay in memory and are never logged.
        let headerKey = headers.sorted { $0.key < $1.key }.map { [$0.key.lowercased(), $0.value] }
        let encodedHeaders = try JSONEncoder().encode(headerKey).base64EncodedString()
        let key = "\(method) \(url.absoluteString) \(body?.base64EncodedString() ?? "") \(encodedHeaders)"
        let prepared = request
        let data: Data
        if let cache {
            data = try await cache.data(for: key) { try await fetch(type, request: prepared) }
        } else {
            data = try await fetch(type, request: prepared)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(type, from: data)
    }

    private func fetch<Response: Decodable & SendableMetatype>(_ type: Response.Type, request: URLRequest) async throws -> Data {
        let endpoint = Log.redactingQuery(request.url!)
        let method = request.httpMethod ?? "GET"
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
            try await limiter?.waitForTurn()
            try Task.checkCancellation()
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where Self.isTransient(error) && attempt < attempts {
                // A dropped connection is the network's hiccup, not the provider's
                // answer; only 429 and 5xx were being retried.
                Log.http.notice(
                    "\(endpoint, privacy: .public) — \(error.code.rawValue, privacy: .public), retrying in \(Self.backoff(attempt), privacy: .public)s"
                )
                try await Task.sleep(for: .seconds(Self.backoff(attempt)))
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                Log.http.debug("\(endpoint, privacy: .public) — no HTTP response, decoding anyway")
                _ = try JSONDecoder().decode(Response.self, from: data)
                return data
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
                    try await Task.sleep(for: .seconds(retryAfter ?? Self.backoff(attempt)))
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
            do {
                _ = try JSONDecoder().decode(Response.self, from: data)
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
            return data
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
        guard let seconds, seconds.isFinite else { return nil }
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

    static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
            .contains(error.code)
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
        for formatter in Self.releaseDateFormatters {
            if let date = formatter.date(from: self), formatter.string(from: date) == self { return date }
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
