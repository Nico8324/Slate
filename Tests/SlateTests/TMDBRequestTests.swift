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

// Nested inside the serialized suite above: the stub table is shared static
// state, so two sibling suites would race each other's routes.
extension TMDBRequestTests {
  @Suite(.serialized)
  struct RecordFields {


    @Test func theRatingIsTheAskedForCountrysOrNothing() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        StubURLProtocol.stub("/tv/1", json: """
        {"id":1,"name":"X","content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]}}
        """)

        let french = TMDBProvider(accessToken: "t", region: "FR", session: StubURLProtocol.session)
        let snapshot = try #require(await french.snapshot(for: Lookup(search: "X", kind: .series)))

        // Ratings are not translations of each other; TV-MA means nothing in
        // France, so nothing is the honest answer.
        #expect(snapshot.contentRating == nil)
    }

    @Test func aFilmsCertificationComesFromItsReleaseDates() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9.0}]}"#)
        StubURLProtocol.stub("/movie/603", json: """
        {"id":603,"title":"The Matrix",
         "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"R"}]}]},
        }
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .movie)))

        #expect(snapshot.contentRating == "R", "the blank entry is skipped")
    }


}

  @Suite(.serialized)
  struct RecordFieldsPartTwo {
    private func provider(language: String = "en-US", region: String = "US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, region: region,
                     session: StubURLProtocol.session)
    }

    private func stubShow(_ json: String) {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        StubURLProtocol.stub("/tv/1", json: json)
    }

    @Test func availabilityIsScopedToOneRegion() async throws {
        stubShow("""
        {"id":1,"name":"X","watch/providers":{"results":{
          "US":{"link":"https://tmdb/US","flatrate":[{"provider_name":"Netflix","logo_path":"/n.jpg"}],
                "rent":[{"provider_name":"Apple TV"}]},
          "FR":{"flatrate":[{"provider_name":"Canal+"}]}}}}
        """)

        let snapshot = try #require(await provider(region: "US").snapshot(for: Lookup(search: "X", kind: .series)))
        let options = try #require(snapshot.watchOptions)

        #expect(options.count == 2, "US only — a service carrying it in France is not an answer here")
        #expect(options.contains { $0.service == "Netflix" && $0.kind == .subscription })
        #expect(options.contains { $0.service == "Apple TV" && $0.kind == .rent })
        #expect(options.allSatisfy { $0.region == "US" })
        #expect(options.first?.link?.absoluteString == "https://tmdb/US")
    }

    @Test func aRegionWithNoAvailabilityIsNilNotEmpty() async throws {
        stubShow(#"{"id":1,"name":"X","watch/providers":{"results":{"US":{"flatrate":[{"provider_name":"Netflix"}]}}}}"#)

        let snapshot = try #require(await provider(region: "JP").snapshot(for: Lookup(search: "X", kind: .series)))
        #expect(snapshot.watchOptions == nil)
    }

    @Test func anEmptyLocalisedSynopsisFallsBackRatherThanShowingBlank() async throws {
        // TMDB returns "" rather than omitting the field when a language has no
        // translation, and a blank synopsis is worse than an English one.
        stubShow("""
        {"id":1,"name":"X","overview":"","translations":{"translations":[
          {"iso_639_1":"en","iso_3166_1":"US","data":{"overview":"The English one."}},
          {"iso_639_1":"de","iso_3166_1":"DE","data":{"overview":"Die deutsche."}}]}}
        """)

        let snapshot = try #require(await provider(language: "fr-FR").snapshot(for: Lookup(search: "X", kind: .series)))
        #expect(snapshot.overview == "The English one.")
    }

    @Test func aLocalisedSynopsisIsPreferredToEnglish() async throws {
        stubShow("""
        {"id":1,"name":"X","overview":"","translations":{"translations":[
          {"iso_639_1":"en","iso_3166_1":"US","data":{"overview":"The English one."}},
          {"iso_639_1":"fr","iso_3166_1":"FR","data":{"overview":"La française."}}]}}
        """)

        let snapshot = try #require(await provider(language: "fr-FR").snapshot(for: Lookup(search: "X", kind: .series)))
        #expect(snapshot.overview == "La française.")
    }

    @Test func keywordsStudiosOriginAndStatusComeFromTheSameRequest() async throws {
        stubShow("""
        {"id":1,"name":"X","original_language":"ja","origin_country":["JP"],"status":"Ended",
         "networks":[{"name":"Fuji TV"}],
         "keywords":{"results":[{"name":"time travel"},{"name":"dystopia"}]},
         "last_episode_to_air":{"air_date":"2024-03-01"},
         "next_episode_to_air":{"air_date":"2026-10-05"}}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .series)))

        #expect(snapshot.keywords == ["time travel", "dystopia"])
        #expect(snapshot.studios == ["Fuji TV"])
        #expect(snapshot.originalLanguage == "ja")
        #expect(snapshot.originCountries == ["JP"])
        #expect(snapshot.status == .ended, "TMDB says `Ended`, AniList says `FINISHED`, callers see one word")
        #expect(snapshot.nextEpisodeAirDate != nil)
        #expect(snapshot.lastEpisodeAirDate != nil)
        // One request for all of it.
        #expect(StubURLProtocol.requested.filter { $0.path.hasPrefix("/3/tv/1") }.count == 1)
    }

    @Test func aFilmCarriesItsFranchise() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9}]}"#)
        StubURLProtocol.stub("/movie/603", json: """
        {"id":603,"title":"The Matrix",
         "belongs_to_collection":{"id":2344,"name":"The Matrix Collection","poster_path":"/c.jpg"},
         "keywords":{"keywords":[{"name":"simulated reality"}]},
         "production_companies":[{"name":"Village Roadshow"}]}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .movie)))

        #expect(snapshot.franchise?.name == "The Matrix Collection")
        #expect(snapshot.franchise?.posterURL?.absoluteString.hasSuffix("/c.jpg") == true)
        #expect(snapshot.keywords == ["simulated reality"], "film names the field `keywords`, television `results`")
        #expect(snapshot.studios == ["Village Roadshow"])
    }

    @Test func anEpisodeListCarriesWhatALibraryShows() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/1/season/2", json: """
        {"episodes":[
          {"id":11,"name":"Pilot","overview":"It begins.","air_date":"2011-04-17",
           "still_path":"/s.jpg","vote_average":8.1,"season_number":2,"episode_number":1},
          {"id":12,"name":"Second","season_number":2,"episode_number":2}]}
        """)

        let episodes = try await provider().episodes(ofShow: 1, nativeSeason: 2)

        #expect(episodes.count == 2)
        #expect(episodes.first?.title == "Pilot")
        #expect(episodes.first?.overview == "It begins.")
        #expect(episodes.first?.rating == 8.1)
        #expect(episodes.first?.stillURL?.absoluteString.hasSuffix("/s.jpg") == true)
        #expect(episodes.last?.airDate == nil, "an unaired episode has no date rather than a guessed one")
    }
  }
}
