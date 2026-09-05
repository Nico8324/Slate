import Foundation

/// Where a title can be watched, in one region, by one means.
///
/// Region-scoped because availability is not a fact about a title — it is a fact
/// about a title *and a country*, and a service that carries something in the US
/// frequently does not in France.
public struct WatchOption: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Included with a subscription.
        case subscription
        case rent
        case buy
        /// Free, with advertising.
        case ads
        /// Free, without.
        case free
    }

    public let service: String
    public let kind: Kind
    /// ISO 3166-1.
    public let region: String
    public let logoURL: URL?
    /// The provider's own page for this title in this region, where one exists.
    public let link: URL?

    public var id: String { "\(region)-\(kind.rawValue)-\(service)" }

    public init(
        service: String, kind: Kind, region: String, logoURL: URL? = nil, link: URL? = nil
    ) {
        self.service = service
        self.kind = kind
        self.region = region
        self.logoURL = logoURL
        self.link = link
    }
}

/// The series a title belongs to — *The Matrix Collection*, *Alien Collection*.
///
/// What a library groups by when a person thinks "the Alien films" rather than
/// "films whose title starts with Alien".
public struct Franchise: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let posterURL: URL?
    public let backdropURL: URL?

    public init(id: Int, name: String, posterURL: URL? = nil, backdropURL: URL? = nil) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.backdropURL = backdropURL
    }
}
