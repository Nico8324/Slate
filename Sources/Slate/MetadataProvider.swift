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
        self.query = query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.year = year
        self.kind = kind
        self.season = season
    }

    func validate() throws {
        guard ids == ids.validated,
              year.map({ (1...9999).contains($0) }) ?? true,
              season.map({ $0 >= 0 }) ?? true else { throw SlateError.invalidLookup }
    }

    /// The id path.
    ///
    /// AniList cannot answer an IMDb id itself — it numbers the work, not the
    /// broadcast. It is reached anyway *if* ``AnimeIDBridge`` is in the
    /// aggregator's providers: the bridge turns the id into an AniList id and
    /// ``MetadataAggregator/metadata(for:)`` asks again in a later round, so the
    /// romaji names arrive from an id alone.
    ///
    /// Without the bridge wired, this path reaches TMDB and not AniList, and a
    /// result's ``TitleMetadata/searchNames`` will be TMDB's two names with no
    /// romaji among them. ``Lookup/init(search:year:kind:)`` reaches every
    /// provider unaided and is the safer default when a title is at hand.
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
    /// A calendar day, stored as **midnight UTC** of that day — providers give a
    /// date, not a moment. Format it with a UTC time zone; in the viewer's own,
    /// every zone west of UTC shows the day before.
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
    /// Directors, writers and creators. See ``CrewMember``.
    public var crew: [CrewMember]?
    /// Every trailer and clip the provider holds, in every language asked for.
    public var trailers: [Trailer]?
    /// Titles the provider suggests to someone who liked this one.
    public var recommendations: [Candidate]?
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
    /// Normalised across providers — see ``ReleaseStatus``.
    public var status: ReleaseStatus?
    /// Sequels, prequels, side stories. See ``Relation``.
    public var relations: [Relation]?
    /// When the next episode airs, for a series still running. AniList states
    /// the broadcast moment; TMDB only the day, as midnight UTC.
    public var nextEpisodeAirDate: Date?
    public var lastEpisodeAirDate: Date?
    /// Names to search by, this provider's preferred order first.
    public var searchNames: [String]
    /// Whether the provider matched a name only approximately. A loose match
    /// loses a conflict with a precise one, whatever the provider priority.
    var matchedLoosely = false

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
        crew: [CrewMember]? = nil,
        trailers: [Trailer]? = nil,
        recommendations: [Candidate]? = nil,
        ratings: [Rating]? = nil,
        watchOptions: [WatchOption]? = nil,
        keywords: [String]? = nil,
        studios: [String]? = nil,
        originalLanguage: String? = nil,
        originCountries: [String]? = nil,
        franchise: Franchise? = nil,
        status: ReleaseStatus? = nil,
        relations: [Relation]? = nil,
        nextEpisodeAirDate: Date? = nil,
        lastEpisodeAirDate: Date? = nil,
        searchNames: [String] = []
    ) {
        self.ids = ids.validated
        self.kind = kind
        self.title = title?.nilIfEmpty
        self.originalTitle = originalTitle?.nilIfEmpty
        self.overview = overview?.nilIfEmpty
        self.releaseDate = releaseDate
        self.runtimeMinutes = runtimeMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.episodeCount = episodeCount.flatMap { $0 > 0 ? $0 : nil }
        self.genres = genres?.deduplicatedNames.nilIfEmpty
        self.rating = rating.flatMap { $0.isFinite && (0...10).contains($0) ? $0 : nil }
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.isAnime = isAnime
        self.contentRating = contentRating?.nilIfEmpty
        self.trailerYouTubeID = trailerYouTubeID?.nilIfEmpty
        self.cast = cast?.mergedByPerson.nilIfEmpty
        self.crew = crew?.nilIfEmpty
        self.trailers = trailers?.nilIfEmpty
        self.recommendations = recommendations?.nilIfEmpty
        self.ratings = ratings
        self.watchOptions = watchOptions
        self.keywords = keywords?.deduplicatedNames.nilIfEmpty
        self.studios = studios?.deduplicatedNames.nilIfEmpty
        self.originalLanguage = originalLanguage?.nilIfEmpty
        self.originCountries = originCountries?.deduplicatedNames.nilIfEmpty
        self.franchise = franchise
        self.status = status
        self.relations = relations
        self.nextEpisodeAirDate = nextEpisodeAirDate
        self.lastEpisodeAirDate = lastEpisodeAirDate
        self.searchNames = searchNames.deduplicatedNames
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

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
