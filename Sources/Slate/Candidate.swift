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
    public let posterURL: URL?
    public let provider: Provider

    public var id: String { "\(provider.rawValue)-\(ids.tmdb ?? ids.aniList ?? 0)" }

    public init(
        ids: Identifiers, kind: Kind, title: String, year: Int? = nil,
        posterURL: URL? = nil, provider: Provider
    ) {
        self.ids = ids
        self.kind = kind
        self.title = title
        self.year = year
        self.posterURL = posterURL
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

    public init(
        id: Int, name: String, biography: String? = nil, birthday: Date? = nil,
        deathday: Date? = nil, profileURL: URL? = nil, department: String? = nil
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.profileURL = profileURL
        self.department = department
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
