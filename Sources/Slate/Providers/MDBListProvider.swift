import Foundation

/// MDBList, for the scores no single database holds.
///
/// The reason the plan wanted several rating sites is that they measure
/// different things and disagree usefully — a film Letterboxd loves and the
/// tomatometer does not is a real signal, and an average of the two is not.
/// MDBList already cross-references them, so one credential buys IMDb,
/// Metacritic, both tomatometers, Letterboxd, Trakt and MyAnimeList together.
///
/// **Needs an id, not a name.** It resolves by IMDb, TMDB, TVDB, MAL or Trakt id
/// and has no title search, so on a name lookup it answers nothing until TMDB
/// has supplied an id — which ``MetadataAggregator/metadata(for:)`` handles by
/// asking again once the ids are known.
public actor MDBListProvider: MetadataProvider {
    public nonisolated let provider = Provider.mdbList

    private static let api = "https://api.mdblist.com"

    private var apiKey: String
    private let http: HTTP

    /// - Parameter apiKey: sourced by the caller and sent as a bearer token.
    ///   MDBList also accepts `?apikey=`; this deliberately does not use it.
    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 5))
    }

    public func updateAPIKey(_ apiKey: String) {
        self.apiKey = apiKey
    }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        guard !apiKey.isEmpty else { throw SlateError.missingCredential(.mdbList) }
        guard let route = Self.route(for: lookup) else { return nil }

        let payload = try await http.json(
            Media.self,
            url: try URL.build(Self.api, path: route),
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        )
        let ratings = payload.ratings?.compactMap(\.rating) ?? []
        guard !ratings.isEmpty || payload.imdb_id != nil else { return nil }

        return Snapshot(
            ids: Identifiers(imdb: payload.imdb_id?.nilIfEmpty),
            kind: payload.type.map { $0 == "movie" ? .movie : .series },
            title: payload.title?.nilIfEmpty,
            // Its own `score` is a blend of the sites below. The sites are the
            // useful part, so the blend is not reported as this provider's
            // rating — that would put an average where a source should be.
            ratings: ratings.isEmpty ? nil : ratings
        )
    }

    /// MDBList's id routes, in the order they are worth trying.
    static func route(for lookup: Lookup) -> String? {
        let type = switch lookup.kind {
        case .movie: "movie"
        case .series: "show"
        case nil: "any"
        }
        if let imdb = lookup.ids.imdb { return "/imdb/\(type)/\(imdb)/" }
        if let tmdb = lookup.ids.tmdb { return "/tmdb/\(type)/\(tmdb)/" }
        if let mal = lookup.ids.myAnimeList { return "/mal/\(type)/\(mal)/" }
        return nil
    }

    // MARK: - Payload

    struct Media: Decodable {
        var imdb_id: String?
        var title: String?
        var type: String?
        var ratings: [Entry]?

        struct Entry: Decodable {
            var source: String?
            /// The site's own number, on the site's own scale.
            var value: Double?
            /// MDBList's normalisation to 0...100, which is not always present.
            var score: Double?
            var votes: Int?

            /// Native scales differ and the source is the only clue which one
            /// applies: Metacritic is out of 100, Letterboxd out of 5, IMDb out
            /// of 10. Guessing from the magnitude would read a 4.5 IMDb score as
            /// a Letterboxd one.
            var rating: Rating? {
                guard let source = source?.nilIfEmpty else { return nil }
                let outOf: Double = switch source {
                case "metacritic", "metacriticuser", "tomatoes", "tomatoesaudience", "audience": 100
                case "letterboxd": 5
                default: 10
                }
                guard let native = value ?? score.map({ $0 / 100 * outOf }), native > 0 else { return nil }
                return Rating(source: source, value: native / outOf * 10, outOf: outOf, votes: votes)
            }
        }
    }
}
