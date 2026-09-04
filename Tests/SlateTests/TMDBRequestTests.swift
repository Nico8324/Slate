import Foundation
import Testing
@testable import Slate

private func provider(language: String = "en-US") -> TMDBProvider {
    TMDBProvider(accessToken: "test-token", language: language, session: StubURLProtocol.session)
}

@Suite(.serialized)
struct TMDBRequestTests {

    // MARK: - Films, which had never been exercised at all

    @Test func aFilmIsSearchedThenDetailed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/movie", json: """
        {"results":[{"id":603,"title":"The Matrix","popularity":80.0}]}
        """)
        StubURLProtocol.stub("/movie/603", json: """
        {"id":603,"imdb_id":"tt0133093","title":"The Matrix","original_title":"The Matrix",
         "overview":"A hacker learns the truth.","release_date":"1999-03-30","runtime":136,
         "genres":[{"name":"Action"}],"vote_average":8.2,"poster_path":"/p.jpg"}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "The Matrix", kind: .movie)))

        #expect(snapshot.kind == .movie)
        #expect(snapshot.ids.imdb == "tt0133093")
        #expect(snapshot.ids.tmdb == 603)
        #expect(snapshot.runtimeMinutes == 136)
        #expect(snapshot.rating == 8.2)
        #expect(snapshot.searchNames == ["The Matrix"], "deduplicated against the original title")
        #expect(snapshot.posterURL?.absoluteString.contains("/original/p.jpg") == true)
    }

    @Test func aFilmKnownOnlyByIMDbIDIsFound() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/find/tt0133093", json: """
        {"movie_results":[{"id":603}],"tv_results":[]}
        """)
        StubURLProtocol.stub("/movie/603", json: #"{"id":603,"title":"The Matrix"}"#)

        let snapshot = try #require(await provider().snapshot(for: Lookup(imdbID: "tt0133093")))
        #expect(snapshot.kind == .movie)
    }

    @Test func filmArtworkResolvesAnIMDbIDFirst() async throws {
        // This returned nothing at all: the film path required a TMDB id while
        // the television path had been looking one up all along.
        StubURLProtocol.reset()
        StubURLProtocol.stub("/find/tt0133093", json: #"{"movie_results":[{"id":603}],"tv_results":[]}"#)
        StubURLProtocol.stub("/movie/603/images", json: """
        {"posters":[{"file_path":"/a.jpg","iso_639_1":"en","vote_average":7.0,"width":2000,"height":3000}],
         "backdrops":[],"logos":[]}
        """)

        let set = try #require(await provider().artwork(for: Identifiers(imdb: "tt0133093"), kind: .movie))
        #expect(set.posters.count == 1)
    }

    // MARK: - Requests carry what they should

    @Test func theCredentialRidesAsABearerHeaderAndNeverInTheURL() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        _ = try await provider().snapshot(for: Lookup(search: "X", kind: .series))

        #expect(!StubURLProtocol.requested.contains { $0.absoluteString.contains("test-token") })
        #expect(!StubURLProtocol.requested.contains { $0.absoluteString.contains("api_key") })
    }

    @Test func theRequestedLanguageIsAsked() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        _ = try await provider(language: "fr-FR").snapshot(for: Lookup(search: "X", kind: .series))

        #expect(StubURLProtocol.requested.contains { $0.absoluteString.contains("language=fr-FR") })
    }

    // MARK: - Seasons, end to end

    @Test func aFlattenedShowIsCorrectedThroughThreeRequests() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/30984", json: """
        {"id":30984,"seasons":[{"season_number":1,"episode_count":80,"name":"Season 1"}]}
        """)
        StubURLProtocol.stub("/tv/30984/episode_groups", json: """
        {"results":[{"id":"g1","name":"TVDB Order","type":1,"group_count":2,"episode_count":80}]}
        """)
        StubURLProtocol.stub("/tv/episode_group/g1", json: """
        {"id":"g1","name":"TVDB Order","groups":[
          {"order":1,"name":"Arc One","episodes":[
            {"id":1,"name":"E1","season_number":1,"episode_number":1},
            {"id":2,"name":"E2","season_number":1,"episode_number":2}]},
          {"order":2,"name":"Arc Two","episodes":[
            {"id":3,"name":"E3","season_number":1,"episode_number":3}]}]}
        """)

        let structure = try #require(await provider().seasons(for: Identifiers(tmdb: 30984)))

        #expect(structure.ordering == .episodeGroup(name: "TVDB Order"))
        #expect(structure.numberedSeasons.map(\.episodeCount) == [2, 1])
        #expect(structure.position(ofAbsolute: 3) == EpisodePosition(season: 2, episode: 1))
        #expect(structure.nativeSeason(ofSeason: 2) == 1)
    }

    @Test func anOrderingIsFetchedOnceAndRemembered() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/7", json: #"{"id":7,"seasons":[{"season_number":1,"episode_count":10}]}"#)

        let tmdb = provider()
        _ = try await tmdb.seasons(for: Identifiers(tmdb: 7))
        _ = try await tmdb.seasons(for: Identifiers(tmdb: 7))

        #expect(StubURLProtocol.requested.filter { $0.path == "/3/tv/7" }.count == 1)
    }

    // MARK: - Failure behaviour

    @Test func aThrottledRequestIsRetriedAndThenSucceeds() async throws {
        StubURLProtocol.reset()
        // Longest-pattern matching lets the second stub win for the details call.
        StubURLProtocol.stub("/search/tv", .init(status: 429, headers: ["Retry-After": "0"]))

        let tmdb = TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
        await #expect(throws: SlateError.self) {
            try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        }
        #expect(StubURLProtocol.requested.count == 3, "three tries, then it gives up")
    }

    @Test func anExpiredCredentialSaysSoRatherThanRetrying() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", .init(status: 401, body: #"{"status_message":"Invalid API key"}"#))

        let tmdb = TMDBProvider(accessToken: "stale", session: StubURLProtocol.session)
        await #expect(throws: SlateError.self) {
            try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        }
        #expect(StubURLProtocol.requested.count == 1, "401 will not fix itself")
    }
}
