import Foundation

/// TMDB, for everything that is not anime — and for the IMDb id, which is the
/// only identifier an acquisition layer can rely on.
///
/// The key is injected and rotatable; it is never written to disk, never logged
/// and never put in a query string. Slate is a public repo and holds no keys.
public actor TMDBProvider: MetadataProvider {
    public nonisolated let provider = Provider.tmdb

    static let api = "https://api.themoviedb.org/3"
    static let images = "https://image.tmdb.org/t/p"

    private(set) var accessToken: String
    let http: HTTP

    /// Orderings are large and change rarely, and a show page can be opened
    /// repeatedly. Held for the life of the provider rather than re-fetched. A
    /// `nil` result is cached too, on purpose: "this show needs no correction" is
    /// exactly the answer that would otherwise be re-asked over the network every
    /// single time.
    var seasonCache: [Int: SeasonStructure?] = [:]

    /// The language metadata comes back in, as TMDB spells it: `fr-FR`, `ja-JP`.
    /// Artwork is deliberately unaffected — every language is fetched and
    /// ``ArtworkSet/best(_:preferring:)`` chooses.
    let language: String

    /// - Parameters:
    ///   - accessToken: a TMDB v4 read access token, sent as a bearer token.
    ///     Sourced by the caller — Slate does not know where it came from.
    ///   - language: an IETF tag TMDB understands. Titles and overviews come
    ///     back in it where the community has supplied them.
    /// The country whose age rating is wanted, ISO 3166-1: `US`, `FR`, `JP`.
    /// Ratings are per-country and not translations of each other — `TV-MA` has
    /// no French equivalent, France says `16`.
    let region: String

    public init(
        accessToken: String, language: String = "en-US", region: String = "US",
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.language = language
        self.region = region
        // TMDB is generous, but a library scan is thousands of requests and
        // there is no reason to be the loudest client on the server.
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 20))
    }

    /// Rotate the token in place. Slate never persists it.
    public func updateAPIKey(_ accessToken: String) {
        self.accessToken = accessToken
    }

    var headers: [String: String] {
        ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
    }

    /// Resolves by TMDB id, then by IMDb id, then by search — the first of
    /// those the lookup can supply.
    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        if let id = lookup.ids.tmdb, let kind = lookup.kind {
            return try await details(id: id, kind: kind)
        }
        if let imdb = lookup.ids.imdb, let hit = try await find(imdb: imdb) {
            return try await details(id: hit.id, kind: hit.kind)
        }
        if let query = lookup.query, let hit = try await search(query, year: lookup.year, kind: lookup.kind) {
            return try await details(id: hit.id, kind: hit.kind)
        }
        return nil
    }

    // MARK: - Endpoints

    private func find(imdb: String) async throws -> (id: Int, kind: Kind)? {
        let url = try URL.build(Self.api, path: "/find/\(imdb)",
                                query: ["external_source": "imdb_id", "language": language])
        let response = try await http.json(FindResponse.self, url: url, headers: headers)
        if let movie = response.movie_results.first { return (movie.id, .movie) }
        if let show = response.tv_results.first { return (show.id, .series) }
        return nil
    }

    private func search(_ query: String, year: Int?, kind: Kind?) async throws -> (id: Int, kind: Kind)? {
        switch kind {
        case .movie:
            let url = try URL.build(Self.api, path: "/search/movie",
                                    query: ["query": query, "year": year.map(String.init),
                                            "language": language])
            let results = try await http.json(SearchResponse.self, url: url, headers: headers).results
            return Self.best(of: results, matching: query).map { ($0.id, .movie) }
        case .series:
            let url = try URL.build(Self.api, path: "/search/tv",
                                    query: ["query": query, "first_air_date_year": year.map(String.init),
                                            "language": language])
            let results = try await http.json(SearchResponse.self, url: url, headers: headers).results
            return Self.best(of: results, matching: query).map { ($0.id, .series) }
        case nil:
            let url = try URL.build(Self.api, path: "/search/multi",
                                    query: ["query": query, "language": language])
            let results = try await http.json(SearchResponse.self, url: url, headers: headers).results
            guard let hit = results.first(where: { $0.media_type == "movie" || $0.media_type == "tv" }) else { return nil }
            return (hit.id, hit.media_type == "movie" ? .movie : .series)
        }
    }

    private func details(id: Int, kind: Kind) async throws -> Snapshot {
        let path = kind == .movie ? "/movie/\(id)" : "/tv/\(id)"
        // One request rather than five. `append_to_response` costs nothing extra
        // and these are exactly the fields a library sets on a record.
        let extras = kind == .movie
            ? "external_ids,release_dates,videos,credits"
            : "external_ids,content_ratings,videos,aggregate_credits"
        let url = try URL.build(Self.api, path: path,
                                query: ["append_to_response": extras, "language": language])
        let payload = try await http.json(Details.self, url: url, headers: headers)

        let title = payload.title ?? payload.name
        let originalTitle = payload.original_title ?? payload.original_name

        return Snapshot(
            ids: Identifiers(imdb: payload.imdb_id ?? payload.external_ids?.imdb_id, tmdb: payload.id),
            kind: kind,
            title: title,
            originalTitle: originalTitle,
            overview: payload.overview?.nilIfEmpty,
            releaseDate: (payload.release_date ?? payload.first_air_date)?.asReleaseDate,
            runtimeMinutes: payload.runtime ?? payload.episode_run_time?.first,
            episodeCount: payload.number_of_episodes,
            genres: payload.genres?.map(\.name),
            rating: payload.vote_average,
            posterURL: payload.poster_path.map { URL(string: Self.images + "/original" + $0) } ?? nil,
            backdropURL: payload.backdrop_path.map { URL(string: Self.images + "/original" + $0) } ?? nil,
            // Deliberately silent: TMDB has no anime type, and its `anime`
            // keyword is volunteer-applied. AniList answering is the signal.
            isAnime: nil,
            contentRating: payload.certification(in: region),
            trailerYouTubeID: payload.videos?.trailerKey,
            cast: payload.castMembers,
            searchNames: [title, originalTitle].compactMap { $0?.nilIfEmpty }.deduplicatedNames
        )
    }

    /// Which of several results is the one that was asked for.
    ///
    /// TMDB's own ordering is kept wherever it is the only signal — but it puts
    /// the 1999 Hunter × Hunter ahead of the 2011 one, and a library matched to
    /// the wrong adaptation is wrong about everything downstream: 62 episodes
    /// instead of 148, one season instead of three, and every absolute number
    /// mapped against the wrong run.
    ///
    /// So among results whose title *is* the query — remakes, and only remakes —
    /// the most popular wins. Where nothing matches the title exactly this
    /// changes nothing and TMDB's relevance stands, because then popularity would
    /// be answering a question it was not asked.
    static func best(of results: [SearchHit], matching query: String) -> SearchHit? {
        let asked = query.normalizedForMatching
        let sameTitle = results.filter {
            ($0.name ?? $0.title ?? "").normalizedForMatching == asked
        }
        guard !sameTitle.isEmpty else { return results.first }
        return sameTitle.max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }
    }

    static func profileURL(_ path: String?) -> URL? {
        guard let path, let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(images)/original\(encoded)")
    }

    // MARK: - Payloads

    struct FindResponse: Decodable {
        var movie_results: [SearchHit] = []
        var tv_results: [SearchHit] = []
    }

    struct SearchResponse: Decodable {
        var results: [SearchHit] = []
    }

    struct SearchHit: Decodable {
        let id: Int
        var media_type: String?
        var name: String?
        var title: String?
        var popularity: Double?
    }

    private struct Details: Decodable {
        let id: Int
        var imdb_id: String?
        var external_ids: ExternalIDs?
        var title: String?
        var name: String?
        var original_title: String?
        var original_name: String?
        var overview: String?
        var release_date: String?
        var first_air_date: String?
        var runtime: Int?
        var episode_run_time: [Int]?
        var number_of_episodes: Int?
        var genres: [Genre]?
        var vote_average: Double?
        var poster_path: String?
        var backdrop_path: String?

        var content_ratings: ContentRatings?
        var release_dates: ReleaseDates?
        var videos: Videos?
        var credits: Credits?
        var aggregate_credits: AggregateCredits?

        struct ExternalIDs: Decodable { var imdb_id: String? }
        struct Genre: Decodable { let name: String }

        struct ContentRatings: Decodable {
            struct Entry: Decodable { let iso_3166_1: String; let rating: String? }
            var results: [Entry] = []
        }

        struct ReleaseDates: Decodable {
            struct Entry: Decodable {
                struct Release: Decodable { var certification: String? }
                let iso_3166_1: String
                var release_dates: [Release] = []
            }
            var results: [Entry] = []
        }

        struct Videos: Decodable {
            struct Clip: Decodable {
                let key: String
                let site: String
                let type: String
                var official: Bool?
            }
            var results: [Clip] = []

            /// An official YouTube trailer, else any YouTube trailer, else any
            /// YouTube clip — a teaser is better than a blank space where a
            /// preview should be.
            var trailerKey: String? {
                let youTube = results.filter { $0.site.caseInsensitiveCompare("YouTube") == .orderedSame }
                let trailers = youTube.filter { $0.type.caseInsensitiveCompare("Trailer") == .orderedSame }
                return trailers.first(where: { $0.official == true })?.key
                    ?? trailers.first?.key
                    ?? youTube.first?.key
            }
        }

        struct Credits: Decodable {
            struct Member: Decodable {
                let id: Int
                let name: String
                var character: String?
                var profile_path: String?
                var order: Int?
            }
            var cast: [Member] = []
        }

        struct AggregateCredits: Decodable {
            struct Member: Decodable {
                struct Role: Decodable { var character: String? }
                let id: Int
                let name: String
                var roles: [Role]?
                var profile_path: String?
                var order: Int?
            }
            var cast: [Member] = []
        }

        /// The rating for the asked-for country, or nothing.
        ///
        /// No falling back to another country: ratings are not translations of
        /// each other, and showing a French viewer `TV-MA` is showing them a
        /// rating from a system they do not use.
        func certification(in region: String) -> String? {
            if let entry = content_ratings?.results.first(where: { $0.iso_3166_1 == region }) {
                return entry.rating?.nilIfEmpty
            }
            return release_dates?.results.first { $0.iso_3166_1 == region }?
                .release_dates.compactMap { $0.certification?.nilIfEmpty }.first
        }

        var castMembers: [CastMember]? {
            let members: [CastMember]
            if let aggregate = aggregate_credits, !aggregate.cast.isEmpty {
                members = aggregate.cast.map {
                    CastMember(id: $0.id, name: $0.name,
                               character: $0.roles?.first?.character?.nilIfEmpty,
                               profileURL: TMDBProvider.profileURL($0.profile_path), order: $0.order)
                }
            } else if let credits, !credits.cast.isEmpty {
                members = credits.cast.map {
                    CastMember(id: $0.id, name: $0.name, character: $0.character?.nilIfEmpty,
                               profileURL: TMDBProvider.profileURL($0.profile_path), order: $0.order)
                }
            } else {
                return nil
            }
            return members.sorted { ($0.order ?? .max) < ($1.order ?? .max) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
