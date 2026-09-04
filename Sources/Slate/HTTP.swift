import Foundation

/// The only errors Slate raises. A provider returning no match is not one of
/// them — that is `nil`, and it is the ordinary case for AniList on a western
/// title.
public enum SlateError: Error, Sendable, Equatable {
    /// The provider has no API key, or the one it has was rejected.
    case missingCredential(Provider)
    /// A non-2xx response, with the first 512 bytes of the body for context.
    case http(status: Int, body: String)
    case malformedURL
}

/// The smallest thing that can fetch and decode JSON. Providers own their
/// endpoints; this owns nothing but the round trip.
struct HTTP: Sendable {
    var session: URLSession = .shared

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

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SlateError.http(status: http.statusCode, body: String(decoding: data.prefix(512), as: UTF8.self))
        }
        return try decoder().decode(Response.self, from: data)
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
