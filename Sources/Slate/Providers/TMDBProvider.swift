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
    /// repeatedly. Held until the configured cache lifetime expires. A
    /// `nil` result is cached too, on purpose: "this show needs no correction" is
    /// exactly the answer that would otherwise be re-asked over the network every
    /// single time.
    var seasonCache: [Int: SeasonStructure?] = [:]
    /// Insertion order, so the cache can be bounded. A `SeasonStructure` carries
    /// every episode of every season, and this was the one cache in the package
    /// with no ceiling — a library scan held all of them for the process.
    private var seasonCacheOrder: [Int] = []
    private var seasonCacheExpiry: [Int: ContinuousClock.Instant] = [:]
    var cacheGeneration = 0
    private let cacheLifetime: Duration
    private static let seasonCacheLimit = 256

    func rememberSeasons(_ structure: SeasonStructure?, for showID: Int) {
        if seasonCache.updateValue(structure, forKey: showID) == nil {
            seasonCacheOrder.append(showID)
        }
        seasonCacheExpiry[showID] = .now.advanced(by: cacheLifetime)
        // Oldest out first, as in `ResponseCache`: the show that matters is the
        // one someone just opened.
        while seasonCacheOrder.count > Self.seasonCacheLimit {
            let oldest = seasonCacheOrder.removeFirst()
            seasonCache.removeValue(forKey: oldest)
            seasonCacheExpiry[oldest] = nil
        }
    }

    func cachedSeasons(for id: Int) -> SeasonStructure?? {
        guard let expiry = seasonCacheExpiry[id], expiry > .now else { return nil }
        return seasonCache[id]
    }

    func forgetSeasons() {
        cacheGeneration += 1
        seasonCacheExpiry.removeAll()
        seasonCache.removeAll()
        seasonCacheOrder.removeAll()
    }

    /// The language metadata comes back in, as TMDB spells it: `fr-FR`, `ja-JP`.
    /// Artwork is deliberately unaffected — every language is fetched and
    /// ``ArtworkSet/best(_:preferring:)`` chooses.
    private(set) var language: String

    /// The country whose ratings and availability are wanted, ISO 3166-1.
    /// Ratings are regional classifications, not translations of one another.
    private(set) var region: String

    /// Hold one instance for the life of the app to share pacing and cached responses.
    ///
    /// - Parameters:
    ///   - accessToken: TMDB read token, supplied by the caller and sent as a bearer header.
    ///   - language: Metadata language, such as `fr-FR` or `ja-JP`.
    ///   - region: Country for ratings, availability, and release-window browsing; defaults to `US`.
    ///   - session: Session used for requests; injectable for tests.
    ///   - cacheTTL: Response and season-cache lifetime in seconds; defaults to one hour.
    ///     Zero disables retention. Finite values are clamped to 0…365 days;
    ///     non-finite values use the default. Expired entries refresh on demand.
    public init(
        accessToken: String, language: String = "en-US", region: String = "US",
        session: URLSession = .shared, cacheTTL: TimeInterval = 3600
    ) {
        self.cacheLifetime = .seconds(cacheTTL.isFinite ? min(max(0, cacheTTL), 31_536_000) : 3600)
        self.accessToken = accessToken
        self.language = language
        self.region = region
        // TMDB is generous, but a library scan is thousands of requests and
        // there is no reason to be the loudest client on the server.
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 20),
                         cache: ResponseCache(ttl: cacheTTL), provider: .tmdb)
    }

    /// Rotate the token in place. Slate never persists it.
    public func updateAPIKey(_ accessToken: String) {
        // Never the token, never a prefix of it, never its length.
        forgetSeasons()
        Log.tmdb.notice("access token rotated")
        self.accessToken = accessToken
    }

    /// Change the metadata language without rebuilding the provider.
    ///
    /// Rebuilding is the obvious way to do this and it costs more than it looks:
    /// the request allowance and every remembered response live in the instance,
    /// so a new one starts unpaced and empty. A user toggling a language setting
    /// twice would be paced against nothing at the moment they are making the
    /// most requests.
    ///
    /// Cached responses are discarded here, because they are in the old
    /// language. Episode-group names are localised too, so orderings go with
    /// them — the numbering does not change, but the names shown would be stale.
    public func updateLanguage(_ language: String) async {
        guard language != self.language else { return }
        self.language = language
        await clearCache()
    }

    /// Change the country whose ratings and availability are wanted. Availability
    /// is per-country, so cached responses go with it.
    public func updateRegion(_ region: String) async {
        guard region != self.region else { return }
        self.region = region
        await clearCache()
    }

    /// Clear responses and season structures; the next lookup fetches fresh metadata.
    /// In-progress lookups are cancelled so they cannot restore stale data.
    public func clearCache() async {
        forgetSeasons()
        await http.cache?.removeAll()
    }

    var headers: [String: String] {
        ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
    }

    /// Resolves by TMDB id, then by IMDb id, then by search — the first of
    /// those the lookup can supply.
    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        try lookup.validate()
        try Task.checkCancellation()
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        if let id = lookup.ids.tmdb, let kind = lookup.kind {
            Log.tmdb.debug("resolving by tmdb id \(id, privacy: .public) (\(kind.rawValue, privacy: .public))")
            return try await details(id: id, kind: kind)
        }
        if lookup.ids.tmdb != nil, lookup.kind == nil, lookup.ids.imdb == nil, lookup.query == nil {
            // A TMDB id names a film or a show depending on which it is, and
            // nothing else here says which. Answering nil made this read as "no
            // such title" when it was a question that cannot be asked.
            Log.tmdb.error("a tmdb id with no kind, no imdb id and no name — cannot tell a film from a show")
            throw SlateError.invalidLookup
        }
        if let imdb = lookup.ids.imdb {
            guard let hit = try await find(imdb: imdb) else {
                Log.tmdb.notice("\(imdb, privacy: .public) — TMDB holds no movie or show under that IMDb id")
                return nil
            }
            Log.tmdb.debug("\(imdb, privacy: .public) → tmdb \(hit.id, privacy: .public) (\(hit.kind.rawValue, privacy: .public))")
            return try await details(id: hit.id, kind: hit.kind)
        }
        if let query = lookup.query {
            guard let hit = try await search(query, year: lookup.year, kind: lookup.kind) else {
                Log.tmdb.notice("no search result for the requested name")
                return nil
            }
            return try await details(id: hit.id, kind: hit.kind)
        }
        // Neither an id nor a name: nothing was asked, which is different from
        // asking and finding nothing.
        Log.tmdb.debug("lookup carries no tmdb id, no imdb id and no name — nothing to ask")
        return nil
    }

    // MARK: - Endpoints

    /// The one `/find/` request. Three callers read three things out of it —
    /// whichever kind it is, the film id, the show id — and it was written three
    /// times for that.
    func findByIMDb(_ imdb: String) async throws -> FindResponse {
        let url = try URL.build(Self.api, path: "/find/\(imdb)",
                                query: ["external_source": "imdb_id", "language": language])
        return try await http.json(FindResponse.self, url: url, headers: headers)
    }

    private func find(imdb: String) async throws -> (id: Int, kind: Kind)? {
        let response = try await findByIMDb(imdb)
        if let movie = response.movie_results.first { return (movie.id, .movie) }
        if let show = response.tv_results.first { return (show.id, .series) }
        return nil
    }

    private func search(_ query: String, year: Int?, kind: Kind?) async throws -> (id: Int, kind: Kind)? {
        if kind == nil, let year {
            // `/search/multi` cannot filter by year, so this used to filter on the
            // client, page after page — up to 500 requests for "Love" in 1950.
            // The two typed searches filter on the server, and cost two requests.
            async let movie = searchHit(query, year: year, kind: .movie)
            async let show = searchHit(query, year: year, kind: .series)
            let hits = try await [movie, show].compactMap { $0 }
            let byID = Dictionary(hits.map { ("\($0.kind.rawValue)-\($0.hit.id)", $0.kind) }) { first, _ in first }
            guard let best = Self.best(of: hits.map(\.hit), matching: query) else { return nil }
            let kind = hits.first { $0.hit.id == best.id && $0.hit.media_type == best.media_type }?.kind
                ?? byID.values.first ?? .movie
            return (best.id, kind)
        }
        return try await searchHit(query, year: year, kind: kind).map { ($0.hit.id, $0.kind) }
    }

    private func searchHit(_ query: String, year: Int?, kind: Kind?) async throws -> (hit: SearchHit, kind: Kind)? {
        let path: String
        var parameters: [String: String?] = ["query": query, "language": language]
        switch kind {
        case .movie:
            path = "/search/movie"
            parameters["primary_release_year"] = year.map(String.init)
        case .series:
            path = "/search/tv"
            parameters["first_air_date_year"] = year.map(String.init)
        case nil:
            path = "/search/multi"
        }
        for page in 1...Self.lastPage {
            try Task.checkCancellation()
            parameters["page"] = String(page)
            let url = try URL.build(Self.api, path: path, query: parameters)
            let response = try await http.json(SearchResponse.self, url: url, headers: headers)
            let titles = response.results.filter {
                guard $0.id > 0 else { return false }
                guard kind == nil else { return true }
                guard $0.media_type == "movie" || $0.media_type == "tv" else { return false }
                guard let year else { return true }
                let date = $0.media_type == "movie" ? $0.release_date : $0.first_air_date
                return date.flatMap { Int($0.prefix(4)) } == year
            }
            if var hit = Self.best(of: titles, matching: query) {
                let resolved = kind ?? (hit.media_type == "movie" ? .movie : .series)
                hit.media_type = resolved == .movie ? "movie" : "tv"
                return (hit, resolved)
            }
            guard !response.results.isEmpty, page < (response.total_pages ?? 1) else { break }
        }
        return nil
    }

    private func details(id: Int, kind: Kind) async throws -> Snapshot {
        let path = kind == .movie ? "/movie/\(id)" : "/tv/\(id)"
        // One request rather than five. `append_to_response` costs nothing extra
        // and these are exactly the fields a library sets on a record.
        // One request, not eight. Everything below is a field a library shows,
        // and `append_to_response` returns them all for the price of the request
        // already being made.
        let extras = kind == .movie
            ? "external_ids,release_dates,videos,credits,keywords,translations,watch/providers,recommendations"
            : "external_ids,content_ratings,videos,aggregate_credits,keywords,translations,watch/providers,recommendations"
        // `language` alone filters `videos` to that one language, so a French
        // lookup never saw the studio's own trailers and a language with no local
        // trailer got none at all. English and untagged ride along for free.
        let url = try URL.build(Self.api, path: path, query: [
            "append_to_response": extras, "language": language,
            "include_video_language": Self.videoLanguages(language, "en"),
        ])
        let payload = try await http.json(Details.self, url: url, headers: headers)

        let title = payload.title ?? payload.name
        let originalTitle = payload.original_title ?? payload.original_name
        let originalLanguage = payload.original_language?.nilIfEmpty
        let trailers = try await trailers(payload.videos?.trailers ?? [], id: id, kind: kind,
                                          originalLanguage: originalLanguage)
        // A score nobody has cast is not a score of zero.
        let rating = (payload.vote_count ?? 0) > 0 ? payload.vote_average : nil

        return Snapshot(
            ids: Identifiers(imdb: payload.imdb_id ?? payload.external_ids?.imdb_id, tmdb: payload.id),
            kind: kind,
            title: title,
            originalTitle: originalTitle,
            overview: payload.localizedOverview(language) ?? payload.overview?.nilIfEmpty,
            releaseDate: (payload.release_date ?? payload.first_air_date)?.asReleaseDate,
            runtimeMinutes: payload.runtime ?? payload.episode_run_time?.first,
            episodeCount: payload.number_of_episodes,
            genres: payload.genres?.map(\.name),
            rating: rating,
            posterURL: Self.imageURL(payload.poster_path),
            backdropURL: Self.imageURL(payload.backdrop_path),
            // Deliberately silent: TMDB has no anime type, and its `anime`
            // keyword is volunteer-applied. AniList answering is the signal.
            isAnime: nil,
            contentRating: payload.certification(in: region),
            // The original version by default — the studio's own cut, which is
            // also what plays well muted. The whole list is in `trailers`.
            trailerYouTubeID: trailers.best(preferring: [originalLanguage, "en"].compactMap { $0 })?.youTubeID,
            cast: payload.castMembers,
            crew: payload.crewMembers,
            trailers: trailers,
            recommendations: payload.recommendations?.results.compactMap { $0.candidate(assuming: kind) },
            // The same number as `rating`, plus the thing `rating` cannot
            // carry: 10.0 from three voters and 8.4 from thirty thousand are
            // not comparable, and only one of them is a recommendation.
            ratings: rating.map {
                [Rating(source: "tmdb", value: $0, outOf: 10, votes: payload.vote_count)]
            },
            watchOptions: payload.watchOptions(in: region),
            keywords: payload.keywordNames,
            studios: payload.studioNames,
            originalLanguage: originalLanguage,
            originCountries: payload.originCountryCodes,
            franchise: payload.belongs_to_collection?.franchise,
            status: payload.status.flatMap(ReleaseStatus.init(providerValue:)),
            nextEpisodeAirDate: payload.next_episode_to_air?.air_date?.asReleaseDate,
            lastEpisodeAirDate: payload.last_episode_to_air?.air_date?.asReleaseDate,
            searchNames: [title, originalTitle].compactMap { $0?.nilIfEmpty }.deduplicatedNames
        )
    }

    /// The details request's videos, plus the original-language ones when that
    /// language was not among those fetched — a Japanese film's own trailer is
    /// in Japanese, and neither the viewer's language nor English finds it.
    /// One extra request, only for titles made in a third language.
    private func trailers(
        _ fetched: [Trailer], id: Int, kind: Kind, originalLanguage: String?
    ) async throws -> [Trailer] {
        let asked = Set([Self.languageCode(language), "en"])
        guard let originalLanguage, !asked.contains(originalLanguage.lowercased()) else { return fetched }
        let path = kind == .movie ? "/movie/\(id)/videos" : "/tv/\(id)/videos"
        let url = try URL.build(Self.api, path: path, query: [
            "include_video_language": Self.videoLanguages(originalLanguage),
        ])
        do {
            let more = try await http.json(Details.Videos.self, url: url, headers: headers).trailers
            let known = Set(fetched.map(\.youTubeID))
            return fetched + more.filter { !known.contains($0.youTubeID) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing original-language trailer is not worth losing the title over.
            Log.tmdb.notice("tmdb \(id, privacy: .public) — original-language videos unavailable (\(Log.describe(error), privacy: .public))")
            return fetched
        }
    }

    /// `fr-FR` → `fr`.
    static func languageCode(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? "").lowercased()
    }

    /// TMDB's `include_video_language`: the given languages, then untagged videos.
    static func videoLanguages(_ tags: String...) -> String {
        (tags.map(languageCode).deduplicatedNames + ["null"]).joined(separator: ",")
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
        guard !sameTitle.isEmpty else {
            Log.tmdb.debug(
                "no exact title match among \(results.count, privacy: .public) results — keeping TMDB's own ranking"
            )
            return results.first
        }
        let winner = sameTitle.max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }
        // The Hunter x Hunter case. Worth a line because picking the wrong
        // adaptation is wrong about everything downstream and looks like nothing.
        if sameTitle.count > 1 {
            Log.tmdb.notice(
                "\(sameTitle.count, privacy: .public) results carry the asked-for title exactly — took tmdb \(winner?.id ?? 0, privacy: .public), the most popular"
            )
        }
        return winner
    }

    static func profileURL(_ path: String?) -> URL? { imageURL(path) }

    /// The widths TMDB's image server renders.
    static let imageWidths = [92, 154, 185, 300, 342, 500, 780, 1280]

    /// The same TMDB image at a width that fits `points × scale` pixels.
    ///
    /// Every URL Slate returns is the `original` — a 2000×3000 poster, several
    /// megabytes — because only the caller knows how big it will be drawn. A
    /// grid of forty posters wants `w342`, not forty originals. Returns the URL
    /// unchanged when it is not a TMDB image or when nothing smaller fits.
    public static func resized(_ url: URL, toFit pixels: Int) -> URL {
        let marker = "/t/p/original/"
        let string = url.absoluteString
        guard string.hasPrefix(images), string.contains(marker),
              let width = imageWidths.first(where: { $0 >= pixels }) else { return url }
        return URL(string: string.replacingOccurrences(of: marker, with: "/t/p/w\(width)/")) ?? url
    }

    /// `path` is third-party JSON. Percent-encoded rather than interpolated raw:
    /// an unencoded `?` or `#` could not escape the pinned host, but it would
    /// silently become a query or a fragment and fetch a different picture.
    static func imageURL(_ path: String?) -> URL? {
        guard let path = path?.nilIfEmpty, path.hasPrefix("/"), let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(images)/original\(encoded)")
    }

    // MARK: - Payloads

    struct FindResponse: Decodable {
        var movie_results: [SearchHit] = []
        var tv_results: [SearchHit] = []
    }

    struct SearchResponse: Decodable {
        var total_pages: Int?
        var results: [SearchHit] = []
    }

    struct SearchHit: Decodable {
        let id: Int
        var media_type: String?
        var name: String?
        var title: String?
        var popularity: Double?
        var release_date: String?
        var first_air_date: String?
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
        var vote_count: Int?
        var poster_path: String?
        var backdrop_path: String?
        var original_language: String?
        var origin_country: [String]?
        /// Film's answer to `origin_country`, which television has and film does
        /// not — without this the field silently meant "series only", and an
        /// anime *film* could never satisfy a JP-plus-animation heuristic.
        var production_countries: [ProductionCountry]?

        struct ProductionCountry: Decodable { var iso_3166_1: String? }

        var originCountryCodes: [String]? {
            // `nilIfEmpty` on the first: a film carrying `origin_country: []`
            // would otherwise stop the fallback with an empty answer.
            origin_country?.compactMap(\.nilIfEmpty).nilIfEmpty
                ?? production_countries?.compactMap { $0.iso_3166_1?.nilIfEmpty }.nilIfEmpty
        }
        var status: String?
        var belongs_to_collection: CollectionRef?
        var networks: [Named]?
        var production_companies: [Named]?
        var keywords: KeywordBox?
        var translations: TranslationBox?
        var next_episode_to_air: EpisodeStub?
        var last_episode_to_air: EpisodeStub?
        var watchProviders: WatchProviderBox?
        var created_by: [Creator]?
        var recommendations: TMDBProvider.CandidateResponse?

        struct Creator: Decodable {
            let id: Int
            let name: String
            var profile_path: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, imdb_id, external_ids, title, name, original_title, original_name
            case overview, release_date, first_air_date, runtime, episode_run_time
            case number_of_episodes, genres, vote_average, vote_count, poster_path, backdrop_path
            case original_language, origin_country, production_countries
            case status, belongs_to_collection
            case networks, production_companies, keywords, translations
            case next_episode_to_air, last_episode_to_air, content_ratings, release_dates
            case videos, credits, aggregate_credits, created_by, recommendations
            // TMDB names this one with a slash, which is not a Swift identifier.
            case watchProviders = "watch/providers"
        }

        struct Named: Decodable { let name: String }
        struct EpisodeStub: Decodable { var air_date: String? }

        struct CollectionRef: Decodable {
            let id: Int
            let name: String
            var poster_path: String?
            var backdrop_path: String?

            var franchise: Franchise {
                Franchise(id: id, name: name,
                          posterURL: TMDBProvider.imageURL(poster_path),
                          backdropURL: TMDBProvider.imageURL(backdrop_path))
            }
        }

        struct KeywordBox: Decodable {
            var keywords: [Named]?
            /// TMDB names the same field `results` on television and `keywords`
            /// on film.
            var results: [Named]?
        }

        struct TranslationBox: Decodable {
            struct Entry: Decodable {
                struct Data: Decodable {
                    var overview: String?
                    var title: String?
                    var name: String?
                }
                let iso_639_1: String
                let iso_3166_1: String
                var data: Data?
            }
            var translations: [Entry] = []
        }

        struct WatchProviderBox: Decodable {
            struct Region: Decodable {
                struct Service: Decodable {
                    let provider_name: String
                    var logo_path: String?
                }
                var link: String?
                var flatrate: [Service]?
                var rent: [Service]?
                var buy: [Service]?
                var ads: [Service]?
                var free: [Service]?
            }
            var results: [String: Region] = [:]
        }

        var content_ratings: ContentRatings?
        var release_dates: ReleaseDates?
        var videos: Videos?
        var credits: Credits?
        var aggregate_credits: AggregateCredits?

        struct Credits: Decodable {
            struct Member: Decodable {
                let id: Int
                let name: String
                var character: String?
                var profile_path: String?
                var order: Int?
            }
            struct CrewEntry: Decodable {
                let id: Int
                let name: String
                var job: String?
                var department: String?
                var profile_path: String?
            }
            var cast: [Member] = []
            var crew: [CrewEntry]?
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

        var keywordNames: [String]? {
            let names = (keywords?.keywords ?? keywords?.results)?.map(\.name)
            return (names?.isEmpty ?? true) ? nil : names
        }

        var studioNames: [String]? {
            let names = (networks ?? production_companies)?.map(\.name)
            return (names?.isEmpty ?? true) ? nil : names
        }

        /// The overview in the asked-for language, falling back to English.
        ///
        /// TMDB returns an empty string rather than omitting the field when a
        /// language has no translation, and a French library showing a blank
        /// synopsis is worse than one showing an English synopsis. `translations`
        /// rides on the same request, so the fallback costs nothing.
        func localizedOverview(_ language: String) -> String? {
            if let overview = overview?.nilIfEmpty { return overview }
            let parts = language.split(separator: "-")
            let code = String(parts.first ?? "en")
            let entries = (translations?.translations ?? []).filter { $0.data?.overview?.nilIfEmpty != nil }
            let exact = entries.first {
                $0.iso_639_1 == code && $0.iso_3166_1 == (parts.count > 1 ? String(parts[1]) : $0.iso_3166_1)
            }
            let candidate = exact ?? entries.first { $0.iso_639_1 == code }
                ?? entries.first { $0.iso_639_1 == "en" }
            return candidate?.data?.overview?.nilIfEmpty
        }

        /// Availability for one region only.
        ///
        /// Not merged across regions: a service carrying something in the US and
        /// not in France is the ordinary case, and a list that hides which
        /// country each row belongs to answers a question nobody asked.
        func watchOptions(in region: String) -> [WatchOption]? {
            guard let entry = watchProviders?.results[region] else { return nil }
            let link = entry.link.flatMap(URL.init(string:))
            let groups: [(WatchOption.Kind, [WatchProviderBox.Region.Service]?)] = [
                (.subscription, entry.flatrate), (.rent, entry.rent), (.buy, entry.buy),
                (.ads, entry.ads), (.free, entry.free),
            ]
            let options = groups.flatMap { kind, services in
                (services ?? []).map {
                    WatchOption(service: $0.provider_name, kind: kind, region: region,
                                logoURL: TMDBProvider.imageURL($0.logo_path), link: link)
                }
            }
            return options.isEmpty ? nil : options
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

        /// A film's directors and writers; a show's creators. Television's
        /// directors and writers are per episode — dozens for a long run — and
        /// the credit a show page carries is the creator's.
        var crewMembers: [CrewMember]? {
            if let created_by, !created_by.isEmpty {
                return created_by.map {
                    CrewMember(personID: $0.id, name: $0.name, job: "Creator", department: .creator,
                               profileURL: TMDBProvider.profileURL($0.profile_path))
                }
            }
            var seen = Set<String>()
            let members: [CrewMember] = (credits?.crew ?? []).compactMap { entry in
                let department: CrewMember.Department? = switch entry.department {
                case "Directing" where entry.job == "Director": .directing
                case "Writing": .writing
                default: nil
                }
                guard let department, let job = entry.job?.nilIfEmpty else { return nil }
                let member = CrewMember(personID: entry.id, name: entry.name, job: job, department: department,
                                        profileURL: TMDBProvider.profileURL(entry.profile_path))
                return seen.insert(member.id).inserted ? member : nil
            }
            // Directors first, then writers, each in the provider's order.
            return (members.filter { $0.department == .directing } + members.filter { $0.department == .writing })
                .nilIfEmpty
        }

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
                var name: String?
                var iso_639_1: String?
                var iso_3166_1: String?
                var published_at: String?
            }
            var results: [Clip] = []

            /// YouTube's, which is the only site a player can use. Every kind is
            /// kept — a teaser is better than a blank space where a preview
            /// should be — and ``Swift/Array/best(preferring:)`` ranks them.
            var trailers: [Trailer] {
                results.filter { $0.site.caseInsensitiveCompare("YouTube") == .orderedSame && !$0.key.isEmpty }
                    .map { clip in
                        Trailer(
                            youTubeID: clip.key,
                            name: clip.name?.nilIfEmpty,
                            kind: Self.kind(clip.type),
                            language: clip.iso_639_1?.nilIfEmpty?.lowercased(),
                            region: clip.iso_3166_1?.nilIfEmpty,
                            isOfficial: clip.official ?? false,
                            publishedAt: clip.published_at.flatMap(Self.publishedDate)
                        )
                    }
            }

            static func kind(_ type: String) -> Trailer.Kind {
                switch type.lowercased() {
                case "trailer": .trailer
                case "teaser": .teaser
                case "clip": .clip
                case "featurette": .featurette
                case "behind the scenes": .behindTheScenes
                default: .other
                }
            }

            static func publishedDate(_ value: String) -> Date? {
                (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                    ?? (try? Date(value, strategy: Date.ISO8601FormatStyle()))
            }
        }

    }
}

extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
