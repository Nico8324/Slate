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
