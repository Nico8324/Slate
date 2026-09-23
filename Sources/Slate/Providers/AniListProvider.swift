import Foundation

/// AniList, for anime — and only for anime.
///
/// Needs no credential, which is why it is in the first cut and AniDB is not.
/// It answers the two questions TMDB cannot: whether a title is anime at all,
/// and what a release group calls it (romaji, before English).
public struct AniListProvider: MetadataProvider, Sendable {
    public let provider = Provider.aniList

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    let http: HTTP

    /// Hold **one instance for the life of the app**, or copies of one.
    ///
    /// The request allowance lives in this instance. Copies share it — it is a
    /// reference — but a freshly constructed provider gets a new allowance, so
    /// `AniListProvider()` called per lookup is paced against nothing and the
    /// only symptom is 429s arriving later than they should have. Nothing in the
    /// type signature says this, which is why it is written here.
    /// - Parameter session: Session used for requests; injectable for tests.
    /// - Parameter cacheTTL: Cache lifetime in seconds; defaults to one hour.
    ///   Zero disables retention. Finite values are clamped to 0…365 days;
    ///   non-finite values use the default. Expired entries refresh on demand.
    public init(session: URLSession = .shared, cacheTTL: TimeInterval = 3600) {
        // AniList allows about ninety requests a minute. Staying just inside it
        // is the difference between a library scan finishing and a wall of 429s
        // that reads as the provider being down.
        self.http = HTTP(session: session, limiter: RateLimiter(requestsPerSecond: 1.4),
                         cache: ResponseCache(ttl: cacheTTL), provider: .aniList)
    }

