import Foundation

/// One possible answer to a search, cheap enough to show a person a list of them.
///
/// ``MetadataAggregator/metadata(for:)`` picks one and hides the rest, which is
/// right when the title is unambiguous and useless when it is not: "Dragon Ball"
/// resolved to Dragon Ball Z for as long as nobody could see the alternatives.
public struct Candidate: Sendable, Equatable, Identifiable {
    public let ids: Identifiers
    public let kind: Kind
    public let title: String
    public let year: Int?
    /// The day it comes out, or came out, where the list gives it: midnight UTC. Announcements
    /// are often only a month or a year: then the first day of it, as ``releasePrecision`` says.
    public let releaseDate: Date?
    /// How much of ``releaseDate`` is known: `nil` without one, else `.day` unless the list says
    /// less — in practice only AniList's charts, whose announcements are often a month or a year.
    public let releasePrecision: DatePrecision?
    public let posterURL: URL?
    public let backdropURL: URL?
    /// ISO 639-1 of the language it was made in, where the list gives it.
    public let originalLanguage: String?
    /// The provider's genre ids — TMDB's, which ``TMDBProvider/genres(of:)`` names.
    public let genreIDs: [Int]
    /// TMDB's popularity score, where the list gives it.
    public let popularity: Double?
    public let provider: Provider

    /// With the kind: TMDB numbers films and shows separately, and a film and
    /// a show sharing a number in one search result had the same id.
    /// And the IMDb id where there is no TMDB one: list rows can carry only that,
    /// and every such row shared the id `…-0`.
    public var id: String {
        let key = ids.tmdb.map(String.init) ?? ids.imdb ?? ids.aniList.map(String.init) ?? "0"
        return "\(provider.rawValue)-\(kind.rawValue)-\(key)"
    }

    public init(
        ids: Identifiers, kind: Kind, title: String, year: Int? = nil, releaseDate: Date? = nil,
        releasePrecision: DatePrecision? = nil,
        posterURL: URL? = nil, backdropURL: URL? = nil, originalLanguage: String? = nil,
        genreIDs: [Int] = [], popularity: Double? = nil, provider: Provider
    ) {
        self.ids = ids
        self.kind = kind
        self.title = title
        self.year = year
        self.releaseDate = releaseDate
        self.releasePrecision = releaseDate == nil ? nil : releasePrecision ?? .day
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.originalLanguage = originalLanguage
        self.genreIDs = genreIDs
        self.popularity = popularity
        self.provider = provider
    }
}

/// Someone in front of or behind the camera.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let biography: String?
    public let birthday: Date?
    public let deathday: Date?
    public let profileURL: URL?
    /// `Acting`, `Directing`, `Writing` — what they are chiefly known for.
    public let department: String?
    /// TMDB's popularity score, from a search: namesakes share a name, not a score, so
    /// this is what tells the actor people mean from someone else called the same.
    public let popularity: Double?

    public init(
        id: Int, name: String, biography: String? = nil, birthday: Date? = nil,
        deathday: Date? = nil, profileURL: URL? = nil, department: String? = nil,
        popularity: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.profileURL = profileURL
        self.department = department
        self.popularity = popularity
    }
}

/// A ranked list TMDB publishes.
///
/// Not a ``Lookup``: there is no title being identified, no other provider that
/// could answer, and nothing to cross-reference. The ranking is TMDB's opinion
/// and calling it through ``TMDBProvider`` is how a caller says so.
public enum TitleList: Sendable, Hashable {
    case popularMovies, popularShows
    case topRatedMovies, topRatedShows
    case nowPlayingMovies, upcomingMovies
    case showsOnTheAir, showsAiringToday
    case trendingToday, trendingThisWeek

    var path: String {
        switch self {
        case .popularMovies: "/movie/popular"
        case .popularShows: "/tv/popular"
        case .topRatedMovies: "/movie/top_rated"
        case .topRatedShows: "/tv/top_rated"
        case .nowPlayingMovies: "/movie/now_playing"
        case .upcomingMovies: "/movie/upcoming"
        case .showsOnTheAir: "/tv/on_the_air"
        case .showsAiringToday: "/tv/airing_today"
        case .trendingToday: "/trending/all/day"
        case .trendingThisWeek: "/trending/all/week"
        }
    }

    /// A list of one kind needs no `media_type` in its rows; a trending list
    /// mixes both and states it per row.
    var kind: Kind? {
        switch self {
        case .popularMovies, .topRatedMovies, .nowPlayingMovies, .upcomingMovies: .movie
        case .popularShows, .topRatedShows, .showsOnTheAir, .showsAiringToday: .series
        case .trendingToday, .trendingThisWeek: nil
        }
    }
}

/// One of TMDB's genres, as ``TMDBProvider/genres(of:)`` lists them: an id to browse
/// with ``TMDBProvider/titles(inGenre:kind:page:)`` and its name in the provider's language.
public struct TMDBGenre: Sendable, Hashable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// How much of a date is known: an announcement may say only "October 2027", or "2027".
public enum DatePrecision: Int, Sendable, Hashable, Comparable {
    case year, month, day

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
