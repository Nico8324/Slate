import Foundation

/// Someone in the credits.
public struct CastMember: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// Who they play. Television credits aggregate several roles across a run;
    /// this is the one they are most billed for.
    public let character: String?
    public let profileURL: URL?
    /// Billing order, lowest first, as the provider gives it.
    public let order: Int?

    public init(id: Int, name: String, character: String? = nil, profileURL: URL? = nil, order: Int? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.order = order
    }
}

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

/// A provider that can list what a search might have meant.
public protocol CandidateProvider: MetadataProvider {
    func candidates(for query: String, kind: Kind?) async throws -> [Candidate]
}
