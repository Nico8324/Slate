import Foundation

/// AniList, for anime — and only for anime.
///
/// Needs no credential, which is why it is in the first cut and AniDB is not.
/// It answers the two questions TMDB cannot: whether a title is anime at all,
/// and what a release group calls it (romaji, before English).
public struct AniListProvider: MetadataProvider, Sendable {
    public let provider = Provider.aniList

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private let http: HTTP

    public init(session: URLSession = .shared) {
        self.http = HTTP(session: session)
    }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        // No id bridge exists from IMDb or TMDB to AniList, so a name is the
        // only way in. Without one there is nothing to ask.
        guard lookup.ids.aniList != nil || lookup.query != nil else { return nil }

        let body = try JSONEncoder().encode(Request(
            query: Self.query,
            variables: .init(id: lookup.ids.aniList, search: lookup.query)
        ))

        let media: Media?
        do {
            media = try await http.json(Response.self, url: Self.endpoint, method: "POST",
                                        headers: ["Accept": "application/json"], body: body).data?.Media
        } catch SlateError.http(let status, _) where status == 404 {
            return nil // AniList reports "no such anime" as a 404. Not a failure.
        }
        guard let media, matches(media, lookup: lookup) else { return nil }
        return snapshot(from: media)
    }

    /// AniList search is fuzzy and will answer for western titles it should not.
    /// Accept a hit only when one of its names actually looks like the query.
    private func matches(_ media: Media, lookup: Lookup) -> Bool {
        guard lookup.ids.aniList == nil, let query = lookup.query?.normalizedForMatching, !query.isEmpty else {
            return true // Looked up by id, or nothing to check against.
        }
        return media.allNames.lazy.map(\.normalizedForMatching).contains { name in
            name == query || name.contains(query) || query.contains(name)
        }
    }

    private func snapshot(from media: Media) -> Snapshot {
        Snapshot(
            ids: Identifiers(aniList: media.id, myAnimeList: media.idMal),
            kind: media.format == "MOVIE" ? .movie : .series,
            title: media.title?.romaji ?? media.title?.english,
            originalTitle: media.title?.native,
            overview: media.description?.strippingHTML.nilIfEmpty,
            releaseDate: media.startDate?.date,
            runtimeMinutes: media.duration,
            episodeCount: media.episodes,
            genres: media.genres,
            rating: media.averageScore.map { Double($0) / 10 },
            posterURL: media.coverImage?.extraLarge.flatMap(URL.init(string:)),
            backdropURL: media.bannerImage.flatMap(URL.init(string:)),
            isAnime: true,
            searchNames: media.allNames
        )
    }

    // MARK: - GraphQL

    private static let query = """
    query ($id: Int, $search: String) {
      Media(id: $id, search: $search, type: ANIME) {
        id idMal format episodes duration genres averageScore bannerImage synonyms description
        title { romaji english native }
        startDate { year month day }
        coverImage { extraLarge }
      }
    }
    """

    private struct Request: Encodable {
        let query: String
        let variables: Variables
        struct Variables: Encodable {
            let id: Int?
            let search: String?
        }
    }

    private struct Response: Decodable {
        var data: Payload?
        struct Payload: Decodable { var Media: AniListProvider.Media? }
    }

    fileprivate struct Media: Decodable {
        let id: Int
        var idMal: Int?
        var format: String?
        var episodes: Int?
        var duration: Int?
        var genres: [String]?
        var averageScore: Int?
        var bannerImage: String?
        var synonyms: [String]?
        var description: String?
        var title: Title?
        var startDate: FuzzyDate?
        var coverImage: CoverImage?

        /// Romaji first: it is what a release group names a file.
        ///
        /// The three titles are kept whatever their script — Japanese ones are
        /// used on the trackers. Synonyms are not: AniList carries the Thai,
        /// Hebrew and Arabic name of everything, and none of that is ever in a
        /// release name.
        var allNames: [String] {
            [title?.romaji, title?.english, title?.native].compactMap { $0 }
                + (synonyms ?? []).filter(\.isMostlyLatin)
        }

        struct Title: Decodable {
            var romaji: String?
            var english: String?
            var native: String?
        }

        struct CoverImage: Decodable { var extraLarge: String? }

        struct FuzzyDate: Decodable {
            var year: Int?
            var month: Int?
            var day: Int?

            var date: Date? {
                guard let year else { return nil }
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = TimeZone(identifier: "UTC")
                components.year = year
                components.month = month ?? 1
                components.day = day ?? 1
                return components.date
            }
        }
    }
}

extension String {
    /// AniList descriptions arrive as HTML fragments.
    var strippingHTML: String {
        replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Letters outside ASCII are fine in moderation — "Titãs" stays, a Thai
    /// title does not.
    var isMostlyLatin: Bool {
        let letters = filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        return Double(letters.filter(\.isASCII).count) / Double(letters.count) >= 0.8
    }

    var normalizedForMatching: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
