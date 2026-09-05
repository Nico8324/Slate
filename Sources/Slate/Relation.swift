import Foundation

/// How one title relates to another.
///
/// The reason anime needs this and western television does not: a second season
/// is frequently a *separate work* with its own id, its own episode numbering
/// starting at one, and no season number anywhere. `Shingeki no Kyojin Season 2`
/// is not season 2 of anything as far as its own record is concerned — the only
/// thing tying it to the first is a sequel edge.
public struct Relation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case sequel, prequel
        case sideStory, spinOff, alternative, summary, compilation
        /// The work this was adapted from, or that was adapted from it.
        case adaptation, source
        case parent, contains, character
        case other

        init(providerValue: String) {
            self = switch providerValue.uppercased() {
            case "SEQUEL": .sequel
            case "PREQUEL": .prequel
            case "SIDE_STORY": .sideStory
            case "SPIN_OFF": .spinOff
            case "ALTERNATIVE": .alternative
            case "SUMMARY": .summary
            case "COMPILATION": .compilation
            case "ADAPTATION": .adaptation
            case "SOURCE": .source
            case "PARENT": .parent
            case "CONTAINS": .contains
            case "CHARACTER": .character
            default: .other
            }
        }
    }

    public let kind: Kind
    public let ids: Identifiers
    public let title: String
    /// `TV`, `MOVIE`, `OVA`, `MANGA` — as the provider names it. A relation to a
    /// manga is not something a video library can play, and this is how to tell.
    public let format: String?

    public var id: String { "\(kind.rawValue)-\(ids.aniList ?? ids.myAnimeList ?? 0)" }

    public init(kind: Kind, ids: Identifiers, title: String, format: String? = nil) {
        self.kind = kind
        self.ids = ids
        self.title = title
        self.format = format
    }

    /// Whether this is something a video library could hold. Manga, novels and
    /// one-shots are related works, not watchable ones.
    public var isWatchable: Bool {
        guard let format else { return true }
        return !["MANGA", "NOVEL", "ONE_SHOT", "MUSIC"].contains(format.uppercased())
    }
}

/// Where a title is in its life, in one vocabulary.
///
/// Providers each have their own words — TMDB says `Returning Series` and
/// `Ended`, AniList says `RELEASING` and `FINISHED` — and a consumer comparing
/// two providers' answers should not have to know both.
public enum ReleaseStatus: String, Sendable, Hashable {
    /// A film that has come out.
    case released
    /// A series that has finished airing.
    case ended
    /// Currently airing.
    case airing
    /// Announced, not yet out.
    case upcoming
    case cancelled
    case hiatus

    init?(providerValue: String) {
        switch providerValue.uppercased() {
        case "RELEASED": self = .released
        case "ENDED", "FINISHED": self = .ended
        case "RETURNING SERIES", "RELEASING": self = .airing
        case "PLANNED", "IN PRODUCTION", "POST PRODUCTION", "PILOT", "RUMORED",
             "NOT_YET_RELEASED": self = .upcoming
        case "CANCELED", "CANCELLED": self = .cancelled
        case "HIATUS": self = .hiatus
        default: return nil
        }
    }
}
