import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  struct Browsing {
    let stub = Stub()
    private func provider() -> TMDBProvider {
        TMDBProvider(accessToken: "t", transport: stub.transport)
    }

    @Test func aSearchReturnsEveryCandidateInsteadOfPickingOne() async throws {
        stub.stub("/search/multi", json: """
        {"results":[
          {"id":12971,"media_type":"tv","name":"Dragon Ball Z","first_air_date":"1989-04-26","poster_path":"/z.jpg"},
          {"id":12609,"media_type":"tv","name":"Dragon Ball","first_air_date":"1986-02-26"},
          {"id":99,"media_type":"person","name":"Akira Toriyama"}]}
        """)

        let candidates = try await provider().candidates(for: "Dragon Ball")

        #expect(candidates.map(\.title) == ["Dragon Ball Z", "Dragon Ball"], "the person is not a title")
        #expect(candidates.map(\.year) == [1989, 1986])
        #expect(candidates.first?.posterURL != nil)
    }

    @Test func aListOfOneKindNeedsNoMediaTypeInItsRows() async throws {
        stub.stub("/tv/popular", json: """
        {"results":[{"id":1,"name":"A","first_air_date":"2020-01-01"},
                    {"id":2,"name":"B","first_air_date":"2021-01-01"}]}
        """)

        let titles = try await provider().titles(in: .popularShows)

        #expect(titles.count == 2)
        #expect(titles.allSatisfy { $0.kind == .series })
    }

    @Test func aTrendingListStatesTheKindPerRow() async throws {
        stub.stub("/trending/all/week", json: """
        {"results":[{"id":1,"media_type":"movie","title":"A","release_date":"2020-01-01"},
                    {"id":2,"media_type":"tv","name":"B"},
                    {"id":3,"media_type":"person","name":"C"}]}
        """)

        let titles = try await provider().titles(in: .trendingThisWeek)

        #expect(titles.map(\.kind) == [.movie, .series])
    }

    @Test func genresAreListedPerKind() async throws {
        stub.stub("/genre/tv/list", json: #"{"genres":[{"id":10759,"name":"Action & Adventure"}]}"#)

        let genres = try await provider().genres(of: .series)

        #expect(genres == [TMDBGenre(id: 10759, name: "Action & Adventure")])
    }

    @Test func aGenreIsBrowsedByPopularityAmongTitlesPeopleRated() async throws {
        stub.stub("/discover/movie", json: #"{"results":[{"id":1,"title":"A","release_date":"2020-01-01"}]}"#)

        let titles = try await provider().titles(inGenre: 28, kind: .movie, page: 2)

        #expect(titles.map(\.kind) == [.movie])
        let asked = try #require(stub.requested.last?.query)
        #expect(asked.contains("with_genres=28"))
        #expect(asked.contains("sort_by=popularity.desc"))
        #expect(asked.contains("vote_count.gte=50"))
        #expect(asked.contains("page=2"))
    }

    @Test func aGenrePagePastTheLastIsEmptyWithoutAsking() async throws {
        #expect(try await provider().titles(inGenre: 28, kind: .movie, page: TMDBProvider.lastPage + 1).isEmpty)
        #expect(stub.requested.isEmpty)
    }

    @Test func upcomingFilmsAreThoseNotOutYetWithTheirDates() async throws {
        stub.stub("/discover/movie", json: """
        {"results":[{"id":1,"title":"Soon","release_date":"2027-03-12","backdrop_path":"/b.jpg"},
                    {"id":2,"title":"Today","release_date":"2026-09-23"},
                    {"id":3,"title":"Undated"}]}
        """)
        let day = try Date("2026-09-23T12:00:00Z", strategy: .iso8601)

        let films = try await provider().upcoming(.movie, after: day)

        #expect(films.map(\.title) == ["Soon"])
        #expect(films.first?.releaseDate == (try Date("2027-03-12T00:00:00Z", strategy: .iso8601)))
        #expect(films.first?.backdropURL != nil)
        let asked = try #require(stub.requested.last?.query)
        #expect(asked.contains("primary_release_date.gte=2026-09-23"))
        #expect(asked.contains("sort_by=popularity.desc"))
    }

    @Test func upcomingShowsAreThosePremieringLater() async throws {
        stub.stub("/discover/tv", json: #"{"results":[{"id":1,"name":"New","first_air_date":"2027-01-08","original_language":"ja","genre_ids":[16,10759]}]}"#)
        let day = try Date("2026-09-23T12:00:00Z", strategy: .iso8601)

        let shows = try await provider().upcoming(.series, after: day)

        #expect(shows.map(\.kind) == [.series])
        #expect(shows.first?.originalLanguage == "ja")
        #expect(shows.first?.genreIDs == [16, 10759])
        #expect(shows.first?.releaseDate == (try Date("2027-01-08T00:00:00Z", strategy: .iso8601)))
        let asked = try #require(stub.requested.last?.query)
        #expect(asked.contains("first_air_date.gte=2026-09-23"))
    }

    @Test func filmGenresAreTheirOwnList() async throws {
        stub.stub("/genre/movie/list", json: #"{"genres":[{"id":28,"name":"Action"}]}"#)

        #expect(try await provider().genres(of: .movie) == [TMDBGenre(id: 28, name: "Action")])
        #expect(stub.requested.last?.path == "/3/genre/movie/list")
    }

    @Test func genresNeedAToken() async throws {
        await #expect(throws: SlateError.missingCredential(.tmdb)) {
            try await TMDBProvider(accessToken: "", transport: stub.transport).genres(of: .movie)
        }
    }

    /// Today is the viewer's: at 20:00 in California it's already tomorrow in UTC, and
    /// tomorrow's releases are still to come.
    @Test func upcomingCountsTodayInTheViewersCalendar() async throws {
        stub.stub("/discover/movie", json: """
        {"results":[{"id":1,"title":"Today","release_date":"2026-09-23"},
                    {"id":2,"title":"Tomorrow","release_date":"2026-09-24"}]}
        """)
        var california = Calendar(identifier: .gregorian)
        california.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 20:00 on the 23rd in California, 03:00 on the 24th in UTC.
        let evening = try Date("2026-09-24T03:00:00Z", strategy: .iso8601)

        let films = try await provider().upcoming(.movie, after: evening, calendar: california)

        #expect(films.map(\.title) == ["Tomorrow"])
        let asked = try #require(stub.requested.last?.query)
        #expect(asked.contains("primary_release_date.gte=2026-09-23"))
    }

    @Test func aFilmographyIsBothDepartmentsNewestFirst() async throws {
        stub.stub("/person/1/combined_credits", json: """
        {"cast":[{"id":10,"media_type":"movie","title":"Old","release_date":"1999-01-01"},
                 {"id":11,"media_type":"movie","title":"New","release_date":"2021-01-01"}],
         "crew":[{"id":12,"media_type":"tv","name":"Directed","first_air_date":"2010-01-01"}]}
        """)

        let credits = try await provider().filmography(personID: 1)

        // Splitting acting from directing would make a caller ask twice to show
        // one filmography.
        #expect(credits.map(\.title) == ["New", "Directed", "Old"])
    }

    @Test func aPersonCarriesWhatADetailPageShows() async throws {
        stub.stub("/person/287", json: """
        {"id":287,"name":"Brad Pitt","biography":"An actor.","birthday":"1963-12-18",
         "profile_path":"/p.jpg","known_for_department":"Acting"}
        """)

        let person = try #require(await provider().person(id: 287))

        #expect(person.name == "Brad Pitt")
        #expect(person.department == "Acting")
        #expect(person.birthday != nil)
        #expect(person.deathday == nil, "absent, not guessed")
        #expect(person.profileURL?.absoluteString.hasSuffix("/p.jpg") == true)
    }

    @Test func aPersonSearchCarriesPopularitySoNamesakesCanBeToldApart() async throws {
        stub.stub("/search/person", json: """
        {"results":[
          {"id":115440,"name":"Sydney Sweeney","profile_path":"/a.jpg","known_for_department":"Acting","popularity":88.4},
          {"id":2,"name":"Sydney Sweeney","profile_path":"/b.jpg","known_for_department":"Acting","popularity":1.9}]}
        """)

        let people = try await provider().searchPeople("Sydney Sweeney")

        #expect(people.map(\.id) == [115440, 2])
        #expect(people.map(\.popularity) == [88.4, 1.9])
    }

    @Test func changingLanguageKeepsTheAllowanceAndDropsTheCache() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        stub.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        let tmdb = provider()
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let before = stub.requested.count

        await tmdb.updateLanguage("fr-FR")
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        // Rebuilding the provider instead would have reset the request allowance
        // too — unpaced at the moment a user is making the most requests.
        #expect(stub.requested.count > before, "cached answers were in the old language")
        #expect(stub.requested.contains { $0.absoluteString.contains("language=fr-FR") })
    }

    @Test func settingTheSameLanguageTwiceKeepsTheCache() async throws {
        stub.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        stub.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        let tmdb = provider()
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let before = stub.requested.count

        await tmdb.updateLanguage("en-US")
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        #expect(stub.requested.count == before)
    }
  }
}

extension TMDBRequestTests {
  struct BrowseRegion {
    let stub = Stub()
    /// The 1959-film-in-this-week's-releases bug: TMDB's release-date windows
    /// are per country, and unscoped they mean "released somewhere on earth".
    @Test func aPublishedListIsScopedToTheRegion() async throws {
        stub.stub("/movie/upcoming", json: #"{"results":[{"id":1,"title":"X"}]}"#)

        let provider = TMDBProvider(accessToken: "t", region: "FR", transport: stub.transport)
        _ = try await provider.titles(in: .upcomingMovies)

        let asked = try #require(stub.requested.last?.query)
        #expect(asked.contains("region=FR"))
    }

    /// The other half: a name someone typed should be findable whatever country
    /// it came out in.
    @Test func searchIsNotScopedToTheRegion() async throws {
        stub.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)

        let provider = TMDBProvider(accessToken: "t", region: "FR", transport: stub.transport)
        _ = try await provider.candidates(for: "X", kind: .movie)

        let asked = try #require(stub.requested.last?.query)
        #expect(!asked.contains("region="))
    }
}
}

struct CollectionTests {
    let stub = Stub()

    private func tmdb(language: String = "en-US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, transport: stub.transport)
    }

    @Test func aCollectionListsItsFilmsInReleaseOrder() async throws {
        stub.stub("/collection/726871", json: """
        {"id":726871,"name":"Dune Collection","parts":[
          {"id":693134,"title":"Dune: Part Two","release_date":"2024-02-27","poster_path":"/2.jpg"},
          {"id":1170608,"title":"Dune: Part Three","poster_path":"/3.jpg"},
          {"id":438631,"title":"Dune","release_date":"2021-09-15","poster_path":"/1.jpg"}]}
        """)
        let films = try await tmdb().collection(id: 726871)
        #expect(films.map(\.title) == ["Dune", "Dune: Part Two", "Dune: Part Three"], "undated last")
        #expect(films.allSatisfy { $0.kind == .movie })
    }
}

struct LightLookupTests {
    let stub = Stub()

    @Test func aTMDBIDAsksTheBarePageInTheViewersLanguage() async throws {
        stub.stub("/movie/129", json: """
        {"id":129,"imdb_id":"tt0245429","title":"Le Voyage de Chihiro","release_date":"2001-07-20",
         "original_language":"ja","popularity":45.5,"genres":[{"id":16,"name":"Animation"}],"poster_path":"/p.jpg"}
        """)
        let tmdb = TMDBProvider(accessToken: "t", language: "fr-FR", transport: stub.transport)
        let film = try #require(await tmdb.candidate(for: Identifiers(tmdb: 129), kind: .movie))
        #expect(film.title == "Le Voyage de Chihiro")
        #expect(film.ids == Identifiers(imdb: "tt0245429", tmdb: 129))
        #expect(film.genreIDs == [16])
        #expect(film.originalLanguage == "ja")
        #expect(film.popularity == 45.5)
        let asked = try #require(stub.requested.first)
        #expect(asked.path == "/3/movie/129")
        #expect(asked.query == "language=fr-FR", "nothing appended")
    }

    @Test func anIMDbIDGoesThroughFind() async throws {
        stub.stub("/find/tt0245429", json: """
        {"movie_results":[{"id":129,"media_type":"movie","title":"Spirited Away","genre_ids":[16,14],
          "original_language":"ja","popularity":45.5}],"tv_results":[{"id":9,"media_type":"tv","name":"Not it"}]}
        """)
        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        let film = try #require(await tmdb.candidate(for: Identifiers(imdb: "tt0245429"), kind: .movie))
        #expect(film.ids == Identifiers(imdb: "tt0245429", tmdb: 129))
        #expect(film.genreIDs == [16, 14])
        #expect(try await tmdb.candidate(for: Identifiers(imdb: "tt0245429"), kind: .series)?.title == "Not it")
        #expect(try await tmdb.candidate(for: Identifiers(), kind: .movie) == nil)
    }
}

struct CorrectedSearchTests {
    let stub = Stub()

    @Test func aMisspelledTitleIsSearchedByItsBeginning() async throws {
        stub.respond { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "query" }?.value
            return .init(body: query == "incep"
                ? #"{"results":[{"id":27205,"media_type":"movie","title":"Inception"},{"id":2,"media_type":"movie","title":"Incendies"}]}"#
                : #"{"results":[]}"#)
        }
        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        let (results, correction) = try await tmdb.candidates(correcting: "inceptoin")
        #expect(results.map(\.title) == ["Inception"])
        #expect(correction == "Inception")
    }

    @Test func aTitleFoundAsTypedIsNotCorrected() async throws {
        stub.stub("/search/multi", json: #"{"results":[{"id":1,"media_type":"movie","title":"Up"}]}"#)
        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        let (results, correction) = try await tmdb.candidates(correcting: "up")
        #expect(results.map(\.title) == ["Up"])
        #expect(correction == nil)
        #expect(stub.requested.count == 1)
    }

    @Test func aMisspelledNameFindsThePersonFirst() async throws {
        stub.respond { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "query" }?.value
            return .init(body: query == "sweeney"
                ? #"{"results":[{"id":1,"name":"Sydney Sweeney","popularity":90},{"id":2,"name":"Todd Sweeney","popularity":5}]}"#
                : #"{"results":[{"id":3,"name":"Sidney Lumet","popularity":10}]}"#)
        }
        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        let (people, correction) = try await tmdb.searchPeople(correcting: "sidney sweeney")
        #expect(correction == "Sydney Sweeney")
        #expect(people.map(\.id) == [1, 3], "the correction first, then what the query found")
    }

    /// Typed as far as "sidney sw": the start of the name is misspelled and the rest isn't typed
    /// yet. What TMDB's API answered on 2026-09-25: "Sidney sw" finds Sidney Sweibel and Matthew
    /// Sweet, "sw" and "sid" never Sydney Sweeney, "Sydney sw" Sydney Sweeney first.
    @Test func aHalfTypedMisspelledNameFindsThePerson() async throws {
        stub.respond { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "query" }?.value
            let body = switch query {
            case "sydney sw":
                #"{"results":[{"id":1,"name":"Sydney Sweeney","popularity":14},{"id":7,"name":"Sydney Swihart","popularity":0.5}]}"#
            case "sw":
                #"{"results":[{"id":8,"name":"Andi SW","popularity":0.3},{"id":4,"name":"Tilda Swinton","popularity":4}]}"#
            default:
                #"{"results":[{"id":5,"name":"Sidney Sweibel","popularity":0.3},{"id":6,"name":"Matthew Sweet","popularity":0.8}]}"#
            }
            return .init(body: body)
        }
        let tmdb = TMDBProvider(accessToken: "t", transport: stub.transport)
        let (people, correction) = try await tmdb.searchPeople(correcting: "sidney sw")
        #expect(correction == "Sydney Sweeney")
        #expect(people.first?.id == 1)
        #expect(!people.contains { $0.id == 4 }, "a popular Sw… who isn't a Sidney stays out")
        // The query, then the spelling that found her: nothing more asked.
        #expect(stub.requested.count == 2)
    }

    @Test func editDistanceIgnoresCaseAndAccents() {
        #expect(TMDBProvider.distance("sidney sweeney", "Sydney Sweeney") == 1)
        #expect(TMDBProvider.distance("Timothee Chalamet", "Timothée Chalamet") == 0)
        #expect(TMDBProvider.distance("", "abc") == 3)
        #expect(TMDBProvider.nearbyQueries("inceptoin") == ["incep"])
        #expect(TMDBProvider.nearbyQueries("sidney sweeney") == ["sweeney", "swee", "sidney"])
        #expect(TMDBProvider.nearbyQueries("up").isEmpty)
        // A last word still being typed is searched as it is: TMDB matches it as a name's start.
        #expect(TMDBProvider.nearbyQueries("sidney sw") == ["sw", "sid"])
        // One letter swapped at a time, in words of four letters or more; two at most.
        #expect(TMDBProvider.spellingVariants("sidney sw") == ["sydney sw", "sidnei sw"])
        #expect(TMDBProvider.spellingVariants("Kylie Minogue") == ["Kilie Minogue", "Kylye Minogue"])
        #expect(TMDBProvider.spellingVariants("tom hanks").isEmpty)
    }
}
