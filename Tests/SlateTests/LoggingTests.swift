import Foundation
import Testing
@testable import Slate

/// The logging added in 0.11.0 is mostly unassertable — `os.Logger` writes to
/// the system log, not to anything a test can read. What *is* assertable is the
/// part that would be a security bug rather than a verbosity one: the helper
/// every log line routes a URL through.
@Suite struct LoggingTests {

    @Test func aLoggedURLNeverCarriesItsQuery() throws {
        // TMDB puts the search term in `?query=`, so a logged URL would write a
        // person's library into the system log one line at a time.
        let searched = try URL.build(TMDBProvider.api, path: "/search/tv",
                                     query: ["query": "Sousou no Frieren", "language": "en-US"])
        let logged = Log.redactingQuery(searched)

        #expect(logged == "https://api.themoviedb.org/3/search/tv")
        #expect(!logged.contains("Frieren"))
        #expect(!logged.contains("?"))
    }

    @Test func aCredentialInAQueryStringWouldNotSurviveEither() throws {
        // Slate sends keys as `Authorization: Bearer` and never in a query — but
        // MDBList also accepts `?apikey=`, and the helper must not be the thing
        // standing between that and the log if anyone ever reaches for it.
        let url = try #require(URL(string: "https://api.mdblist.com/tmdb/show/1429?apikey=SECRET-abc123"))
        let logged = Log.redactingQuery(url)

        #expect(!logged.contains("SECRET"))
        #expect(!logged.contains("apikey"))
        #expect(logged == "https://api.mdblist.com/tmdb/show/1429")
    }

    @Test func idsAreLoggableAndAQueryIsNot() {
        // What a lookup is *about* is a catalogue number; what was typed is the
        // person's. `describe` carries the first and only the presence of the
        // second.
        let byName = Lookup(search: "Attack on Titan", kind: .series)
        #expect(Log.describe(byName) == "no ids by name series")
        #expect(!Log.describe(byName).contains("Attack"))

        let byID = Lookup(ids: Identifiers(imdb: "tt2560140", tmdb: 1429), kind: .series)
        #expect(Log.describe(byID) == "tt2560140 tmdb:1429 series")
    }

    @Test func noLogLineInThePackageInterpolatesACredential() throws {
        // A grep, as a test. The privacy rules are a convention, and a
        // convention that nothing checks is one edit from being untrue —
        // `.private` redacts a line for a reader, it does not stop the string
        // being built.
        let sources = FileManager.default.enumerator(atPath: "Sources")?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") } ?? []
        #expect(!sources.isEmpty, "the source tree should be readable from the test working directory")

        for file in sources {
            let text = try String(contentsOfFile: "Sources/" + file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("Log.") && line.contains("\\(") {
                for forbidden in ["accessToken", "apiKey", "headers", "Bearer"] {
                    #expect(!line.contains(forbidden),
                            "\(file) interpolates \(forbidden) into a log line")
                }
            }
        }
    }
}

@Suite("Errors in log lines")
struct ErrorLoggingTests {
    /// The body is the hazard. `HTTP` never logs one; this is the path that
    /// used to, by way of `String(describing: error)` at `.public`.
    @Test func theResponseBodyNeverReachesALogLine() {
        let leaky = SlateError.http(status: 404, body: #"{"status_message":"no results for my private search"}"#)

        #expect(Log.describe(leaky) == "HTTP 404")
        #expect(!Log.describe(leaky).contains("private search"))
    }

    @Test func theOtherFailuresStillSayWhatHappened() {
        #expect(Log.describe(SlateError.rateLimited(retryAfter: 30)) == "rate limited, retry after 30s")
        #expect(Log.describe(SlateError.rateLimited(retryAfter: nil)) == "rate limited")
        #expect(Log.describe(SlateError.missingCredential(.tmdb)) == "tmdb credential refused")
        #expect(Log.describe(SlateError.malformedURL) == "malformed URL")
        #expect(Log.describe(CancellationError()) == "cancelled")
    }

    /// A coding path is about the payload's shape, not about the title — and it
    /// is the one thing that makes a 200-that-changed-shape diagnosable.
    @Test func aDecodeFailureSaysWhichFieldBroke() throws {
        struct Row: Decodable { let id: Int }
        let json = Data(#"{"id":"not a number"}"#.utf8)

        #expect(throws: (any Error).self) { try JSONDecoder().decode(Row.self, from: json) }
        do {
            _ = try JSONDecoder().decode(Row.self, from: json)
        } catch {
            #expect(Log.describe(error) == "decoding failed at id")
            #expect(!Log.describe(error).contains("not a number"), "never the value that failed")
        }
    }

    /// `TitleMetadata.failures` is a value a caller holds in process, not a log
    /// line, and the body is what makes a failure diagnosable there.
    @Test func theCallerFacingFailureKeepsItsDetail() async {
        struct Failing: MetadataProvider {
            let provider = Provider.tmdb
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                throw SlateError.http(status: 500, body: "upstream exploded")
            }
        }

        let result = await MetadataAggregator(providers: [Failing()]).metadata(for: Lookup(search: "X"))

        #expect(result.failures[.tmdb]?.contains("upstream exploded") == true)
    }
}

@Suite("The failing URL")
struct FailingURLTests {
    private struct Offline: MetadataProvider, ArtworkProvider {
        let provider = Provider.tmdb
        func snapshot(for lookup: Lookup) async throws -> Snapshot? { try await fail() }
        func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int?) async throws -> ArtworkSet? {
            try await fail()
        }

        /// The shape a TMDB search has: what the person typed, in the query
        /// string, on a host that cannot resolve.
        private func fail<T>() async throws -> T {
            let url = URL(string: "https://tmdb.invalid.invalid/3/search/movie?query=private%20phrase")!
            _ = try await URLSession.shared.data(from: url)
            throw SlateError.malformedURL
        }
    }

    /// `String(describing:)` of a `URLError` embeds `NSErrorFailingURLKey` —
    /// the whole URL, query string included. That is the search term, inside a
    /// string that reads like an opaque diagnostic.
    @Test func aTransportFailureDoesNotCarryTheQueryToTheCaller() async {
        let result = await MetadataAggregator(providers: [Offline()])
            .metadata(for: Lookup(search: "private phrase"))

        let failure = result.failures[.tmdb]
        #expect(failure?.contains("private") == false, "not what was searched for")
        #expect(failure?.hasPrefix("URLError") == true, "still says what went wrong")
    }

    @Test func theSameHoldsForArtwork() async {
        let set = await MetadataAggregator(providers: [Offline()])
            .artwork(for: Identifiers(tmdb: 1), kind: .movie)

        #expect(set.failures[.tmdb]?.contains("private") == false)
    }
}
