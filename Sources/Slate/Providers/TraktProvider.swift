import Foundation

/// Trakt's lists: what people are watching, ranked by watching.
///
/// TMDB's own lists rank by its popularity score — page views, votes, searches
/// on TMDB itself — which surfaces titles nobody around you has heard of and
/// orders the rest oddly next to IMDb's or Trakt's charts. Trakt counts people
/// actually watching, so its trending and popular lists read like what a person
/// expects on a home screen.
///
/// Lists only, never metadata. Every row carries IMDb and TMDB ids and nothing
/// to show; fetch the details — and the poster — through ``MetadataAggregator``
/// or ``TMDBProvider``. Scrobbling stays out, as before: a record of what
/// someone watched belongs to the app that watched it.
///
/// The client id is injected and rotatable, sent as a header, never stored and
/// never logged — the same rules as TMDB's token.
public actor TraktProvider {
    public nonisolated let provider = Provider.trakt

    static let api = "https://api.trakt.tv"

    private(set) var clientID: String
    let http: HTTP

    /// Hold one instance for the life of the app to share pacing and cached responses.
    ///
    /// - Parameters:
    ///   - clientID: A Trakt API app's client id, supplied by the caller and sent as a header.
    ///   - session: Session used for requests; injectable for tests.
    ///   - cacheTTL: Response lifetime in seconds; defaults to 15 minutes, since
    ///     trending moves through the day. Zero disables retention.
    public init(clientID: String, session: URLSession = .shared, cacheTTL: TimeInterval = 900) {
        self.clientID = clientID
        // Trakt allows 1,000 GETs every five minutes; three a second stays under it.
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 3),
                         cache: ResponseCache(ttl: cacheTTL), provider: .trakt)
    }

    /// Rotate the client id in place. Slate never persists it.
    public func updateClientID(_ clientID: String) {
        Log.trakt.notice("client id rotated")
        self.clientID = clientID
    }

    /// Discard cached lists; the next call fetches fresh ones.
    public func clearCache() async {
        await http.cache?.removeAll()
    }

    /// One of Trakt's lists, in Trakt's order.
    ///
    /// Rows carry ids, a title and a year — no poster, because Trakt holds none.
    /// A row with neither a TMDB nor an IMDb id is dropped: nothing could fetch
    /// its details.
    public func titles(in list: TraktList, page: Int = 1, limit: Int = 20) async throws -> [Candidate] {
        guard page >= 1 else { return [] }
        try Task.checkCancellation()
        guard !clientID.isEmpty else { throw SlateError.missingCredential(.trakt) }
        let url = try URL.build(Self.api, path: list.path, query: [
            "page": String(page), "limit": String(min(max(limit, 1), 100)),
        ])
        let rows = try await http.json([Row].self, url: url, headers: [
            "trakt-api-key": clientID, "trakt-api-version": "2", "Content-Type": "application/json",
        ])
        let candidates = rows.compactMap { $0.item.candidate(kind: list.kind) }
        Log.trakt.debug("\(list.path, privacy: .public) page \(page, privacy: .public) — \(candidates.count, privacy: .public) titles")
        return candidates
    }

    // MARK: - Payloads

    /// Trakt wraps some lists' rows (`{"watchers": 12, "movie": {…}}`) and not
    /// others (`popular` returns the items bare). Either decodes.
    struct Row: Decodable {
        let item: Item

        struct Item: Decodable {
            var title: String?
            var year: Int?
            var ids: IDs?

            struct IDs: Decodable {
                var imdb: String?
                var tmdb: Int?
            }

            func candidate(kind: Kind) -> Candidate? {
                guard let title = title?.nilIfEmpty else { return nil }
                let ids = Identifiers(imdb: ids?.imdb, tmdb: ids?.tmdb).validated
                guard ids.tmdb != nil || ids.imdb != nil else { return nil }
                return Candidate(ids: ids, kind: kind, title: title, year: year, provider: .trakt)
            }
        }

        private enum Wrapper: String, CodingKey { case movie, show }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Wrapper.self)
            if let movie = try container.decodeIfPresent(Item.self, forKey: .movie) {
                item = movie
            } else if let show = try container.decodeIfPresent(Item.self, forKey: .show) {
                item = show
            } else {
                item = try Item(from: decoder)
            }
        }
    }
}

/// A list Trakt publishes. Ranked by viewing — see ``TraktProvider``.
public enum TraktList: Sendable, Hashable {
    /// Being watched right now.
    case trendingMovies, trendingShows
    /// Most watched and best rated, over all time.
    case popularMovies, popularShows
    /// Most added to people's lists, not yet out.
    case anticipatedMovies, anticipatedShows
    /// The US weekend box office.
    case boxOffice
    /// Most watched in a period.
    case mostWatchedMovies(TraktPeriod), mostWatchedShows(TraktPeriod)

    var path: String {
        switch self {
        case .trendingMovies: "/movies/trending"
        case .trendingShows: "/shows/trending"
        case .popularMovies: "/movies/popular"
        case .popularShows: "/shows/popular"
        case .anticipatedMovies: "/movies/anticipated"
        case .anticipatedShows: "/shows/anticipated"
        case .boxOffice: "/movies/boxoffice"
        case .mostWatchedMovies(let period): "/movies/watched/\(period.rawValue)"
        case .mostWatchedShows(let period): "/shows/watched/\(period.rawValue)"
        }
    }

    var kind: Kind {
        switch self {
        case .trendingMovies, .popularMovies, .anticipatedMovies, .boxOffice, .mostWatchedMovies: .movie
        case .trendingShows, .popularShows, .anticipatedShows, .mostWatchedShows: .series
        }
    }
}

public enum TraktPeriod: String, Sendable, Hashable, CaseIterable {
    case daily, weekly, monthly, yearly, all
}
