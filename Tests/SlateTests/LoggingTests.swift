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
