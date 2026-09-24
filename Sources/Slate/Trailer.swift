import Foundation

/// A video about a title — a trailer, a teaser, a clip — hosted on YouTube.
///
/// A title has several: TMDB holds *The Housemaid*'s three Lionsgate trailers in
/// English and four from its French distributor, dubbed and subtitled. Which one
/// is right depends on who is watching, so Slate returns all of them and
/// ``Swift/Array/best(preferring:)`` chooses — the same shape as ``ArtworkSet``.
public struct Trailer: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case trailer, teaser, clip, featurette, behindTheScenes, other
    }

    /// Which version a viewer wants.
    public enum Version: String, Sendable, Hashable, CaseIterable, Codable {
        /// The studio's own, in the title's language.
        case original
        /// Original audio with subtitles in the viewer's language.
        case subtitled
        /// Dubbed into the viewer's language.
        case dubbed
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

    /// Whether ``name`` says it is subtitled (`VOSTFR`, `sous-titré`, `Subtitled`).
    /// Providers tag a subtitled trailer and a dub with the same language.
    public var isSubtitled: Bool {
        let name = name?.lowercased() ?? ""
        return ["vost", "sous-titr", "subtitled"].contains { name.contains($0) }
    }

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
            return Self.before(lhs, rhs)
        }
    }

    /// The one to play in `version`, falling back to the closest one there is.
    ///
    /// The original is in `originalLanguage` (English when unknown), else English.
    /// Subtitled and dubbed are in the `viewer`'s language, told apart by
    /// ``Trailer/isSubtitled``; a viewer whose language is the original's gets the
    /// original. Subtitled falls back to the original; dubbed to subtitled, then
    /// the original. Within each, a trailer beats a teaser, official beats not,
    /// and the newest wins.
    ///
    /// - Parameters:
    ///   - originalLanguage: ISO 639-1 of the title, such as ``Snapshot/originalLanguage``.
    ///   - viewer: ISO 639-1 or a full tag (`fr`, `fr-FR`).
    public func best(version: Trailer.Version, originalLanguage: String?, viewer: String) -> Trailer? {
        func rank(_ trailer: Trailer) -> Int { trailer.kind == .trailer ? 0 : trailer.kind == .teaser ? 1 : 2 }
        let ranked = sorted { lhs, rhs in rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : Self.before(lhs, rhs) }
        let viewer = viewer.split(separator: "-").first.map { String($0).lowercased() } ?? viewer
        let original = ranked.first { $0.language == (originalLanguage ?? "en") } ?? ranked.first { $0.language == "en" }
        let local = ranked.filter { $0.language == viewer && viewer != originalLanguage }
        let subtitled = local.first(where: \.isSubtitled)
        let dubbed = local.first { !$0.isSubtitled }
        let pick: Trailer? = switch version {
        case .original: original
        case .subtitled: subtitled ?? original
        case .dubbed: dubbed ?? subtitled ?? original
        }
        return pick ?? ranked.first
    }

    /// Official first, then the newest; the id settles the rest so every call agrees.
    private static func before(_ lhs: Trailer, _ rhs: Trailer) -> Bool {
        if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial }
        let (l, r) = (lhs.publishedAt ?? .distantPast, rhs.publishedAt ?? .distantPast)
        if l != r { return l > r }
        return lhs.youTubeID < rhs.youTubeID
    }
}
