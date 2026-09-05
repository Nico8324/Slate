import Foundation

/// Searching, browsing and people — the questions only TMDB can answer.
///
/// Deliberately **not** on ``MetadataAggregator``. That type exists to ask
/// several providers one question and keep every answer with its source; these
/// have one possible source, one ranking, and nothing to cross-reference.
/// Putting them behind the aggregator would dress a single provider's opinion as
/// a merged one — the type a caller reaches for *is* the attribution.
extension TMDBProvider {

    /// What a search might have meant, in TMDB's own order.
    ///
    /// ``snapshot(for:)`` collapses this to one title, which is right when a
    /// title is unambiguous and wrong when a person should choose. "Dragon Ball"
    /// resolved to Dragon Ball Z for as long as nobody could see the
    /// alternatives.
    public func candidates(for query: String, kind: Kind? = nil, page: Int = 1) async throws -> [Candidate] {
        let path = switch kind {
        case .movie: "/search/movie"
        case .series: "/search/tv"
        case nil: "/search/multi"
        }
        return try await candidates(path: path, kind: kind,
                                    query: ["query": query, "page": String(page)])
    }

    /// One of TMDB's published lists.
    public func titles(in list: TitleList, page: Int = 1) async throws -> [Candidate] {
        try await candidates(path: list.path, kind: list.kind, query: ["page": String(page)])
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
        return (payload.cast + payload.crew)
            .compactMap { $0.candidate(assuming: nil) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
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
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/search/person",
                                query: ["query": query, "page": String(page), "language": language])
        return try await http.json(PersonSearch.self, url: url, headers: headers).results
            .compactMap { hit in
                hit.name?.nilIfEmpty.map {
                    Person(id: hit.id, name: $0, profileURL: Self.imageURL(hit.profile_path),
                           department: hit.known_for_department?.nilIfEmpty)
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

    struct CandidateResponse: Decodable {
        struct Hit: Decodable {
            let id: Int
            var media_type: String?
            var name: String?
            var title: String?
            var first_air_date: String?
            var release_date: String?
            var poster_path: String?

            func candidate(assuming kind: Kind?) -> Candidate? {
                let resolved: Kind? = switch media_type {
                case "movie": .movie
                case "tv": .series
                // A mixed list also returns people, who are not titles.
                case .some: nil
                case nil: kind
                }
                guard let resolved, let title = (title ?? name)?.nilIfEmpty else { return nil }
                return Candidate(
                    ids: Identifiers(tmdb: id), kind: resolved, title: title,
                    year: (release_date ?? first_air_date).flatMap { Int($0.prefix(4)) },
                    posterURL: TMDBProvider.imageURL(poster_path), provider: .tmdb
                )
            }
        }
        var results: [Hit] = []
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
        }
        var results: [Hit] = []
    }
}
