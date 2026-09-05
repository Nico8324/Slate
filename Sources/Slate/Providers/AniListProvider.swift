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

    /// Hold **one instance for the life of the app**, or copies of one.
    ///
    /// The request allowance lives in this instance. Copies share it — it is a
    /// reference — but a freshly constructed provider gets a new allowance, so
    /// `AniListProvider()` called per lookup is paced against nothing and the
    /// only symptom is 429s arriving later than they should have. Nothing in the
    /// type signature says this, which is why it is written here.
    public init(session: URLSession = .shared) {
        // AniList allows about ninety requests a minute. Staying just inside it
        // is the difference between a library scan finishing and a wall of 429s
        // that reads as the provider being down.
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 1.4),
                         cache: ResponseCache())
    }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        // No id bridge exists from IMDb or TMDB to AniList, so a name is the
        // only way in. Without one there is nothing to ask.
        guard lookup.ids.aniList != nil || lookup.query != nil else { return nil }

        let body = try JSONEncoder().encode(Request(
            query: Self.query,
            variables: .init(id: lookup.ids.aniList, search: lookup.query)
        ))

        let candidates: [Media]
        do {
            candidates = try await http.json(Response.self, url: Self.endpoint, method: "POST",
                                             headers: ["Accept": "application/json"],
                                             body: body).data?.Page?.media ?? []
        } catch SlateError.http(let status, _) where status == 404 {
            return nil // AniList reports "no such anime" as a 404. Not a failure.
        }
        guard let media = pick(from: candidates, lookup: lookup) else { return nil }
        return snapshot(from: media)
    }

    /// Which of several entries was asked for.
    ///
    /// AniList's relevance puts the 1999 Hunter × Hunter ahead of the 2011 one,
    /// as TMDB's does. When more than one entry carries the asked-for title
    /// exactly — which is what a remake looks like — the popular one is the one
    /// meant. Otherwise relevance stands, filtered by ``matches(_:lookup:)``.
    private func pick(from candidates: [Media], lookup: Lookup) -> Media? {
        let eligible = candidates.filter { matches($0, lookup: lookup) }
        guard let asked = lookup.query?.normalizedForMatching, !asked.isEmpty else {
            return eligible.first
        }
        let sameTitle = eligible.filter {
            $0.allNames.contains { $0.normalizedForMatching == asked }
        }
        guard !sameTitle.isEmpty else { return eligible.first }
        return sameTitle.max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }
    }

    /// AniList search is fuzzy and will answer for western titles it should not.
    /// Accept a hit only when one of its names actually looks like the query.
    private func matches(_ media: Media, lookup: Lookup) -> Bool {
        guard lookup.ids.aniList == nil, let query = lookup.query?.normalizedForMatching, !query.isEmpty else {
            return true // Looked up by id, or nothing to check against.
        }
        return media.allNames.lazy.map(\.normalizedForMatching).contains { name in
            name.looksLikeTheSameTitleAs(query)
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
            cast: media.castMembers,
            // Tags are AniList's keywords, ranked by how strongly the community
            // says they apply. Below sixty is noise — a tag two people agreed on.
            keywords: media.tags?.filter { ($0.rank ?? 0) >= 60 }.compactMap(\.name).nilIfEmpty,
            studios: media.studioNames,
            originalLanguage: "ja",
            originCountries: ["JP"],
            status: media.status.flatMap(ReleaseStatus.init(providerValue:)),
            relations: media.relationList,
            nextEpisodeAirDate: media.nextAiringEpisode?.date,
            searchNames: media.allNames.deduplicatedNames
        )
    }

    // MARK: - GraphQL

    private static let query = """
    query ($id: Int, $search: String) {
      Page(perPage: 5) {
        media(id: $id, search: $search, type: ANIME) {
          id idMal format episodes duration genres averageScore bannerImage synonyms description
          popularity status
          nextAiringEpisode { airingAt }
          studios { edges { isMain node { name } } }
          tags { name rank }
          relations { edges { relationType node { id idMal format title { romaji english } } } }
          characters(sort: [ROLE, RELEVANCE], perPage: 12) {
            edges { role node { name { full } } voiceActors(language: JAPANESE) { id name { full } image { large } } }
          }
          title { romaji english native }
          startDate { year month day }
          coverImage { extraLarge }
        }
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
        struct Payload: Decodable {
            var Page: PageResult?
            struct PageResult: Decodable { var media: [AniListProvider.Media]? }
        }
    }

    fileprivate struct Media: Decodable {
        let id: Int
        var idMal: Int?
        var format: String?
        var episodes: Int?
        var duration: Int?
        var genres: [String]?
        var averageScore: Int?
        var popularity: Int?
        var bannerImage: String?
        var synonyms: [String]?
        var description: String?
        var title: Title?
        var startDate: FuzzyDate?
        var coverImage: CoverImage?
        var status: String?
        var nextAiringEpisode: Airing?
        var studios: StudioConnection?
        var tags: [Tag]?
        var relations: RelationConnection?
        var characters: CharacterConnection?

        struct Airing: Decodable {
            var airingAt: Int?
            var date: Date? { airingAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        }

        struct Tag: Decodable {
            var name: String?
            var rank: Int?
        }

        struct StudioConnection: Decodable {
            struct Edge: Decodable {
                var isMain: Bool?
                var node: Node?
                struct Node: Decodable { var name: String? }
            }
            var edges: [Edge]?
        }

        struct RelationConnection: Decodable {
            struct Edge: Decodable {
                var relationType: String?
                var node: Node?
                struct Node: Decodable {
                    var id: Int?
                    var idMal: Int?
                    var format: String?
                    var title: Title?
                }
            }
            var edges: [Edge]?
        }

        struct CharacterConnection: Decodable {
            struct Edge: Decodable {
                struct Person: Decodable {
                    struct Name: Decodable { var full: String? }
                    struct Image: Decodable { var large: String? }
                    var id: Int?
                    var name: Name?
                    var image: Image?
                }
                struct Character: Decodable {
                    struct Name: Decodable { var full: String? }
                    var name: Name?
                }
                var role: String?
                var node: Character?
                var voiceActors: [Person]?
            }
            var edges: [Edge]?
        }

        /// Anime credits are the voice actors, listed against the characters
        /// they play — which is what a person looking at an anime record expects
        /// to see, and what TMDB's credits for the same title usually lack.
        var castMembers: [CastMember]? {
            let members = (characters?.edges ?? []).compactMap { edge -> CastMember? in
                guard let actor = edge.voiceActors?.first,
                      let id = actor.id, let name = actor.name?.full?.nilIfEmpty
                else { return nil }
                return CastMember(
                    id: id, name: name,
                    character: edge.node?.name?.full?.nilIfEmpty,
                    profileURL: actor.image?.large.flatMap(URL.init(string:)),
                    // AniList orders by role then relevance, so position is the
                    // billing order; MAIN before SUPPORTING.
                    order: nil
                )
            }
            return members.isEmpty ? nil : members
        }

        /// The animation studio, not the committee. AniList marks one main
        /// studio and lists producers, licensors and broadcasters beside it —
        /// naming all seven answers a question nobody asked.
        var studioNames: [String]? {
            let main = (studios?.edges ?? []).filter { $0.isMain == true }.compactMap { $0.node?.name }
            return main.isEmpty ? nil : main
        }

        var relationList: [Relation]? {
            let list = (relations?.edges ?? []).compactMap { edge -> Relation? in
                guard let type = edge.relationType, let node = edge.node,
                      let title = (node.title?.romaji ?? node.title?.english)?.nilIfEmpty
                else { return nil }
                return Relation(
                    kind: Relation.Kind(providerValue: type),
                    ids: Identifiers(aniList: node.id, myAnimeList: node.idMal),
                    title: title, format: node.format
                )
            }
            return list.isEmpty ? nil : list
        }

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
        // A parenthesised year disambiguates two adaptations; it is not part of
        // the name. AniList files the second Hunter × Hunter as "Hunter x Hunter
        // (2011)", so without this nothing a person types ever matches it
        // exactly, and the 1999 series wins by default. Only parenthesised — a
        // bare trailing year can be the title itself, as in Blade Runner 2049.
        let withoutYear = replacingOccurrences(
            of: #"\(\s*(19|20)\d{2}\s*\)"#, with: "", options: .regularExpression
        )
        // × is how Japanese titles write the x that everyone types: HUNTER×HUNTER
        // and SPY×FAMILY are searched for as "Hunter x Hunter" and "Spy x Family".
        // It is punctuation to `isLetter`, so without this it vanishes and the two
        // spellings stop matching.
        return withoutYear
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "✕", with: "x")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Whether two normalised titles are plausibly the same show.
    ///
    /// Containment has to be allowed — "Frieren" is how people ask for
    /// *Sousou no Frieren* — but bare containment is far too generous: a search
    /// for "Suits" matched *Is This a Zombie? Of the Dead: Yes, This Suits Me
    /// Just Fine*, and a legal drama was filed as anime. The shorter title must
    /// therefore be a substantial part of the longer one, not a word buried in
    /// it. "Frieren" is 47% of "sousounofrieren" and passes; "suits" is 11% of
    /// that zombie title and does not.
    func looksLikeTheSameTitleAs(_ other: String) -> Bool {
        if self == other { return true }
        let (shorter, longer) = count < other.count ? (self, other) : (other, self)
        guard !shorter.isEmpty, longer.contains(shorter) else { return false }
        return Double(shorter.count) >= 0.35 * Double(longer.count)
    }
}
