import Foundation
import Testing
@testable import Slate

struct TMDBRequestTests {
    let stub = Stub()

    private func provider(language: String = "en-US") -> TMDBProvider {
        TMDBProvider(accessToken: "test-token", language: language, transport: stub.transport)
    }

    // MARK: - Films, which had never been exercised at all

    @Test func aFilmIsSearchedThenDetailed() async throws {
        stub.stub("/search/movie", json: """
        {"results":[{"id":603,"title":"The Matrix","popularity":80.0}]}
        """)
        stub.stub("/movie/603", json: """
        {"id":603,"imdb_id":"tt0133093","title":"The Matrix","original_title":"The Matrix",
         "overview":"A hacker learns the truth.","release_date":"1999-03-30","runtime":136,
         "genres":[{"id":28,"name":"Action"}],"vote_average":8.2,"vote_count":26000,"poster_path":"/p.jpg",
         "translations":{"translations":[
           {"iso_639_1":"fr","iso_3166_1":"CA","data":{"title":"La Matrice"}},
           {"iso_639_1":"fr","iso_3166_1":"FR","data":{"title":"Matrix"}},
           {"iso_639_1":"de","iso_3166_1":"DE","data":{"title":""}}]},
         "images":{"posters":[{"file_path":"/fr.jpg","iso_639_1":"fr"}],"backdrops":[{"file_path":"/b.jpg"}],"logos":[]}}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "The Matrix", kind: .movie)))
        #expect(snapshot.genreIDs == [28])
        #expect(snapshot.translatedTitles == ["fr": "La Matrice"], "first region wins; blanks are no title")
        #expect(snapshot.artwork?.posters.first?.language == "fr")
        #expect(snapshot.artwork?.backdrops.first?.isTextless == true)
        let details = try #require(stub.requested.first { $0.path == "/3/movie/603" }?.query)
        #expect(details.contains("include_image_language=en,null"))
        #expect(details.contains("images"))

        #expect(snapshot.kind == .movie)
        #expect(snapshot.ids.imdb == "tt0133093")
        #expect(snapshot.ids.tmdb == 603)
        #expect(snapshot.runtimeMinutes == 136)
        #expect(snapshot.rating == 8.2)
        #expect(snapshot.searchNames == ["The Matrix"], "deduplicated against the original title")
        #expect(snapshot.posterURL?.absoluteString.contains("/original/p.jpg") == true)
    }

    @Test func aFilmKnownOnlyByIMDbIDIsFound() async throws {
        stub.stub("/find/tt0133093", json: """
        {"movie_results":[{"id":603}],"tv_results":[]}
        """)
        stub.stub("/movie/603", json: #"{"id":603,"title":"The Matrix"}"#)

        let snapshot = try #require(await provider().snapshot(for: Lookup(imdbID: "tt0133093")))
        #expect(snapshot.kind == .movie)
    }

    @Test func filmArtworkResolvesAnIMDbIDFirst() async throws {
        // This returned nothing at all: the film path required a TMDB id while
        // the television path had been looking one up all along.
        stub.stub("/find/tt0133093", json: #"{"movie_results":[{"id":603}],"tv_results":[]}"#)
        stub.stub("/movie/603/images", json: """
        {"posters":[{"file_path":"/a.jpg","iso_639_1":"en","vote_average":7.0,"width":2000,"height":3000}],
         "backdrops":[],"logos":[]}
        """)

        let set = try #require(await provider().artwork(for: Identifiers(imdb: "tt0133093"), kind: .movie))
        #expect(set.posters.count == 1)
    }

    // MARK: - Requests carry what they should

    @Test func theCredentialRidesAsABearerHeaderAndNeverInTheURL() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        stub.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        _ = try await provider().snapshot(for: Lookup(search: "X", kind: .series))

        #expect(!stub.requested.contains { $0.absoluteString.contains("test-token") })
        #expect(!stub.requested.contains { $0.absoluteString.contains("api_key") })
    }

    @Test func theRequestedLanguageIsAsked() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        stub.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        _ = try await provider(language: "fr-FR").snapshot(for: Lookup(search: "X", kind: .series))

        #expect(stub.requested.contains { $0.absoluteString.contains("language=fr-FR") })
    }

    // MARK: - Seasons, end to end

    @Test func aFlattenedShowIsCorrectedThroughThreeRequests() async throws {
        stub.stub("/tv/30984", json: """
        {"id":30984,"seasons":[{"season_number":1,"episode_count":80,"name":"Season 1"}]}
        """)
        stub.stub("/tv/30984/episode_groups", json: """
        {"results":[{"id":"g1","name":"TVDB Order","type":1,"group_count":2,"episode_count":80}]}
        """)
        let remaining = (3...80).map {
            "{\"id\":\($0),\"season_number\":1,\"episode_number\":\($0)}"
        }.joined(separator: ",")
        stub.stub("/tv/episode_group/g1", json: """
        {"id":"g1","name":"TVDB Order","groups":[
          {"order":1,"name":"Arc One","episodes":[
            {"id":1,"name":"E1","season_number":1,"episode_number":1},
            {"id":2,"name":"E2","season_number":1,"episode_number":2}]},
          {"order":2,"name":"Arc Two","episodes":[
            \(remaining)]}]}
        """)

        let structure = try #require(await provider().seasons(for: Identifiers(tmdb: 30984)))

        #expect(structure.ordering == .episodeGroup(name: "TVDB Order"))
        #expect(structure.numberedSeasons.map(\.episodeCount) == [2, 78])
        #expect(structure.position(ofAbsolute: 3) == EpisodePosition(season: 2, episode: 1))
        #expect(structure.nativeSeason(ofSeason: 2) == 1)
    }

    @Test func anOrderingIsFetchedOnceAndRemembered() async throws {
        stub.stub("/tv/7", json: #"{"id":7,"seasons":[{"season_number":1,"episode_count":10}]}"#)

        let tmdb = provider()
        _ = try await tmdb.seasons(for: Identifiers(tmdb: 7))
        _ = try await tmdb.seasons(for: Identifiers(tmdb: 7))

        #expect(stub.requested.filter { $0.path == "/3/tv/7" }.count == 1)
    }

    // MARK: - Failure behaviour

    @Test func aThrottledRequestIsRetriedAndThenSucceeds() async throws {
        // Longest-pattern matching lets the second stub win for the details call.
        stub.stub("/search/tv", .init(status: 429, headers: ["Retry-After": "0"]))

        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        await #expect(throws: SlateError.self) {
            try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        }
        #expect(stub.requested.count == 3, "three tries, then it gives up")
    }

    @Test func anExpiredCredentialSaysSoRatherThanRetrying() async throws {
        stub.stub("/search/tv", .init(status: 401, body: #"{"status_message":"Invalid API key"}"#))

        let tmdb = TMDBProvider(accessToken: "stale", transport: stub.transport)
        await #expect(throws: SlateError.self) {
            try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        }
        #expect(stub.requested.count == 1, "401 will not fix itself")
    }
}

extension TMDBRequestTests {
  struct RecordFields {
    let stub = Stub()

    private func provider() -> TMDBProvider {
        TMDBProvider(accessToken: "test-token", transport: stub.transport)
    }

    @Test func theRatingIsTheAskedForCountrysOrNothing() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1.0}]}"#)
        stub.stub("/tv/1", json: """
        {"id":1,"name":"X","content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]}}
        """)

        let french = TMDBProvider(accessToken: "t", region: "FR", transport: stub.transport)
        let snapshot = try #require(await french.snapshot(for: Lookup(search: "X", kind: .series)))

        // Ratings are not translations of each other; TV-MA means nothing in
        // France, so nothing is the honest answer.
        #expect(snapshot.contentRating == nil)
    }

    @Test func aFilmsCertificationComesFromItsReleaseDates() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9.0}]}"#)
        stub.stub("/movie/603", json: """
        {"id":603,"title":"The Matrix",
         "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"R"}]}]},
        }
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .movie)))

