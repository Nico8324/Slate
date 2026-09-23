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
    /// - Parameter session: Session used for requests; injectable for tests.
    /// - Parameter cacheTTL: Cache lifetime in seconds; defaults to one hour.
    ///   Zero disables retention. Finite values are clamped to 0…365 days;
    ///   non-finite values use the default. Expired entries refresh on demand.
    public init(apiKey: String, session: URLSession = .shared, cacheTTL: TimeInterval = 3600) {
        self.apiKey = apiKey
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 5),
                         cache: ResponseCache(ttl: cacheTTL), provider: .mdbList)
    }

    public func updateAPIKey(_ apiKey: String) {
        Log.mdbList.notice("api key rotated")
        self.apiKey = apiKey
    }

    /// Discard cached responses and cancel in-progress requests.
    public func clearCache() async { await http.cache?.removeAll() }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        try lookup.validate()
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw SlateError.missingCredential(.mdbList) }
        guard let route = Self.route(for: lookup) else {
            // MDBList resolves by id and has no title search, so it stays silent
            // on a lookup by name until another provider supplies one.
            Log.mdbList.debug("no id to resolve by yet — waiting for another provider to supply one")
            return nil
        }

        let payload = try await http.json(
            Media.self,
            url: try URL.build(Self.api, path: route),
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        )
        let ratings = payload.ratings?.compactMap(\.rating) ?? []
        guard !ratings.isEmpty || payload.imdb_id != nil else {
            Log.mdbList.notice("\(Log.describe(lookup.ids), privacy: .public) — answered, but with no ratings and no ids")
            return nil
        }
        Log.mdbList.debug("\(ratings.count, privacy: .public) ratings")

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

    /// One page of an official list, in MDBList's order.
    ///
    /// TMDB's own lists rank by its popularity score — page views, votes and
    /// searches on TMDB itself — which surfaces titles nobody around you has
    /// heard of and orders the rest oddly next to IMDb's or Trakt's charts.
    /// MDBList republishes the charts people recognise, for the same free key
    /// its ratings already need.
    ///
    /// Rows carry ids, a title, a year and a poster; fetch the details through
    /// ``MetadataAggregator`` or ``TMDBProvider``. A row with neither a TMDB nor
    /// an IMDb id is dropped: nothing could fetch its details.
    ///
    /// - Parameters:
    ///   - list: Which chart.
    ///   - kind: Films or shows — every official list holds both.
    ///   - limit: Rows per page, 1…1000.
    ///   - cursor: ``ListPage/nextCursor`` from the previous page; `nil` for the first.
    public func titles(
        in list: OfficialList, kind: Kind, limit: Int = 20, cursor: String? = nil
    ) async throws -> ListPage {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw SlateError.missingCredential(.mdbList) }
        let url = try URL.build(Self.api, path: "/lists/official/\(list.rawValue)/items", query: [
            "mediatype": kind == .movie ? "movie" : "show",
            "limit": String(min(max(limit, 1), 1000)),
            "append_to_response": "poster",
            "cursor": cursor,
        ])
        let payload = try await http.json(
            ListItems.self, url: url,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        )
        let rows = kind == .movie ? payload.movies : payload.shows
        let titles = (rows ?? []).sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
            .compactMap { $0.candidate(kind: kind) }
        Log.mdbList.debug("\(list.rawValue, privacy: .public) — \(titles.count, privacy: .public) \(kind.rawValue, privacy: .public) rows")
        return ListPage(titles: titles, nextCursor: payload.pagination?.next_cursor?.nilIfEmpty)
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

    struct ListItems: Decodable {
        var movies: [Item]?
        var shows: [Item]?
        var pagination: Pagination?

        struct Pagination: Decodable { var next_cursor: String? }

        struct Item: Decodable {
            var rank: Int?
            var title: String?
            var release_year: Int?
            var imdb_id: String?
            var ids: IDs?
            var poster: String?

            struct IDs: Decodable {
                var imdb: String?
                var tmdb: Int?
            }

            func candidate(kind: Kind) -> Candidate? {
                guard let title = title?.nilIfEmpty else { return nil }
                let ids = Identifiers(imdb: ids?.imdb ?? imdb_id, tmdb: ids?.tmdb).validated
                guard ids.tmdb != nil || ids.imdb != nil else { return nil }
                return Candidate(ids: ids, kind: kind, title: title, year: release_year,
                                 posterURL: poster.flatMap(URL.init(string:)), provider: .mdbList)
            }
        }
    }

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
            ///
            /// MDBList's own 0...100 `score` decides the value where it is given — it is the one
            /// number that is on a known scale for every source. The table covers what is left:
            /// Trakt, TMDB and Popcornmeter send percentages, Roger Ebert stars out of four, and
            /// Metacritic's user score is out of ten, not a hundred — a table that knew six
            /// sources read Trakt's 85 as eighty-five out of ten and Metacritic users' 8.9 as 0.89.
            var rating: Rating? {
                guard let source = source?.nilIfEmpty else { return nil }
                let outOf: Double = switch source {
                case "metacritic", "tomatoes", "tomatoesaudience", "audience", "popcorn", "trakt", "tmdb": 100
                case "letterboxd": 5
                case "rogerebert": 4
                default: 10
                }
                if let score, score > 0 {
                    return Rating(source: source, value: min(score, 100) / 10, outOf: outOf, votes: votes)
                }
                guard let native = value, native > 0 else { return nil }
                return Rating(source: source, value: min(native / outOf * 10, 10), outOf: outOf, votes: votes)
            }
        }
    }
}
