import Foundation

/// A chart MDBList publishes. Each holds films and shows; ask for one kind.
public enum OfficialList: String, Sendable, Hashable, CaseIterable {
    /// Being watched right now.
    case trending
    /// Most watched and best rated.
    case popular
    /// Most watched, all time and this week.
    case mostWatched = "most-watched"
    case mostWatchedThisWeek = "most-watched-week"
    /// Most anticipated, not out yet.
    case anticipated
    /// IMDb's MOVIEmeter: what people are looking up on IMDb.
    case imdbMovieMeter = "moviemeter"
    /// What is being streamed most, from JustWatch.
    case streamingCharts = "justwatch-streaming-charts"
}

/// One page of a list, and where the next one starts.
public struct ListPage: Sendable, Equatable {
    public let titles: [Candidate]
    /// Pass to the next call for the following page; `nil` on the last page.
    public let nextCursor: String?

    public init(titles: [Candidate], nextCursor: String? = nil) {
        self.titles = titles
        self.nextCursor = nextCursor
    }
}
