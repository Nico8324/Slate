import Foundation

/// What to look a title up by. A provider uses whichever parts it understands
/// and returns `nil` when it has nothing to go on.
public struct Lookup: Sendable, Hashable {
    public var ids: Identifiers
    public var query: String?
    public var year: Int?
    public var kind: Kind?

    public init(ids: Identifiers = .init(), query: String? = nil, year: Int? = nil, kind: Kind? = nil) {
        self.ids = ids
        self.query = query
        self.year = year
        self.kind = kind
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
        self.searchNames = searchNames
    }
}

public protocol MetadataProvider: Sendable {
    var provider: Provider { get }
    /// `nil` means "no match", which is not a failure — AniList returns `nil`
    /// for every western title.
    func snapshot(for lookup: Lookup) async throws -> Snapshot?
}