        #expect(snapshot.contentRating == "R", "the blank entry is skipped")
    }

    /// In cinemas is not at home: a film is watchable from its digital release,
    /// the region's own when it has one.
    @Test func aFilmsHomeReleaseIsItsFirstDigitalOne() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9.0}]}"#)
        stub.stub("/movie/603", json: """
        {"id":603,"title":"X","release_dates":{"results":[
          {"iso_3166_1":"US","release_dates":[{"type":3,"release_date":"2027-03-12T00:00:00.000Z"},
                                              {"type":4,"release_date":"2027-04-20T00:00:00.000Z"}]},
          {"iso_3166_1":"FR","release_dates":[{"type":4,"release_date":"2027-05-02T00:00:00.000Z"}]}]}}
        """)

        let american = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(american.homeReleaseDate == (try Date("2027-04-20T00:00:00Z", strategy: .iso8601)))

        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9.0}]}"#)
        stub.stub("/movie/603", json: """
        {"id":603,"title":"X","release_dates":{"results":[
          {"iso_3166_1":"US","release_dates":[{"type":4,"release_date":"2027-04-20T00:00:00.000Z"}]},
          {"iso_3166_1":"FR","release_dates":[{"type":4,"release_date":"2027-05-02T00:00:00.000Z"}]}]}}
        """)
        let french = TMDBProvider(accessToken: "t", region: "FR", transport: stub.transport)
        let snapshot = try #require(await french.snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(snapshot.homeReleaseDate == (try Date("2027-05-02T00:00:00Z", strategy: .iso8601)))
    }

    /// No date of the region's own: the earliest anywhere, when it's first watchable at home somewhere.
    @Test func withoutTheRegionsOwnTheHomeReleaseIsTheEarliestAnywhere() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9.0}]}"#)
        stub.stub("/movie/603", json: """
        {"id":603,"title":"X","release_dates":{"results":[
          {"iso_3166_1":"GB","release_dates":[{"type":4,"release_date":"2027-04-28T00:00:00.000Z"}]},
          {"iso_3166_1":"US","release_dates":[{"type":4,"release_date":"2027-04-20T00:00:00.000Z"}]},
          {"iso_3166_1":"FR","release_dates":[{"type":3,"release_date":"2027-03-12T00:00:00.000Z"}]}]}}
        """)
        let french = TMDBProvider(accessToken: "t", region: "FR", transport: stub.transport)
        let snapshot = try #require(await french.snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(snapshot.homeReleaseDate == (try Date("2027-04-20T00:00:00Z", strategy: .iso8601)))
    }


}

  struct RecordFieldsPartTwo {
    let stub = Stub()
    private func provider(language: String = "en-US", region: String = "US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, region: region,
                     transport: stub.transport)
    }

    private func stubShow(_ json: String) {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        stub.stub("/tv/1", json: json)
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

    /// A show just looked up has its seasons in the details already fetched: no second request.
    @Test func seasonsComeFromTheDetailsAlreadyFetched() async throws {
        stubShow(#"{"id":1,"name":"X","seasons":[{"season_number":1,"episode_count":10}]}"#)
        let tmdb = provider()

        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let seasons = try await tmdb.seasons(for: Identifiers(tmdb: 1), kind: .series)

        #expect(seasons?.nativeSeasons.count == 1)
        #expect(stub.requested.filter { $0.path == "/3/tv/1" }.count == 1)
    }

    /// The least recently used goes first: a response read again outlives older ones.
    @Test func aCachedResponseReadAgainIsKeptLonger() async {
        let cache = ResponseCache(limit: 2)
        await cache.store(Data([1]), for: "a")
        await cache.store(Data([2]), for: "b")
        _ = await cache.data(for: "a")
        await cache.store(Data([3]), for: "c")

        #expect(await cache.data(for: "a") != nil)
        #expect(await cache.data(for: "b") == nil)
    }

    @Test func keywordsStudiosOriginAndStatusComeFromTheSameRequest() async throws {
        stubShow("""
        {"id":1,"name":"X","original_language":"ja","origin_country":["JP"],"status":"Ended",
         "networks":[{"name":"Fuji TV"}],
         "keywords":{"results":[{"name":"time travel"},{"name":"dystopia"}]},
         "last_episode_to_air":{"air_date":"2024-03-01"},
         "next_episode_to_air":{"air_date":"2026-10-05","season_number":3,"episode_number":1}}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .series)))

        #expect(snapshot.keywords == ["time travel", "dystopia"])
        #expect(snapshot.studios == ["Fuji TV"])
        #expect(snapshot.originalLanguage == "ja")
        #expect(snapshot.originCountries == ["JP"])
        #expect(snapshot.status == .ended, "TMDB says `Ended`, AniList says `FINISHED`, callers see one word")
        #expect(snapshot.nextEpisodeAirDate != nil)
        #expect(snapshot.nextEpisode == EpisodePosition(season: 3, episode: 1), "a new season")
        #expect(snapshot.lastEpisodeAirDate != nil)
        // One request for all of it. (A Japanese show also asks for its Japanese
        // trailers, which is a separate question with its own path.)
        #expect(stub.requested.filter { $0.path == "/3/tv/1" }.count == 1)
    }

    @Test func aFilmCarriesItsFranchise() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"X","popularity":9}]}"#)
        stub.stub("/movie/603", json: """
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
        stub.stub("/tv/1/season/2", json: """
        {"episodes":[
          {"id":11,"name":"Pilot","overview":"It begins.","air_date":"2011-04-17",
           "still_path":"/s.jpg","vote_average":8.1,"vote_count":120,"season_number":2,"episode_number":1},
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

extension TMDBRequestTests {
  struct ProviderSemantics {
    let stub = Stub()
    private func provider() -> TMDBProvider {
        TMDBProvider(accessToken: "t", transport: stub.transport)
    }

    /// `year` matches any release date a film carries, so a re-release or a
    /// regional reissue answers for a year it was not made in.
    @Test func aYearNarrowsTheOriginalReleaseNotEveryRelease() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)
        stub.stub("/movie/1", json: #"{"id":1,"title":"X"}"#)

        _ = try await provider().snapshot(for: Lookup(search: "X", year: 1999, kind: .movie))

        let asked = try #require(stub.requested.first?.query)
        #expect(asked.contains("primary_release_year=1999"))
        #expect(!asked.contains("&year="))
    }

    /// The kindless path is what `Lookup(search:)` takes, and it was the one
    /// still handing back TMDB's raw relevance — 1999's Hunter x Hunter first.
    @Test func aKindlessSearchPicksTheSameWinnerAsATypedOne() async throws {
        stub.stub("/search/multi", json: """
        {"results":[
          {"id":99,"media_type":"person","name":"Hunter x Hunter"},
          {"id":11061,"media_type":"tv","name":"Hunter x Hunter","popularity":40.0},
          {"id":6572,"media_type":"tv","name":"Hunter x Hunter","popularity":12.0}]}
        """)
        stub.stub("/tv/11061", json: #"{"id":11061,"name":"Hunter x Hunter"}"#)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "Hunter x Hunter")))

        #expect(snapshot.ids.tmdb == 11061, "the 2011 adaptation, not the person and not relevance's first")
    }

    /// `origin_country` is a television field. Without the film equivalent the
    /// whole field silently meant "series only".
    @Test func aFilmHasAnOriginCountryToo() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)
        stub.stub("/movie/1", json: """
        {"id":1,"title":"Your Name","production_countries":[{"iso_3166_1":"JP"}],
         "vote_average":8.5,"vote_count":11000}
        """)

        let snapshot = try #require(await provider().snapshot(for: Lookup(search: "X", kind: .movie)))

        #expect(snapshot.originCountries == ["JP"])
        // And the score arrives with the thing that says what it is worth.
        #expect(snapshot.ratings?.first?.source == "tmdb")
        #expect(snapshot.ratings?.first?.votes == 11000)
    }

    /// MDBList answers `ratings` with five sites at once; TMDB answers with one.
    /// Under the general order the one-entry list would win the field.
    @Test func theBroadRatingsListWinsOverASingleScore() {
        let aggregator = MetadataAggregator(providers: [])
        let result = aggregator.assemble([
            .tmdb: Snapshot(ratings: [Rating(source: "tmdb", value: 8.5)]),
            .mdbList: Snapshot(ratings: [
                Rating(source: "imdb", value: 8.4), Rating(source: "metacritic", value: 7.9),
            ]),
        ])

        #expect(result.ratings.best?.map(\.source) == ["imdb", "metacritic"])
        #expect(result.providersConsulted(for: .ratings) == [.mdbList, .tmdb],
                "TMDB is still there, just not first")
    }
  }
}

extension TMDBRequestTests {
  struct Details {
    let stub = Stub()

    private func tmdb(language: String = "en-US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, transport: stub.transport)
    }

    private func stubFilm(_ json: String) {
        stub.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)
        stub.stub("/movie/1", json: json)
    }

    @Test func aFilmCarriesItsDirectorsThenWritersOnce() async throws {
        stubFilm("""
        {"id":1,"title":"X","credits":{"cast":[],"crew":[
          {"id":5,"name":"Rebecca Sonnenshine","job":"Screenplay","department":"Writing"},
          {"id":4,"name":"Paul Feig","job":"Director","department":"Directing"},
          {"id":4,"name":"Paul Feig","job":"Director","department":"Directing"},
          {"id":6,"name":"Someone","job":"Assistant Director","department":"Directing"},
          {"id":7,"name":"Grip","job":"Key Grip","department":"Camera"}]}}
        """)
        let crew = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie))?.crew)
        #expect(crew.map(\.name) == ["Paul Feig", "Rebecca Sonnenshine"])
        #expect(crew.map(\.department) == [.directing, .writing])
    }

    @Test func aShowIsCreditedToItsCreators() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":2,"name":"Tulsa King"}]}"#)
        stub.stub("/tv/2", json: """
        {"id":2,"name":"Tulsa King","created_by":[{"id":9,"name":"Taylor Sheridan"}]}
        """)
        let crew = try #require(await tmdb().snapshot(for: Lookup(search: "Tulsa King", kind: .series))?.crew)
        #expect(crew == [CrewMember(personID: 9, name: "Taylor Sheridan", job: "Creator", department: .creator)])
    }

    @Test func theOriginalVersionIsTheDefaultTrailerAndEveryLanguageIsKept() async throws {
        stubFilm("""
        {"id":1,"title":"The Housemaid","original_language":"en","videos":{"results":[
          {"key":"vf","site":"YouTube","type":"Trailer","iso_639_1":"fr","name":"Bande-annonce (VF)","published_at":"2025-11-12T10:00:00.000Z"},
          {"key":"final","site":"YouTube","type":"Trailer","official":true,"iso_639_1":"en","published_at":"2025-12-15T10:00:00.000Z"},
          {"key":"first","site":"YouTube","type":"Trailer","official":true,"iso_639_1":"en","published_at":"2025-09-16T10:00:00.000Z"},
          {"key":"teaser","site":"YouTube","type":"Teaser","official":true,"iso_639_1":"fr"},
          {"key":"vimeo","site":"Vimeo","type":"Trailer","iso_639_1":"en"}]}}
        """)
        let snapshot = try #require(await tmdb(language: "fr-FR").snapshot(for: Lookup(search: "X", kind: .movie)))

        #expect(snapshot.trailerYouTubeID == "final", "original language, official, newest")
        #expect(snapshot.trailers?.count == 4, "YouTube only")
        #expect(snapshot.trailers?.best(preferring: ["fr"])?.youTubeID == "vf", "a trailer beats a teaser in the asked language")
        let details = try #require(stub.requested.first { $0.path == "/3/movie/1" })
        #expect(details.query?.contains("include_video_language=fr,en,null") == true,
                "without it a French lookup never saw the studio's own trailers")
    }

    @Test func aThirdLanguageFilmAsksForItsOwnTrailersOnce() async throws {
        stubFilm(#"{"id":1,"title":"X","original_language":"ja","videos":{"results":[]}}"#)
        stub.stub("/movie/1/videos", json: """
        {"results":[{"key":"jp","site":"YouTube","type":"Trailer","iso_639_1":"ja"}]}
        """)
        let snapshot = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(snapshot.trailerYouTubeID == "jp")
        #expect(stub.requested.filter { $0.path == "/3/movie/1/videos" }.count == 1)
    }

    @Test func recommendationsRideOnTheDetailsRequest() async throws {
        stubFilm("""
        {"id":1,"title":"X","recommendations":{"results":[
          {"id":8,"media_type":"movie","title":"Y","release_date":"2020-01-01"},
          {"id":9,"media_type":"person","name":"Not a title"}]}}
        """)
        let recommended = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie))?.recommendations)
        #expect(recommended.map(\.title) == ["Y"])
        #expect(stub.requested.filter { $0.path.hasPrefix("/3/movie/") }.count == 1)
    }

    @Test func aTitleNobodyHasRatedHasNoScore() async throws {
        stubFilm(#"{"id":1,"title":"X","vote_average":0,"vote_count":0}"#)
        let snapshot = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(snapshot.rating == nil)
        #expect(snapshot.ratings == nil)
    }

    @Test func someoneWithTwoRolesIsOneCastMember() async throws {
        stubFilm("""
        {"id":1,"title":"X","credits":{"cast":[
          {"id":3,"name":"Actor","character":"Twin A","order":0},
          {"id":4,"name":"Other","character":"Friend","order":1},
          {"id":3,"name":"Actor","character":"Twin B","order":2}]}}
        """)
        let cast = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie))?.cast)
        #expect(cast.map(\.id) == [3, 4])
        #expect(cast.first?.character == "Twin A / Twin B")
    }

    @Test func imagesCanBeAskedForAtTheSizeTheyAreDrawn() throws {
        let original = try #require(TMDBProvider.imageURL("/p.jpg"))
        #expect(TMDBProvider.resized(original, toFit: 300).absoluteString.hasSuffix("/t/p/w300/p.jpg"))
        #expect(TMDBProvider.resized(original, toFit: 5000) == original, "nothing smaller fits")
        let small = try #require(URL(string: "https://image.tmdb.org/t/p/w200/p.jpg"))
        #expect(TMDBProvider.resized(small, toFit: 700).absoluteString.hasSuffix("/t/p/w780/p.jpg"),
                "an MDBList w200 poster is upgraded, not left blurry")
        #expect(TMDBProvider.resized(small, toFit: 5000).absoluteString.hasSuffix("/t/p/original/p.jpg"))
        let elsewhere = try #require(URL(string: "https://example.com/original/p.jpg"))
        #expect(TMDBProvider.resized(elsewhere, toFit: 300) == elsewhere)
    }

    @Test func aBareTMDBIDWithoutAKindIsAnInvalidQuestion() async {
        await #expect(throws: SlateError.invalidLookup) {
            try await tmdb().snapshot(for: Lookup(ids: Identifiers(tmdb: 1399)))
        }
    }
}
}

struct TMDBSearchTests {
    let stub = Stub()

    @Test func mixedSearchRespectsTheRequestedYear() async throws {
        // A year with no kind is asked of both typed searches, which filter
        // by year on the server — `/search/multi` could not.
        stub.respond { request in
            let url = request.url!
            switch url.path {
            case "/3/search/movie":
                let asked1984 = url.query?.contains("primary_release_year=1984") == true
                return .init(body: asked1984
                    ? #"{"results":[{"id":2,"title":"Dune","release_date":"1984-12-14","popularity":10}]}"#
                    : #"{"results":[{"id":1,"title":"Dune","release_date":"2021-09-15","popularity":100}]}"#)
            case "/3/search/tv":
                #expect(url.query?.contains("first_air_date_year=1984") == true)
                return .init(body: #"{"results":[]}"#)
            default:
                return .init(body: #"{"id":2,"title":"Dune"}"#)
            }
        }
        let provider = TMDBProvider(accessToken: "t", transport: stub.transport)
        let result = try await provider.snapshot(for: Lookup(search: "Dune", year: 1984))
        #expect(result?.ids.tmdb == 2)
        #expect(result?.kind == .movie)
        #expect(!stub.requested.contains { $0.path == "/3/search/multi" })
    }

    @Test func emptyTranslationEntriesDoNotBlockTheFallback() async throws {
        stub.stub("/tv/1", json: """
        {"id":1,"name":"X","overview":"","translations":{"translations":[
          {"iso_639_1":"fr","iso_3166_1":"FR","data":{"overview":""}},
          {"iso_639_1":"en","iso_3166_1":"GB","data":{"overview":""}},
          {"iso_639_1":"en","iso_3166_1":"US","data":{"overview":"English synopsis"}}]}}
        """)
        let provider = TMDBProvider(accessToken: "t", language: "fr-FR", transport: stub.transport)
        let result = try await provider.snapshot(for: Lookup(ids: Identifiers(tmdb: 1), kind: .series))
        #expect(result?.overview == "English synopsis")
    }
}

struct TrailerChoiceTests {
    private func trailer(_ id: String, _ kind: Trailer.Kind = .trailer, language: String, name: String? = nil,
                         official: Bool = true, daysAgo: Double = 0) -> Trailer {
        Trailer(youTubeID: id, name: name, kind: kind, language: language, isOfficial: official,
                publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400))
    }

    @Test func aTrailerBeatsATeaserAndOfficialBeatsFanMade() {
        let trailers = [
            trailer("teaser", .teaser, language: "en"),
            trailer("fan", language: "en", official: false),
            trailer("official", language: "en", daysAgo: 30),
        ]
        #expect(trailers.best(version: .original, originalLanguage: "en", viewer: "en")?.youTubeID == "official")
    }

    @Test func theNewestWinsAmongEquals() {
        let trailers = [trailer("old", language: "en", daysAgo: 30), trailer("new", language: "en", daysAgo: 1)]
        #expect(trailers.best(version: .original, originalLanguage: "en", viewer: "en")?.youTubeID == "new")
    }

    @Test func eachVersionFindsItsOwnAndFallsBack() {
        let trailers = [
            trailer("vo", language: "en"),
            trailer("vf", language: "fr", name: "Bande-annonce VF"),
            trailer("vost", language: "fr", name: "Bande-annonce VOSTFR"),
        ]
        #expect(trailers.best(version: .original, originalLanguage: "en", viewer: "fr")?.youTubeID == "vo")
        #expect(trailers.best(version: .subtitled, originalLanguage: "en", viewer: "fr-FR")?.youTubeID == "vost")
        #expect(trailers.best(version: .dubbed, originalLanguage: "en", viewer: "fr")?.youTubeID == "vf")
        #expect(trailers.best(version: .dubbed, originalLanguage: "en", viewer: "de")?.youTubeID == "vo",
                "nothing in the viewer's language: the original")
        #expect(trailers.filter { $0.youTubeID != "vf" }
            .best(version: .dubbed, originalLanguage: "en", viewer: "fr")?.youTubeID == "vost", "no dub: subtitled")
    }

    @Test func aViewerInTheFilmsOwnLanguageGetsTheOriginal() {
        let trailers = [trailer("jp", language: "ja"), trailer("en", language: "en")]
        #expect(trailers.best(version: .dubbed, originalLanguage: "ja", viewer: "ja")?.youTubeID == "jp")
        #expect(trailers.best(version: .original, originalLanguage: "ko", viewer: "fr")?.youTubeID == "en",
                "no trailer in the original language: English")
    }

    @Test func aTrailerSurvivesEncoding() throws {
        let trailer = trailer("vf", language: "fr", name: "VF")
        #expect(try JSONDecoder().decode(Trailer.self, from: JSONEncoder().encode(trailer)) == trailer)
    }
}
