import Foundation
import Testing
@testable import Slate

struct HTTPTests {
    @Test func aPauseAlsoHoldsAnAlreadyWaitingRequest() async throws {
        let limiter = RateLimiter(requestsPerSecond: 10)
        try await limiter.waitForTurn()
        let pause = Task {
            try await Task.sleep(for: .milliseconds(20))
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
            await limiter.pause(until: deadline)
            return deadline
        }

        try await limiter.waitForTurn()
        let finished = ContinuousClock.now
        #expect(finished >= (try await pause.value))
    }

    @Test func cancellingAQueuedTurnThrows() async throws {
        let limiter = RateLimiter(requestsPerSecond: 1)
        try await limiter.waitForTurn()
        let waiting = Task { try await limiter.waitForTurn() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func aCancelledRequestDoesNotReturnCachedData() async throws {
        let cache = ResponseCache()
        let url = URL(string: "https://example.com/test")!
        await cache.store(Data("{}".utf8), for: "GET \(url.absoluteString) ")
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HTTP(cache: cache).json([String: String].self, url: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await request.value }
    }

    @Test(arguments: ["NaN", "inf", "-inf"])
    func nonFiniteRetryDelaysAreIgnored(_ value: String) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": value]
        )!
        #expect(HTTP.retryAfter(response) == nil)
    }
}
