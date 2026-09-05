import Foundation

/// A metadata source. Every value Slate returns is attributed to one of these.
public enum Provider: String, Sendable, Hashable {
    /// The IMDb id, western movies and television, art, ratings.
    case tmdb
    /// Anime: whether a title is one at all, its romaji and native names,
    /// episode counts.
    case aniList
    /// Cross-referenced scores — IMDb, Metacritic, the tomatometer, Letterboxd,
    /// MyAnimeList — which no single provider holds.
    case mdbList
}

/// A single value, and the provider that supplied it.
public struct Attributed<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let provider: Provider

    public init(_ value: Value, from provider: Provider) {
        self.value = value
        self.provider = provider
    }
}

/// Every provider's answer for one field, ordered by provider priority.
///
/// Slate does not merge. A field holds what each provider said, so the consumer
/// can decide per field — which is what makes a per-field hand-edit survive a
/// refresh from a different source.
public struct Field<Value: Sendable & Equatable>: Sendable, Equatable {
    public private(set) var candidates: [Attributed<Value>]

    public init(_ candidates: [Attributed<Value>] = []) {
        self.candidates = candidates
    }

    /// The highest-priority answer, or `nil` if no provider supplied this field.
    public var best: Value? { candidates.first?.value }

    /// The provider behind ``best``.
    public var bestProvider: Provider? { candidates.first?.provider }

    public var isEmpty: Bool { candidates.isEmpty }


    /// What one specific provider said, whatever the priority order.
    public func value(from provider: Provider) -> Value? {
        candidates.first { $0.provider == provider }?.value
    }

    mutating func append(_ value: Value?, from provider: Provider) {
        guard let value else { return }
        candidates.append(Attributed(value, from: provider))
    }
}
