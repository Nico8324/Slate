import Foundation

/// What to look a title up by. A provider uses whichever parts it understands
/// and returns `nil` when it has nothing to go on.
public struct Lookup: Sendable, Hashable {
    public var ids: Identifiers
    public var query: String?
    public var year: Int?
    public var kind: Kind?
    /// Narrows a lookup to one season, where a provider can use it. Anime ids
    /// need it: two works routinely share one broadcast id.
    public var season: Int?

    public init(
        ids: Identifiers = .init(), query: String? = nil, year: Int? = nil,
        kind: Kind? = nil, season: Int? = nil
    ) {
        self.ids = ids
        self.query = query
        self.year = year
        self.kind = kind
        self.season = season
    }

    /// The id path. Note that AniList cannot answer this one: no id bridge to
    /// it exists from IMDb, which is why ``Lookup/init(search:year:kind:)``
    /// is the lookup that reaches every provider.
    public init(imdbID: String, kind: Kind? = nil) {
        self.init(ids: Identifiers(imdb: imdbID), kind: kind)
    }

    /// The name path. Every provider understands it.
    public init(search query: String, year: Int? = nil, kind: Kind? = nil) {
        self.init(query: query, year: year, kind: kind)
    }
}

/// One provider's unmerged answer. Flat and all-optional on purpose: the
/// aggregator, not the provider, decides how values are attributed and ordered.
public struct Snapshot: Sendable, Equatable {
    public var ids: Identifiers
    public var kind: Kind?
    public var title: String?
    public var originalTitle: String?
    public var overview: String?
    public var releaseDate: Date?
    public var runtimeMinutes: Int?
    public var episodeCount: Int?
    public var genres: [String]?
    /// Normalised to 0...10 by the provider.
    public var rating: Double?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var isAnime: Bool?
    /// An age rating, as the provider spells it in the asked-for region: `TV-MA`,
    /// `16`, `PG-13`.
    public var contentRating: String?
    /// A YouTube key, not a URL — a player wants the id.
    public var trailerYouTubeID: String?
    public var cast: [CastMember]?
    /// One entry per site, never averaged.
    public var ratings: [Rating]?
    /// Where it can be watched, in the region asked for.
    public var watchOptions: [WatchOption]?
    /// Free-text tags — `time travel`, `dystopia`. Discovery, not genre.
    public var keywords: [String]?
    /// Networks for television, production companies for film.
    public var studios: [String]?
    /// ISO 639-1 of the language it was made in, which is not the language it
    /// was fetched in.
    public var originalLanguage: String?
    /// ISO 3166-1 of where it was made. `JP` plus animation is the oldest anime
    /// heuristic there is.
    public var originCountries: [String]?
    public var franchise: Franchise?
    /// `Returning Series`, `Ended`, `Released`, as the provider spells it.
    public var status: String?
    /// When the next episode airs, for a series still running.
    public var nextEpisodeAirDate: Date?
    public var lastEpisodeAirDate: Date?
    /// Names to search by, this provider's preferred order first.
    public var searchNames: [String]

    public init(
        ids: Identifiers = .init(),
        kind: Kind? = nil,
        title: String? = nil,
        originalTitle: String? = nil,
        overview: String? = nil,
        releaseDate: Date? = nil,
        runtimeMinutes: Int? = nil,
        episodeCount: Int? = nil,
        genres: [String]? = nil,
        rating: Double? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        isAnime: Bool? = nil,
        contentRating: String? = nil,
        trailerYouTubeID: String? = nil,
        cast: [CastMember]? = nil,
        ratings: [Rating]? = nil,
        watchOptions: [WatchOption]? = nil,
        keywords: [String]? = nil,
        studios: [String]? = nil,
        originalLanguage: String? = nil,
        originCountries: [String]? = nil,
        franchise: Franchise? = nil,
        status: String? = nil,
        nextEpisodeAirDate: Date? = nil,
        lastEpisodeAirDate: Date? = nil,
        searchNames: [String] = []
    ) {
        self.ids = ids
        self.kind = kind
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.releaseDate = releaseDate
        self.runtimeMinutes = runtimeMinutes
        self.episodeCount = episodeCount
        self.genres = genres
        self.rating = rating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.isAnime = isAnime
        self.contentRating = contentRating
        self.trailerYouTubeID = trailerYouTubeID
        self.cast = cast
        self.ratings = ratings
        self.watchOptions = watchOptions
        self.keywords = keywords
        self.studios = studios
        self.originalLanguage = originalLanguage
        self.originCountries = originCountries
        self.franchise = franchise
        self.status = status
        self.nextEpisodeAirDate = nextEpisodeAirDate
        self.lastEpisodeAirDate = lastEpisodeAirDate
        self.searchNames = searchNames
    }
}

public protocol MetadataProvider: Sendable {
    var provider: Provider { get }
    /// `nil` means "no match", which is not a failure — AniList returns `nil`
    /// for every western title.
    func snapshot(for lookup: Lookup) async throws -> Snapshot?
}

extension Array where Element == String {
    /// Names, trimmed, blanks dropped, case-insensitively deduplicated, **order
    /// kept**.
    ///
    /// Both halves are claims about *names*, not about any destination they are
    /// sent to — which is what makes this safe to publish. Capitalisation does
    /// not make a different title: `BLEACH` and `Bleach` name one work, so the
    /// list holds it once. And the order a caller gave is information the caller
    /// owns — a romaji-first list is asserting which name is likeliest, so the
    /// first spelling of a repeat survives and the order is never rearranged.
    ///
    /// A destination with its *own* rule — a search that folds case, an index
    /// that ignores punctuation — needs its own fold at its own boundary. That
    /// one is a fact about the transport and does not belong here, and a package
    /// should not skip it on the grounds that its callers were careful.
    ///
    /// Worth having wherever a repeated name costs something: for a film whose
    /// title and original title match, which is every film in its own language,
    /// the naive list contains a duplicate.
    public var deduplicatedNames: [String] {
        var seen: Set<String> = []
        return compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}
