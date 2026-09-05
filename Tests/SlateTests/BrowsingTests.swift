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
