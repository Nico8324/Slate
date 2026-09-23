import Foundation

/// A chart AniList publishes, ranked by anime fans rather than by a general database.
public enum AniListChart: Sendable, Hashable {
    /// Rising right now.
    case trending
    /// Most popular of all time.
    case popular
    /// The current broadcast season, most popular first.
    case thisSeason
    /// Best rated.
    case topRated
    /// Announced and not out yet, most anticipated first.
    case upcoming
}

extension AniListProvider {
    /// One page of a chart, in AniList's order.
    ///
    /// Rows carry the AniList and MyAnimeList ids, a title (English where AniList has
    /// one, else romaji), a year and a cover. They carry no TMDB id — AniList numbers
    /// the work, not the broadcast; ``AnimeIDBridge/broadcastIDs(ofAniList:kind:)``
    /// finds it.
    ///
    /// - Parameters:
    ///   - chart: Which chart.
    ///   - kind: `.series` for TV, TV shorts and web series; `.movie` for films.
    ///   - page: 1-based.
    ///   - perPage: 1…50.
    ///   - now: The date the current season is worked out from; injectable for tests.
    public func titles(
        in chart: AniListChart, kind: Kind, page: Int = 1, perPage: Int = 25, now: Date = .now
    ) async throws -> [Candidate] {
        guard page >= 1 else { return [] }
        try Task.checkCancellation()
        let (season, year) = Self.season(of: now)
        var variables = ChartVariables(
            page: page, perPage: min(max(perPage, 1), 50),
            format: kind == .movie ? ["MOVIE"] : ["TV", "TV_SHORT", "ONA"],
            sort: ["POPULARITY_DESC"]
        )
        switch chart {
        case .trending: variables.sort = ["TRENDING_DESC", "POPULARITY_DESC"]
        case .popular: break
        case .thisSeason: (variables.season, variables.seasonYear) = (season, year)
        case .topRated: variables.sort = ["SCORE_DESC"]
        case .upcoming: variables.status = "NOT_YET_RELEASED"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(ChartRequest(query: Self.chartQuery, variables: variables))
        let response = try await http.json(ChartResponse.self, url: URL(string: "https://graphql.anilist.co")!,
                                           method: "POST", headers: ["Accept": "application/json"], body: body)
        let titles = response.media.compactMap { $0.candidate(kind: kind) }
        Log.aniList.debug("chart page \(page, privacy: .public) — \(titles.count, privacy: .public) titles")
        return titles
    }

    /// AniList's broadcast seasons: winter starts in January, spring in April,
    /// summer in July, fall in October.
    static func season(of date: Date) -> (season: String, year: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        let season = switch parts.month ?? 1 {
        case 1...3: "WINTER"
        case 4...6: "SPRING"
        case 7...9: "SUMMER"
        default: "FALL"
        }
        return (season, parts.year ?? 2026)
    }

    private static let chartQuery = """
    query ($page: Int, $perPage: Int, $sort: [MediaSort], $format: [MediaFormat], $season: MediaSeason, $seasonYear: Int, $status: MediaStatus) {
      Page(page: $page, perPage: $perPage) {
        media(type: ANIME, isAdult: false, sort: $sort, format_in: $format, season: $season, seasonYear: $seasonYear, status: $status) {
          id idMal format title { romaji english } startDate { year } coverImage { extraLarge }
        }
      }
    }
    """

    private struct ChartRequest: Encodable {
        let query: String
        let variables: ChartVariables
    }

    private struct ChartVariables: Encodable {
        var page: Int
        var perPage: Int
        var format: [String]
        var sort: [String]
        var season: String?
        var seasonYear: Int?
        var status: String?
    }

    private struct ChartResponse: Decodable {
        var media: [Row]

        struct Row: Decodable {
            let id: Int
            var idMal: Int?
            var title: Title?
            var startDate: Year?
            var coverImage: Cover?

            struct Title: Decodable { var romaji: String?; var english: String? }
            struct Year: Decodable { var year: Int? }
            struct Cover: Decodable { var extraLarge: String? }

            func candidate(kind: Kind) -> Candidate? {
                guard id > 0, let name = (title?.english?.nilIfEmpty ?? title?.romaji?.nilIfEmpty) else { return nil }
                return Candidate(
                    ids: Identifiers(aniList: id, myAnimeList: idMal).validated, kind: kind, title: name,
                    year: startDate?.year, posterURL: coverImage?.extraLarge.flatMap(URL.init(string:)),
                    provider: .aniList
                )
            }
        }

        private enum Keys: String, CodingKey { case data, errors }
        private struct Payload: Decodable { var Page: PageResult? }
        private struct PageResult: Decodable { var media: [Row]? }
        private struct Failure: Decodable {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            // A GraphQL error arrives with HTTP 200; it is a failure, not an empty chart.
            guard (try values.decodeIfPresent([Failure].self, forKey: .errors) ?? []).isEmpty,
                  let media = try values.decodeIfPresent(Payload.self, forKey: .data)?.Page?.media
            else { throw SlateError.graphQL(.aniList) }
            self.media = media
        }
    }
}
