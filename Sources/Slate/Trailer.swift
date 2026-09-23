import Foundation

/// A video about a title — a trailer, a teaser, a clip — hosted on YouTube.
///
/// A title has several: TMDB holds *The Housemaid*'s three Lionsgate trailers in
/// English and four from its French distributor, dubbed and subtitled. Which one
/// is right depends on who is watching, so Slate returns all of them and
/// ``Swift/Array/best(preferring:)`` chooses — the same shape as ``ArtworkSet``.
public struct Trailer: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case trailer, teaser, clip, featurette, behindTheScenes, other
    }

    /// The YouTube video id — what a player wants, not a URL.
    public let youTubeID: String
    /// As published: `Official Trailer 2`, `Bande-annonce n°1 (VF)`.
    public let name: String?
    public let kind: Kind
    /// ISO 639-1 of the audio or the subtitles, as the provider tags it. A
    /// dubbed trailer and a subtitled one are both tagged with the language of
    /// the country they were made for; ``name`` is often the only way to tell.
    public let language: String?
    /// ISO 3166-1 of the market it was made for.
    public let region: String?
    /// The provider's own flag. Regional distributors rarely get it, so a
    /// missing flag is not evidence of a fan upload.
    public let isOfficial: Bool
    public let publishedAt: Date?

    public var id: String { youTubeID }

    public init(
        youTubeID: String, name: String? = nil, kind: Kind, language: String? = nil,
        region: String? = nil, isOfficial: Bool = false, publishedAt: Date? = nil
    ) {
        self.youTubeID = youTubeID
        self.name = name
        self.kind = kind
        self.language = language
        self.region = region
        self.isOfficial = isOfficial
        self.publishedAt = publishedAt
    }
}

extension Array where Element == Trailer {
    /// The one to play.
    ///
    /// In order: a trailer over a teaser over anything else; then the first
    /// language in `languages` that has one, and an untagged video after every
    /// listed language; then official over not; then the newest, which settles
    /// ties the same way on every call instead of by whatever order the API
    /// happened to list them in.
    ///
    /// - Parameter languages: ISO 639-1 codes or full tags (`fr`, `fr-FR`),
    ///   most wanted first. Pass the original language first for the original
    ///   version, the viewer's first for a dubbed or subtitled one.
    public func best(preferring languages: [String] = []) -> Trailer? {
        let wanted = languages.map { $0.split(separator: "-").first.map { String($0).lowercased() } ?? "" }
        func kindRank(_ trailer: Trailer) -> Int {
            switch trailer.kind {
            case .trailer: 0
            case .teaser: 1
            default: 2
            }
        }
        func languageRank(_ trailer: Trailer) -> Int {
            guard let language = trailer.language?.lowercased() else { return wanted.count }
            return wanted.firstIndex(of: language) ?? wanted.count + 1
        }
        return self.min { lhs, rhs in
            if kindRank(lhs) != kindRank(rhs) { return kindRank(lhs) < kindRank(rhs) }
            if languageRank(lhs) != languageRank(rhs) { return languageRank(lhs) < languageRank(rhs) }
            if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial }
            let (l, r) = (lhs.publishedAt ?? .distantPast, rhs.publishedAt ?? .distantPast)
            if l != r { return l > r }
            return lhs.youTubeID < rhs.youTubeID
        }
    }
}
