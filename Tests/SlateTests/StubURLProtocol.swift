import Foundation
import Synchronization

/// Answers requests from a table of canned responses, so the provider request
/// and decoding paths can be tested without a credential or a network.
///
/// These paths were previously unreachable in tests: everything TMDB does needs
/// a key, so search, find, details, episode groups and artwork had only ever run
/// by hand. That is how "Dragon Ball" resolved to Dragon Ball Z for as long as it
/// did.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = "{}"
        var headers: [String: String] = [:]
    }

    /// Matched by substring against the absolute URL, longest pattern first, so
    /// `/tv/1/season/2/images` can be distinguished from `/tv/1/images`.
    private static let routes = Mutex<[(String, Reply)]>([])
    private static let seen = Mutex<[URL]>([])
    private static let responder = Mutex<(@Sendable (URLRequest) async -> Reply)?>(nil)

    static func respond(using handler: @escaping @Sendable (URLRequest) async -> Reply) {
        responder.withLock { $0 = handler }
    }

    static func stub(_ pattern: String, _ reply: Reply) {
        routes.withLock { $0.append((pattern, reply)) }
    }

    static func stub(_ pattern: String, json: String) {
        stub(pattern, Reply(body: json))
    }

    static func reset() {
        routes.withLock { $0.removeAll() }
        seen.withLock { $0.removeAll() }
        responder.withLock { $0 = nil }
    }

    /// Every URL requested, for asserting that a provider asked what it should.
    static var requested: [URL] { seen.withLock { $0 } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let pending = Mutex<Task<Void, Never>?>(nil)
    override func stopLoading() { pending.withLock { $0?.cancel() } }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.seen.withLock { $0.append(url) }

        let text = url.absoluteString
        let match = Self.routes.withLock { routes in
            routes.filter { text.contains($0.0) }.max { $0.0.count < $1.0.count }?.1
        }
        let handler = Self.responder.withLock { $0 }
        let request = self.request
        let task = Task { @Sendable [self, request] in
            let reply = await handler?(request)
                ?? match ?? Reply(status: 404, body: #"{"status_message":"no stub"}"#)

            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        pending.withLock { $0 = task }
    }
}