    /// Discard cached responses and cancel in-progress requests.
    public func clearCache() async { await http.cache?.removeAll() }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        try lookup.validate()
        try Task.checkCancellation()
        // AniList numbers the work, not the broadcast, so it cannot answer an
        // IMDb or TMDB id directly — a name, or an AniList id someone else
        // supplied, is the only way in. `AnimeIDBridge` is that someone: it
        // turns a broadcast id into an AniList one and the aggregator asks
        // again in a later round. Without it in the providers, an id-only
        // lookup reaches this and there is nothing to ask.
        guard lookup.ids.aniList != nil || lookup.query != nil else {
            // The gap that made an id-only lookup silently romaji-less before
            // AnimeIDBridge existed, and still does when it is not wired.
            Log.aniList.debug(
                "no AniList id and no name — AniList numbers the work, not the broadcast, so there is nothing to ask. Wire AnimeIDBridge to reach it from a broadcast id"
            )
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A filtered search keeps paging until something passes the filter; an
        // unfiltered one is decided by relevance within the first few pages, and
        // paging on only spent a minute of AniList's allowance on a miss.
        let pageLimit = lookup.ids.aniList != nil ? 1 : (lookup.year != nil || lookup.kind != nil ? 20 : 3)
        for page in 1...pageLimit {
            try Task.checkCancellation()
            let body = try encoder.encode(Request(
                query: Self.query,
                variables: .init(id: lookup.ids.aniList, search: lookup.ids.aniList == nil ? lookup.query : nil, page: page)
            ))
            let response: Response
            do {
                response = try await http.json(Response.self, url: Self.endpoint, method: "POST",
                                               headers: ["Accept": "application/json"], body: body)
            } catch SlateError.http(let status, _) where status == 404 {
                return nil
            }
            let candidates = response.data?.Page?.media ?? []
            if let media = pick(from: candidates, lookup: lookup) {
                Log.aniList.debug("matched anilist \(media.id, privacy: .public)")
                var result = snapshot(from: media)
                if lookup.ids.aniList == nil, let asked = lookup.query?.normalizedForMatching {
                    result.matchedLoosely = !media.allNames.contains { $0.normalizedForMatching == asked }
                }
                return result
            }
            guard lookup.ids.aniList == nil, !candidates.isEmpty,
                  response.data?.Page?.pageInfo?.hasNextPage == true else { break }
        }
        return nil
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
        if sameTitle.count > 1 {
            Log.aniList.notice(
                "\(sameTitle.count, privacy: .public) entries carry the asked-for title exactly — taking the most popular"
            )
        }
        return sameTitle.max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }
    }

    /// AniList search is fuzzy and will answer for western titles it should not.
    /// Accept a hit only when one of its names actually looks like the query.
    private func matches(_ media: Media, lookup: Lookup) -> Bool {
        guard media.id > 0 else { return false }
        if let id = lookup.ids.aniList { return media.id == id }
        if let year = lookup.year, media.startDate?.year != year { return false }
        if let kind = lookup.kind {
            guard let format = media.format, (format == "MOVIE" ? Kind.movie : .series) == kind else { return false }
        }
        guard let query = lookup.query?.normalizedForMatching, !query.isEmpty else { return false }
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
            // AniList's mean, kept with the number of people behind it. A 78
            // from forty voters and a 78 from four hundred thousand are the
            // same number and not the same claim.
            ratings: media.averageScore.map {
                [Rating(source: "anilist", value: Double($0) / 10, outOf: 10, votes: media.scoreCount)]
            },
            // Tags are AniList's keywords, ranked by how strongly the community
            // says they apply. Below sixty is noise — a tag two people agreed on.
            keywords: media.tags?.filter { ($0.rank ?? 0) >= 60 }.compactMap(\.name).nilIfEmpty,
            studios: media.studioNames,
            // Not hardcoded to Japan. AniList's `type: ANIME` covers Chinese
            // donghua and Korean aeni too, and answering `ja`/`JP` for
            // "Mo Dao Zu Shi" is a wrong fact carrying this provider's name.
            // Silent where AniList does not say, rather than guessing.
            originalLanguage: media.countryOfOrigin.flatMap(Media.language(ofCountry:)),
            originCountries: media.countryOfOrigin?.nilIfEmpty.map { [$0] },
            status: media.status.flatMap(ReleaseStatus.init(providerValue:)),
            relations: media.relationList,
            nextEpisodeAirDate: media.nextAiringEpisode?.date,
            searchNames: media.allNames.deduplicatedNames
        )
    }

    // MARK: - GraphQL

    private static let query = """
    query ($id: Int, $search: String, $page: Int) {
      Page(perPage: 25, page: $page) {
        pageInfo { hasNextPage }
        media(id: $id, search: $search, type: ANIME) {
          id idMal format episodes duration genres averageScore bannerImage synonyms description
          popularity status countryOfOrigin
          stats { scoreDistribution { amount } }
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
            let page: Int
        }
    }

    private struct Response: Decodable {
        var data: Payload?
        private enum CodingKeys: String, CodingKey { case data, errors }
        private struct Failure: Decodable {}
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard (try values.decodeIfPresent([Failure].self, forKey: .errors) ?? []).isEmpty else {
                throw SlateError.graphQL(.aniList)
            }
            data = try values.decodeIfPresent(Payload.self, forKey: .data)
            guard data?.Page?.media != nil else { throw SlateError.graphQL(.aniList) }
        }
        struct Payload: Decodable {
            var Page: PageResult?
            struct PageResult: Decodable {
                var media: [AniListProvider.Media]?
                var pageInfo: PageInfo?
                struct PageInfo: Decodable { var hasNextPage: Bool? }
            }
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
        /// ISO 3166-1, as AniList spells it: `JP`, `CN`, `KR`, `TW`.
        var countryOfOrigin: String?
        var stats: Stats?

        struct Stats: Decodable {
            struct Bucket: Decodable { var amount: Int? }
            var scoreDistribution: [Bucket]?
        }

        /// How many people actually scored it — the sum of the distribution,
        /// **not** `popularity`, which counts everyone who put it on a list
        /// including the ones who never rated it.
        var scoreCount: Int? {
            guard let buckets = stats?.scoreDistribution, !buckets.isEmpty else { return nil }
            return buckets.compactMap(\.amount).reduce(0, +)
        }
        var nextAiringEpisode: Airing?

        /// The language a work from this country was made in. Only the four
        /// countries AniList catalogues, because a general country-to-language
        /// table is a different problem and mostly wrong.
        static func language(ofCountry country: String) -> String? {
            switch country.uppercased() {
            case "JP": "ja"
            case "CN", "TW", "HK": "zh"
            case "KR": "ko"
            default: nil
            }
        }
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

            /// Only a complete date. `{year: 2027}` is an announcement, not the
            /// first of January — and AniList outranks TMDB, so a guess here
            /// replaced TMDB's real date.
            var date: Date? {
                guard let year, (1...9999).contains(year), let month, let day else { return nil }
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = TimeZone(identifier: "UTC")
                components.year = year
                components.month = month
                components.day = day
                guard components.isValidDate(in: components.calendar!) else { return nil }
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
