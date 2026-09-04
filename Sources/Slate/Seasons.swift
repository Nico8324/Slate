import Foundation

/// Where an episode sits, in whichever numbering is being talked about.
public struct EpisodePosition: Sendable, Hashable {
    public let season: Int
    public let episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }
}

public struct Episode: Sendable, Equatable, Identifiable {
    /// The season this episode is shown under, in ``SeasonStructure/ordering``.
    public var season: Int
    /// 1-based within that season.
    public var number: Int
    public var title: String?
    public var airDate: Date?
    public var tmdbID: Int?
    /// The frame a provider uses to illustrate this episode.
    public var stillURL: URL?
    /// Where the provider files this episode in its *own* numbering, when that
    /// differs from the season structure being presented. Stated by the API,
    /// never inferred — which is what makes the two views translatable.
    public var native: EpisodePosition?

    public var id: EpisodePosition { EpisodePosition(season: season, episode: number) }

    public init(
        season: Int, number: Int, title: String? = nil, airDate: Date? = nil,
        tmdbID: Int? = nil, stillURL: URL? = nil, native: EpisodePosition? = nil
    ) {
        self.season = season
        self.number = number
        self.title = title
        self.airDate = airDate
        self.tmdbID = tmdbID
        self.stillURL = stillURL
        self.native = native
    }
}

public struct Season: Sendable, Equatable, Identifiable {
    /// 1-based. Specials keep `0`.
    public var number: Int
    /// The arc's own name where one exists — "The Entry", "Lost Agent Arc".
    public var name: String?
    public var episodeCount: Int
    /// `nil` means *not loaded*, which is different from a season with no
    /// episodes. The episode-group path fills this for free; the ordinary path
    /// leaves it nil until someone asks for one season.
    public var episodes: [Episode]?

    public var id: Int { number }

    public init(number: Int, name: String? = nil, episodeCount: Int, episodes: [Episode]? = nil) {
        self.number = number
        self.name = name
        self.episodeCount = episodeCount
        self.episodes = episodes
    }
}

/// The seasons a series should be filed and shown by — which is not always the
/// ones its metadata provider files it under.
///
/// TMDB has Bleach as one season of 366 episodes and Detective Conan as one of
/// 1212. Nothing else in the world numbers them that way: Wikipedia, TheTVDB and
/// the groups that name the releases all count arcs. A library filed the flat way
/// lines up with nothing a person reads, searches for, or downloads.
///
/// The correction comes from the provider itself — TMDB's `episode_groups`, where
/// the community keeps the orderings TMDB's own numbering isn't. See
/// ``Ordering/episodeGroup(name:)``.
public struct SeasonStructure: Sendable, Equatable {
    /// How these seasons were arrived at, so a consumer can tell a correction
    /// from the ordinary case — and say so in a UI if it wants to.
    public enum Ordering: Sendable, Equatable {
        /// The provider's own seasons, used as-is. The ordinary case.
        case native
        /// An alternate ordering, named as the provider names it.
        case episodeGroup(name: String)
    }

    /// Whether absolute episode numbers are *stated* by the provider or worked
    /// out by walking season lengths.
    ///
    /// The difference matters. A derived reading is a reading: season boundaries
    /// are a database's opinion, a release group's are the broadcaster's, and
    /// long-running shows disagree with both. Keep the number the filename gave.
    public enum AbsoluteNumbering: Sendable, Equatable {
        case stated
        case derived
    }

    public let seasons: [Season]
    public let ordering: Ordering
    public let absoluteNumbering: AbsoluteNumbering
    public let provider: Provider

    /// The provider's own seasons, kept for translation even when ``ordering``
    /// presents different ones.
    public let nativeSeasons: [Season]

    private let toNative: [EpisodePosition: EpisodePosition]
    private let fromNative: [EpisodePosition: EpisodePosition]

    /// Seasons exactly as the provider files them.
    public init(nativeSeasons: [Season], provider: Provider) {
        self.seasons = nativeSeasons
        self.nativeSeasons = nativeSeasons
        self.ordering = .native
        self.absoluteNumbering = .derived
        self.provider = provider
        self.toNative = [:]
        self.fromNative = [:]
    }

