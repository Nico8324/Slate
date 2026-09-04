import Foundation

/// What a title is. Slate deliberately knows only these two shapes; season and
/// episode ordering stay with whoever owns the library.
public enum Kind: String, Sendable, Hashable, Codable {
    case movie
    case series
}

/// Cross-provider identifiers for one title.
public struct Identifiers: Sendable, Hashable, Codable {
    public var imdb: String?
    public var tmdb: Int?
    public var aniList: Int?
    public var myAnimeList: Int?

    public init(imdb: String? = nil, tmdb: Int? = nil, aniList: Int? = nil, myAnimeList: Int? = nil) {
        self.imdb = imdb
        self.tmdb = tmdb
        self.aniList = aniList
        self.myAnimeList = myAnimeList
    }

    var isEmpty: Bool { imdb == nil && tmdb == nil && aniList == nil && myAnimeList == nil }

    mutating func fill(from other: Identifiers) {
        imdb = imdb ?? other.imdb
        tmdb = tmdb ?? other.tmdb
        aniList = aniList ?? other.aniList
        myAnimeList = myAnimeList ?? other.myAnimeList
    }
}

/// One metadata field, addressable without knowing its type.
///
/// Exists so a consumer can express a policy over *fields* — "was this one
/// hand-edited", "this one is machine-owned and always refreshes" — as a loop
/// rather than as a dozen hand-written branches that drift apart. Slate decides
/// which provider wins a field; whether a human outranks that decision is the
/// consumer's call, and this is what makes it writable.
public enum FieldKey: String, Sendable, Hashable, Codable, CaseIterable {
    case kind, title, originalTitle, overview, releaseDate, runtimeMinutes
    case episodeCount, genres, rating, posterURL, backdropURL, isAnime
}

/// The aggregated answer for one title: every field carries every provider's
/// value, not a merged one.
public struct TitleMetadata: Sendable, Equatable {
    public var ids: Identifiers
    public var kind: Field<Kind>
    public var title: Field<String>
    public var originalTitle: Field<String>
    public var overview: Field<String>
    public var releaseDate: Field<Date>
    public var runtimeMinutes: Field<Int>
    public var episodeCount: Field<Int>
    public var genres: Field<[String]>
    /// Normalised to a 0...10 scale, whatever the provider's native scale.
    public var rating: Field<Double>
    public var posterURL: Field<URL>
    public var backdropURL: Field<URL>
    public var isAnime: Field<Bool>

    /// Every name this title is known by, highest-priority provider first and
    /// deduplicated — romaji ahead of English for anime, because that is what a
    /// release group names a file.
    public var searchNames: [String]

    /// Providers that were asked and failed, by description. A failure here is
    /// not an error: the other providers still answered.
    public var failures: [Provider: String]

    public init(
        ids: Identifiers = .init(),
        kind: Field<Kind> = .init(),
        title: Field<String> = .init(),
        originalTitle: Field<String> = .init(),
        overview: Field<String> = .init(),
        releaseDate: Field<Date> = .init(),
        runtimeMinutes: Field<Int> = .init(),
        episodeCount: Field<Int> = .init(),
        genres: Field<[String]> = .init(),
        rating: Field<Double> = .init(),
        posterURL: Field<URL> = .init(),
        backdropURL: Field<URL> = .init(),
        isAnime: Field<Bool> = .init(),
        searchNames: [String] = [],
        failures: [Provider: String] = [:]
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
        self.failures = failures
    }
}

/// What an acquisition layer needs from Slate: an id, a shape, and the names to
/// search by. Mirrors `Resolvers.ResolveRequest` without depending on it.
public struct ResolveInput: Sendable, Hashable {
    public var imdbID: String
    public var kind: Kind
    public var searchNames: [String]

    public init(imdbID: String, kind: Kind, searchNames: [String]) {
        self.imdbID = imdbID
        self.kind = kind
        self.searchNames = searchNames
    }
}

extension TitleMetadata {
    /// Which provider won each field. A field no provider answered is absent.
    public var provenance: [FieldKey: Provider] {
        var result: [FieldKey: Provider] = [:]
        for key in FieldKey.allCases {
            result[key] = provider(of: key)
        }
        return result
    }

    /// The provider behind this field's winning value.
    public func provider(of key: FieldKey) -> Provider? {
        providersConsulted(for: key).first
    }

    /// Every provider that answered this field, winner first.
    public func providersConsulted(for key: FieldKey) -> [Provider] {
        switch key {
        case .kind: kind.candidates.map(\.provider)
        case .title: title.candidates.map(\.provider)
        case .originalTitle: originalTitle.candidates.map(\.provider)
        case .overview: overview.candidates.map(\.provider)
        case .releaseDate: releaseDate.candidates.map(\.provider)
        case .runtimeMinutes: runtimeMinutes.candidates.map(\.provider)
        case .episodeCount: episodeCount.candidates.map(\.provider)
        case .genres: genres.candidates.map(\.provider)
        case .rating: rating.candidates.map(\.provider)
        case .posterURL: posterURL.candidates.map(\.provider)
        case .backdropURL: backdropURL.candidates.map(\.provider)
        case .isAnime: isAnime.candidates.map(\.provider)
        }
    }

    /// `nil` when no provider supplied an IMDb id or a kind — a resolver cannot
    /// use the result without both.
    public var resolveInput: ResolveInput? {
        guard let imdbID = ids.imdb, let kind = kind.best else { return nil }
        return ResolveInput(imdbID: imdbID, kind: kind, searchNames: searchNames)
    }
}
