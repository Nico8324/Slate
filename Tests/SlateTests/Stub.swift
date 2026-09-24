import Foundation
import Synchronization

/// Answers requests from a table of canned responses, so the provider request
/// and decoding paths can be tested without a credential or a network.
///
/// One per test: pass ``transport`` to a provider and nothing is shared with
/// the tests running beside it.
final class Stub: Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = "{}"
        var headers: [String: String] = [:]
    }

    /// Matched by substring against the absolute URL, longest pattern first, so
    /// `/tv/1/season/2/images` can be distinguished from `/tv/1/images`.
    private let routes = Mutex<[(String, Reply)]>([])
    private let seen = Mutex<[URLRequest]>([])
    private let responder = Mutex<(@Sendable (URLRequest) async -> Reply)?>(nil)

    func respond(using handler: @escaping @Sendable (URLRequest) async -> Reply) {
        responder.withLock { $0 = handler }
    }

    func stub(_ pattern: String, _ reply: Reply) {
        routes.withLock { $0.append((pattern, reply)) }
    }

    func stub(_ pattern: String, json: String) {
        stub(pattern, Reply(body: json))
    }

    func reset() {
        routes.withLock { $0.removeAll() }
        seen.withLock { $0.removeAll() }
        responder.withLock { $0 = nil }
    }

    /// Every URL requested, for asserting that a provider asked what it should.
    var requested: [URL] { seen.withLock { $0.compactMap(\.url) } }
    /// Every request, headers included.
    var requests: [URLRequest] { seen.withLock { $0 } }

    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { [self] request in
            try Task.checkCancellation()
            let url = request.url!
            seen.withLock { $0.append(request) }
            let text = url.absoluteString
            let match = routes.withLock { routes in
                routes.filter { text.contains($0.0) }.max { $0.0.count < $1.0.count }?.1
            }
            let handler = responder.withLock { $0 }
            let reply = await handler?(request)
                ?? match ?? Reply(status: 404, body: #"{"status_message":"no stub"}"#)
            try Task.checkCancellation()
            let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            return (Data(reply.body.utf8), response)
        }
    }
}
