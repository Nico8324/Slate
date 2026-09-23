import Foundation

/// Searching, browsing and people — the questions only TMDB can answer.
///
/// Deliberately **not** on ``MetadataAggregator``. That type exists to ask
/// several providers one question and keep every answer with its source; these
/// have one possible source, one ranking, and nothing to cross-reference.
/// Putting them behind the aggregator would dress a single provider's opinion as
/// a merged one — the type a caller reaches for *is* the attribution.
extension TMDBProvider {

    /// The last page TMDB serves; past it the API answers with an error, not an
    /// empty page, which ended an infinite scroll on a thrown request.
    public static let lastPage = 500

    /// What a search might have meant, in TMDB's own order.
    ///
    /// ``snapshot(for:)`` collapses this to one title, which is right when a
    /// title is unambiguous and wrong when a person should choose. "Dragon Ball"
    /// resolved to Dragon Ball Z for as long as nobody could see the
    /// alternatives.
    public func candidates(for query: String, kind: Kind? = nil, page: Int = 1) async throws -> [Candidate] {
        guard (1...Self.lastPage).contains(page) else { return [] }
        let path = switch kind {
        case .movie: "/search/movie"
        case .series: "/search/tv"
        case nil: "/search/multi"
        }
        return try await candidates(path: path, kind: kind,
                                    query: ["query": query, "page": String(page)])
    }

    /// One of TMDB's published lists.
    ///
    /// Scoped to ``TMDBProvider``'s `region`. "Now playing" and "upcoming" are
    /// *release-date* windows, and TMDB computes them per country: unscoped, a
    /// restoration re-released in one territory is playing now everywhere, which
    /// is why a 1959 film turns up in a list of this week's. The other lists
    /// ignore the parameter, which is cheaper than maintaining a table of which
    /// ones read it.
    ///
    /// Search is deliberately left unscoped — a region there narrows what can be
    /// found, and a title someone typed should be findable wherever it came out.
    public func titles(in list: TitleList, page: Int = 1) async throws -> [Candidate] {
        guard (1...Self.lastPage).contains(page) else { return [] }
        return try await candidates(path: list.path, kind: list.kind,
                                    query: ["page": String(page), "region": region])
    }

