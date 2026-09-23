import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  @Suite(.serialized)
  struct Browsing {
    private func provider() -> TMDBProvider {
        TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
    }

    @Test func aSearchReturnsEveryCandidateInsteadOfPickingOne() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/multi", json: """
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
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/popular", json: """
        {"results":[{"id":1,"name":"A","first_air_date":"2020-01-01"},
                    {"id":2,"name":"B","first_air_date":"2021-01-01"}]}
        """)

        let titles = try await provider().titles(in: .popularShows)

        #expect(titles.count == 2)
        #expect(titles.allSatisfy { $0.kind == .series })
    }

    @Test func aTrendingListStatesTheKindPerRow() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/trending/all/week", json: """
        {"results":[{"id":1,"media_type":"movie","title":"A","release_date":"2020-01-01"},
                    {"id":2,"media_type":"tv","name":"B"},
                    {"id":3,"media_type":"person","name":"C"}]}
        """)

        let titles = try await provider().titles(in: .trendingThisWeek)

        #expect(titles.map(\.kind) == [.movie, .series])
    }

    @Test func genresAreListedPerKind() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/genre/tv/list", json: #"{"genres":[{"id":10759,"name":"Action & Adventure"}]}"#)

        let genres = try await provider().genres(of: .series)

        #expect(genres == [TMDBGenre(id: 10759, name: "Action & Adventure")])
    }

    @Test func aGenreIsBrowsedByPopularityAmongTitlesPeopleRated() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/discover/movie", json: #"{"results":[{"id":1,"title":"A","release_date":"2020-01-01"}]}"#)

        let titles = try await provider().titles(inGenre: 28, kind: .movie, page: 2)

        #expect(titles.map(\.kind) == [.movie])
        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(asked.contains("with_genres=28"))
        #expect(asked.contains("sort_by=popularity.desc"))
        #expect(asked.contains("vote_count.gte=50"))
        #expect(asked.contains("page=2"))
    }

    @Test func aGenrePagePastTheLastIsEmptyWithoutAsking() async throws {
        StubURLProtocol.reset()
        #expect(try await provider().titles(inGenre: 28, kind: .movie, page: TMDBProvider.lastPage + 1).isEmpty)
        #expect(StubURLProtocol.requested.isEmpty)
    }

    @Test func upcomingFilmsAreThoseNotOutYetWithTheirDates() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/discover/movie", json: """
        {"results":[{"id":1,"title":"Soon","release_date":"2027-03-12","backdrop_path":"/b.jpg"},
                    {"id":2,"title":"Today","release_date":"2026-09-23"},
                    {"id":3,"title":"Undated"}]}
        """)
        let day = try Date("2026-09-23T12:00:00Z", strategy: .iso8601)

        let films = try await provider().upcoming(.movie, after: day)

        #expect(films.map(\.title) == ["Soon"])
        #expect(films.first?.releaseDate == (try Date("2027-03-12T00:00:00Z", strategy: .iso8601)))
        #expect(films.first?.backdropURL != nil)
        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(asked.contains("primary_release_date.gte=2026-09-23"))
        #expect(asked.contains("sort_by=popularity.desc"))
    }

    @Test func upcomingShowsAreThosePremieringLater() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/discover/tv", json: #"{"results":[{"id":1,"name":"New","first_air_date":"2027-01-08","original_language":"ja","genre_ids":[16,10759]}]}"#)
        let day = try Date("2026-09-23T12:00:00Z", strategy: .iso8601)

        let shows = try await provider().upcoming(.series, after: day)

        #expect(shows.map(\.kind) == [.series])
        #expect(shows.first?.originalLanguage == "ja")
        #expect(shows.first?.genreIDs == [16, 10759])
        #expect(shows.first?.releaseDate == (try Date("2027-01-08T00:00:00Z", strategy: .iso8601)))
        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(asked.contains("first_air_date.gte=2026-09-23"))
    }

    @Test func filmGenresAreTheirOwnList() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/genre/movie/list", json: #"{"genres":[{"id":28,"name":"Action"}]}"#)

        #expect(try await provider().genres(of: .movie) == [TMDBGenre(id: 28, name: "Action")])
        #expect(StubURLProtocol.requested.last?.path == "/3/genre/movie/list")
    }

    @Test func genresNeedAToken() async throws {
        await #expect(throws: SlateError.missingCredential(.tmdb)) {
            try await TMDBProvider(accessToken: "", session: StubURLProtocol.session).genres(of: .movie)
        }
    }

    /// Today is the viewer's: at 20:00 in California it's already tomorrow in UTC, and
    /// tomorrow's releases are still to come.
    @Test func upcomingCountsTodayInTheViewersCalendar() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/discover/movie", json: """
        {"results":[{"id":1,"title":"Today","release_date":"2026-09-23"},
                    {"id":2,"title":"Tomorrow","release_date":"2026-09-24"}]}
        """)
        var california = Calendar(identifier: .gregorian)
        california.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 20:00 on the 23rd in California, 03:00 on the 24th in UTC.
        let evening = try Date("2026-09-24T03:00:00Z", strategy: .iso8601)

        let films = try await provider().upcoming(.movie, after: evening, calendar: california)

        #expect(films.map(\.title) == ["Tomorrow"])
        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(asked.contains("primary_release_date.gte=2026-09-23"))
    }

    @Test func aFilmographyIsBothDepartmentsNewestFirst() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/person/1/combined_credits", json: """
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
        StubURLProtocol.reset()
        StubURLProtocol.stub("/person/287", json: """
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
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/person", json: """
        {"results":[
          {"id":115440,"name":"Sydney Sweeney","profile_path":"/a.jpg","known_for_department":"Acting","popularity":88.4},
          {"id":2,"name":"Sydney Sweeney","profile_path":"/b.jpg","known_for_department":"Acting","popularity":1.9}]}
        """)

        let people = try await provider().searchPeople("Sydney Sweeney")

        #expect(people.map(\.id) == [115440, 2])
        #expect(people.map(\.popularity) == [88.4, 1.9])
    }

    @Test func changingLanguageKeepsTheAllowanceAndDropsTheCache() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        let tmdb = provider()
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let before = StubURLProtocol.requested.count

        await tmdb.updateLanguage("fr-FR")
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        // Rebuilding the provider instead would have reset the request allowance
        // too — unpaced at the moment a user is making the most requests.
        #expect(StubURLProtocol.requested.count > before, "cached answers were in the old language")
        #expect(StubURLProtocol.requested.contains { $0.absoluteString.contains("language=fr-FR") })
    }

    @Test func settingTheSameLanguageTwiceKeepsTheCache() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        let tmdb = provider()
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let before = StubURLProtocol.requested.count

        await tmdb.updateLanguage("en-US")
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        #expect(StubURLProtocol.requested.count == before)
    }
  }
}

extension TMDBRequestTests {
  @Suite(.serialized)
  struct BrowseRegion {
    /// The 1959-film-in-this-week's-releases bug: TMDB's release-date windows
    /// are per country, and unscoped they mean "released somewhere on earth".
    @Test func aPublishedListIsScopedToTheRegion() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/movie/upcoming", json: #"{"results":[{"id":1,"title":"X"}]}"#)

        let provider = TMDBProvider(accessToken: "t", region: "FR", session: StubURLProtocol.session)
        _ = try await provider.titles(in: .upcomingMovies)

        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(asked.contains("region=FR"))
    }

    /// The other half: a name someone typed should be findable whatever country
    /// it came out in.
    @Test func searchIsNotScopedToTheRegion() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)

        let provider = TMDBProvider(accessToken: "t", region: "FR", session: StubURLProtocol.session)
        _ = try await provider.candidates(for: "X", kind: .movie)

        let asked = try #require(StubURLProtocol.requested.last?.query)
        #expect(!asked.contains("region="))
    }
}
}