    /// Seasons taken from an alternate ordering, with the provider's own kept
    /// alongside so the two can be translated.
    public init(
        seasons: [Season], orderingName: String, nativeSeasons: [Season], provider: Provider
    ) {
        var toNative: [EpisodePosition: EpisodePosition] = [:]
        var fromNative: [EpisodePosition: EpisodePosition] = [:]
        for season in seasons {
            for episode in season.episodes ?? [] {
                guard let native = episode.native else { continue }
                let shown = EpisodePosition(season: season.number, episode: episode.number)
                // First writing wins. An ordering that lists the same episode
                // twice — recaps and compilation entries do turn up — must not
                // have its earlier, likelier mapping overwritten by the later.
                if toNative[shown] == nil { toNative[shown] = native }
                if fromNative[native] == nil { fromNative[native] = shown }
            }
        }
        self.seasons = seasons
        self.nativeSeasons = nativeSeasons
        self.ordering = .episodeGroup(name: orderingName)
        self.absoluteNumbering = .stated
        self.provider = provider
        self.toNative = toNative
        self.fromNative = fromNative
    }

    /// Seasons a person is shown, specials excluded.
    public var numberedSeasons: [Season] {
        seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number }
    }

    /// Where the provider files an episode this structure shows at
    /// `season`/`episode`, or `nil` when the ordering doesn't account for it.
    public func nativePosition(ofSeason season: Int, episode: Int) -> EpisodePosition? {
        toNative[EpisodePosition(season: season, episode: episode)]
    }

    /// The reverse: where an episode the provider files at `season`/`episode` is
    /// shown here.
    public func position(ofNativeSeason season: Int, episode: Int) -> EpisodePosition? {
        fromNative[EpisodePosition(season: season, episode: episode)]
    }

    /// The provider's episode numbers one shown season covers, when they are
    /// contiguous inside one of the provider's seasons.
    ///
    /// Contiguous is the ordinary case and the useful one: Bleach's second arc is
    /// TMDB S1 E21–41, and a bounded range is exactly what an acquisition can ask
    /// an indexer for instead of matching a complete-series pack. An ordering that
    /// jumps around returns `nil` rather than a range quietly covering episodes it
    /// does not hold.
    public func nativeRange(ofSeason season: Int) -> (season: Int, episodes: ClosedRange<Int>)? {
        guard let entry = seasons.first(where: { $0.number == season }), entry.episodeCount > 0 else {
            return nil
        }
        let positions = (1...entry.episodeCount).compactMap { nativePosition(ofSeason: season, episode: $0) }
        guard positions.count == entry.episodeCount, let first = positions.first,
              positions.allSatisfy({ $0.season == first.season })
        else { return nil }

        let numbers = positions.map(\.episode).sorted()
        guard let low = numbers.first, let high = numbers.last, high - low + 1 == numbers.count
        else { return nil }
        return (first.season, low...high)
    }

    /// Which of the provider's own seasons a shown season lives in.
    ///
    /// Needed wherever a number is handed back to the provider — its artwork
    /// endpoints, for one. Bleach's arc season 2 is inside TMDB's season 1, and
    /// asking TMDB for "season 2" gets the posters for Thousand-Year Blood War
    /// instead: a real picture, of the wrong thing, with nothing to indicate it.
    ///
    /// `nil` when the ordering does not account for that season.
    public func nativeSeason(ofSeason season: Int) -> Int? {
        if case .native = ordering { return season }
        return nativeRange(ofSeason: season)?.season
            ?? nativePosition(ofSeason: season, episode: 1)?.season
    }

    /// Turning `Bleach - 340` into the season and episode it is shown under.
    ///
    /// Anime is numbered straight through its whole run: a filename says `12` and
    /// nothing about a season, because the people who made it don't think in
    /// seasons. Walking and subtracting rather than a formula — seasons are not
    /// the same length and split cours are common.
    ///
    /// Running off the end is left unmapped rather than clamped to the last
    /// season. A number past the final episode means the season list is
    /// incomplete, the show was matched wrongly, or the filename was never
    /// absolute — and filing it somewhere plausible hides that instead of showing
    /// it. Keep the number the filename gave; this reading can be redone.
    public func position(ofAbsolute absolute: Int) -> EpisodePosition? {
        guard absolute > 0 else { return nil }
        var remaining = absolute
        for season in numberedSeasons where season.episodeCount > 0 {
            if remaining <= season.episodeCount {
                return EpisodePosition(season: season.number, episode: remaining)
            }
            remaining -= season.episodeCount
        }
        return nil
    }
}
