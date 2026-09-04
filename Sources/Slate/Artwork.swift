import Foundation

public enum ArtworkKind: String, Sendable, Hashable, Codable, CaseIterable {
    case poster
    case backdrop
    /// A transparent title treatment. TMDB holds these, so they cost no second
    /// credential.
    case logo
    /// An episode frame.
    case still
}

/// One image, with what is needed to choose between it and the forty others the
/// same show has.
public struct Artwork: Sendable, Equatable, Identifiable {
    public let kind: ArtworkKind
    public let url: URL
    /// ISO 639-1, or `nil` for an image with no text in it. `nil` is not missing
    /// data — it is the most useful kind of backdrop there is.
    public let language: String?
    public let width: Int?
    public let height: Int?
    /// The provider's own rating, where it has one.
    public let rating: Double?
    public let provider: Provider

    /// The size-agnostic part of the URL, when the provider serves the same
    /// image at several widths.
    private let sizingBase: String?
    private let path: String?

    public var id: URL { url }

    public init(
        kind: ArtworkKind, url: URL, language: String? = nil, width: Int? = nil,
        height: Int? = nil, rating: Double? = nil, provider: Provider,
        sizingBase: String? = nil, path: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.language = language
        self.width = width
        self.height = height
        self.rating = rating
        self.provider = provider
        self.sizingBase = sizingBase
        self.path = path
    }

    public var isTextless: Bool { language == nil }

    /// The same image at the smallest width the provider offers that is at least
    /// `width`, falling back to the original.
    ///
    /// A grid of posters at full size is several megabytes an item, which on a
    /// television is the difference between a list that scrolls and one that
    /// does not. Providers that serve only one size return it unchanged.
    public func sized(atLeast width: Int) -> URL {
        guard let sizingBase, let path else { return url }
        let available: [Int] = switch kind {
        case .poster: [92, 154, 185, 342, 500, 780]
        case .backdrop, .still: [300, 780, 1280]
        case .logo: [45, 92, 154, 185, 300, 500]
        }
        guard let fit = available.first(where: { $0 >= width }),
              let sized = URL(string: "\(sizingBase)/w\(fit)\(path)")
        else { return url }
        return sized
    }
}

/// Every image a title has, by kind, from every provider that answered.
///
/// Unsorted on purpose — ``best(_:preferring:)`` applies the choosing rules, and
/// a consumer offering the user a picker wants the whole list.
public struct ArtworkSet: Sendable, Equatable {
    public var posters: [Artwork]
    public var backdrops: [Artwork]
    public var logos: [Artwork]
    /// Providers that were asked and failed. The others still answered.
    public var failures: [Provider: String]

    public init(
        posters: [Artwork] = [], backdrops: [Artwork] = [], logos: [Artwork] = [],
        failures: [Provider: String] = [:]
    ) {
        self.posters = posters
        self.backdrops = backdrops
        self.logos = logos
        self.failures = failures
    }

    public var isEmpty: Bool { posters.isEmpty && backdrops.isEmpty && logos.isEmpty }

    public func all(_ kind: ArtworkKind) -> [Artwork] {
        switch kind {
        case .poster: posters
        case .backdrop, .still: backdrops
        case .logo: logos
        }
    }

    /// The one to show, given the languages a person reads.
    ///
    /// Posters are chosen for language and logos likewise — a title treatment in
    /// a script the viewer cannot read is worse than none. Backdrops invert it:
    /// a **textless** backdrop wins outright, because it is the one that can sit
    /// behind a title without two sets of words fighting each other.
    ///
    /// Within a tier, the provider's rating decides, then the larger image.
    public func best(_ kind: ArtworkKind, preferring languages: [String] = ["en"]) -> Artwork? {
        all(kind).min { lhs, rhs in
            let (l, r) = (tier(lhs, kind: kind, languages: languages),
                          tier(rhs, kind: kind, languages: languages))
            if l != r { return l < r }
            if lhs.rating != rhs.rating { return (lhs.rating ?? 0) > (rhs.rating ?? 0) }
            return (lhs.width ?? 0) > (rhs.width ?? 0)
        }
    }

    /// Lower sorts first.
    private func tier(_ artwork: Artwork, kind: ArtworkKind, languages: [String]) -> Int {
        if kind == .backdrop || kind == .still {
            return artwork.isTextless ? 0 : (languages.contains(artwork.language ?? "") ? 1 : 2)
        }
        if let language = artwork.language, let rank = languages.firstIndex(of: language) {
            return rank
        }
        // A textless poster is usable; one in a language nobody asked for is a
        // last resort.
        return artwork.isTextless ? languages.count : languages.count + 1
    }

    mutating func merge(_ other: ArtworkSet) {
        posters += other.posters
        backdrops += other.backdrops
        logos += other.logos
        failures.merge(other.failures) { first, _ in first }
    }
}

/// A provider that can also supply pictures.
///
/// Separate from ``MetadataProvider`` for the same reason ``SeasonProvider`` is:
/// it is another request, and a caller asking *what is this* should not pay for
/// forty image records it did not ask for.
public protocol ArtworkProvider: MetadataProvider {
    /// - Parameter nativeSeason: the **provider's own** season number, not one
    ///   from a corrected ``SeasonStructure``. Translate first with
    ///   ``SeasonStructure/nativeSeason(ofSeason:)``: Bleach's arc season 2 lives
    ///   inside TMDB's season 1, and passing 2 straight through returns the
    ///   posters for Thousand-Year Blood War.
    func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int?) async throws -> ArtworkSet?
}
