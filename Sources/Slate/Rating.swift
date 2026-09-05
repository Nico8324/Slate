import Foundation

/// One site's score for a title.
///
/// Kept per source rather than averaged. An average of IMDb, Metacritic and a
/// tomatometer is a number no site would recognise, and the reason a person
/// wants ratings at all is usually that they trust one of them.
public struct Rating: Sendable, Equatable, Identifiable {
    /// As the aggregator names it: `imdb`, `metacritic`, `tomatoes`,
    /// `tomatoesaudience`, `letterboxd`, `myanimelist`, `trakt`, `tmdb`,
    /// `rogerebert`.
    public let source: String
    /// Normalised to 0...10 whatever the site's native scale, so two sources are
    /// comparable without the caller knowing that Metacritic is out of 100 and
    /// Letterboxd out of 5.
    public let value: Double
    /// The site's own scale, kept because "7.4 out of 10" and "74%" read
    /// differently to a person even when they are the same number.
    public let outOf: Double
    public let votes: Int?

    public var id: String { source }

    public init(source: String, value: Double, outOf: Double = 10, votes: Int? = nil) {
        self.source = source
        self.value = value
        self.outOf = outOf
        self.votes = votes
    }

    /// The score as the site itself would print it.
    public var native: Double { value / 10 * outOf }
}
