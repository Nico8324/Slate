import Foundation

extension TMDBProvider: CandidateProvider {

    /// What a search might have meant, most likely first.
    ///
    /// The same results ``snapshot(for:)`` chooses from, unreduced. A picker
    /// showing three Dragon Balls is the cheapest possible fix for matching the
    /// wrong one.
    public func candidates(for query: String, kind: Kind?) async throws -> [Candidate] {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        let path = switch kind {
        case .movie: "/search/movie"
        case .series: "/search/tv"
        case nil: "/search/multi"
        }
        let url = try URL.build(Self.api, path: path, query: ["query": query, "language": language])
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
                // `/search/multi` also returns people, who are not titles.
                case .some: nil
                case nil: kind
                }
                guard let resolved, let title = (title ?? name)?.nilIfEmpty else { return nil }
                let year = (release_date ?? first_air_date)?.prefix(4)
                return Candidate(
                    ids: Identifiers(tmdb: id),
                    kind: resolved,
                    title: title,
                    year: year.flatMap { Int($0) },
                    posterURL: poster_path.flatMap {
                        URL(string: "\(TMDBProvider.images)/original\($0)")
                    },
                    provider: .tmdb
                )
            }
        }
        var results: [Hit] = []
    }
}