    /// TMDB's genres for films or for shows, named in the provider's `language`.
    ///
    /// The two lists differ — shows have "Action & Adventure" where films have
    /// "Action" and "Adventure" — so a genre is looked up for the kind it browses.
    public func genres(of kind: Kind) async throws -> [TMDBGenre] {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: kind == .movie ? "/genre/movie/list" : "/genre/tv/list",
                                query: ["language": language])
        return try await http.json(GenreList.self, url: url, headers: headers).genres
            .map { TMDBGenre(id: $0.id, name: $0.name) }
    }

    /// One page of a genre's titles, most popular first.
    ///
    /// Only titles with some votes: sorted by popularity alone, discover lists
    /// unrated uploads that nobody has heard of among the films people know.
    public func titles(inGenre genreID: Int, kind: Kind, page: Int = 1) async throws -> [Candidate] {
        guard (1...Self.lastPage).contains(page) else { return [] }
        return try await candidates(
            path: kind == .movie ? "/discover/movie" : "/discover/tv", kind: kind,
            query: ["with_genres": String(genreID), "sort_by": "popularity.desc",
                    "vote_count.gte": "50", "include_adult": "false", "page": String(page)]
        )
    }

    /// Films or shows announced and not out yet, the most awaited first, with their
    /// release dates — for a show, its premiere.
    ///
    /// Unlike ``TitleList/upcomingMovies`` — the next few weeks in cinemas of
    /// one country — this reaches as far ahead as TMDB has dates, which is what
    /// a list of what's been announced needs. Popularity first keeps the far
    /// future's placeholders at the end. A title out today isn't upcoming —
    /// today in `calendar`, the viewer's: at 20:00 in California it is already
    /// tomorrow in UTC, and tomorrow's releases are still to come.
    ///
    /// New shows only: a returning show's next season is dated on its episodes,
    /// which discover can't sort by without listing every show on the air.
    public func upcoming(
        _ kind: Kind, after day: Date = .now, calendar: Calendar = .current, page: Int = 1
    ) async throws -> [Candidate] {
        guard (1...Self.lastPage).contains(page) else { return [] }
        // The day as release dates are kept: that calendar day at midnight UTC.
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let from = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
        guard let today = from.asReleaseDate else { return [] }
        return try await candidates(
            path: kind == .movie ? "/discover/movie" : "/discover/tv", kind: kind,
            query: [kind == .movie ? "primary_release_date.gte" : "first_air_date.gte": from,
                    "sort_by": "popularity.desc", "include_adult": "false", "page": String(page)]
        ).filter { ($0.releaseDate ?? .distantPast) > today }
    }

    /// Everything a person is credited in, most recent first.
    ///
    /// Both departments in one list: someone who directed one film and acted in
    /// another is credited for both, and splitting them would make a caller ask
    /// twice to show one filmography.
    public func filmography(personID: Int) async throws -> [Candidate] {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/person/\(personID)/combined_credits",
                                query: ["language": language])
        let payload = try await http.json(CombinedCredits.self, url: url, headers: headers)
        // Once per title: the crew list has one entry per job — a director
        // who also wrote and produced is there three times — and someone who
        // acted in their own film is in both lists.
        var seen = Set<String>()
        return (payload.cast + payload.crew)
            .compactMap { $0.candidate(assuming: nil) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    /// The films of a collection — a ``Franchise`` — in release order.
    ///
    /// Unreleased entries without a date come last. The franchise comes from
    /// ``TitleMetadata/franchise``; this is the one request that lists what is in it.
    public func collection(id: Int) async throws -> [Candidate] {
        guard id > 0 else { throw SlateError.invalidLookup }
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/collection/\(id)", query: ["language": language])
        return try await http.json(CollectionPayload.self, url: url, headers: headers).parts
            .compactMap { $0.candidate(assuming: .movie) }
            .sorted { ($0.year ?? .max) < ($1.year ?? .max) }
    }

    public func person(id: Int) async throws -> Person? {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/person/\(id)", query: ["language": language])
        let payload = try await http.json(PersonPayload.self, url: url, headers: headers)
        guard let name = payload.name?.nilIfEmpty else { return nil }
        return Person(
            id: payload.id, name: name,
            biography: payload.biography?.nilIfEmpty,
            birthday: payload.birthday?.asReleaseDate,
            deathday: payload.deathday?.asReleaseDate,
            profileURL: Self.imageURL(payload.profile_path),
            department: payload.known_for_department?.nilIfEmpty
        )
    }

    public func searchPeople(_ query: String, page: Int = 1) async throws -> [Person] {
        guard (1...Self.lastPage).contains(page) else { return [] }
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/search/person",
                                query: ["query": query, "page": String(page), "language": language])
        return try await http.json(PersonSearch.self, url: url, headers: headers).results
            .compactMap { hit in
                hit.name?.nilIfEmpty.map {
                    Person(id: hit.id, name: $0, profileURL: Self.imageURL(hit.profile_path),
                           department: hit.known_for_department?.nilIfEmpty, popularity: hit.popularity)
                }
            }
    }

    // MARK: - Shared

    private func candidates(path: String, kind: Kind?, query: [String: String?]) async throws -> [Candidate] {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        var query = query
        query["language"] = language
        let url = try URL.build(Self.api, path: path, query: query)
        return try await http.json(CandidateResponse.self, url: url, headers: headers).results
            .compactMap { $0.candidate(assuming: kind) }
    }

    struct GenreList: Decodable {
        struct Entry: Decodable { let id: Int; let name: String }
        let genres: [Entry]
    }

    struct CandidateResponse: Decodable {
        struct Hit: Decodable {
            let id: Int
            var media_type: String?
            var name: String?
            var title: String?
            var first_air_date: String?
            var release_date: String?
            var poster_path: String?
            var backdrop_path: String?
            var original_language: String?
            var genre_ids: [Int]?

            func candidate(assuming kind: Kind?) -> Candidate? {
                let resolved: Kind? = switch media_type {
                case "movie": .movie
                case "tv": .series
                // A mixed list also returns people, who are not titles.
                case .some: nil
                case nil: kind
                }
                guard let resolved, let title = (title ?? name)?.nilIfEmpty else { return nil }
                let date = release_date ?? first_air_date
                return Candidate(
                    ids: Identifiers(tmdb: id), kind: resolved, title: title,
                    year: date.flatMap { Int($0.prefix(4)) }, releaseDate: date?.asReleaseDate,
                    posterURL: TMDBProvider.imageURL(poster_path),
                    backdropURL: TMDBProvider.imageURL(backdrop_path),
                    originalLanguage: original_language, genreIDs: genre_ids ?? [], provider: .tmdb
                )
            }
        }
        var results: [Hit] = []
    }

    private struct CollectionPayload: Decodable {
        var parts: [CandidateResponse.Hit] = []
    }

    private struct CombinedCredits: Decodable {
        var cast: [CandidateResponse.Hit] = []
        var crew: [CandidateResponse.Hit] = []
    }

    private struct PersonPayload: Decodable {
        let id: Int
        var name: String?
        var biography: String?
        var birthday: String?
        var deathday: String?
        var profile_path: String?
        var known_for_department: String?
    }

    private struct PersonSearch: Decodable {
        struct Hit: Decodable {
            let id: Int
            var name: String?
            var profile_path: String?
            var known_for_department: String?
            var popularity: Double?
        }
        var results: [Hit] = []
    }
}
