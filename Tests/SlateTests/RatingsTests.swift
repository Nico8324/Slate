import Foundation
import Testing
@testable import Slate

private func mdbList() -> MDBListProvider {
    MDBListProvider(apiKey: "test-key", session: StubURLProtocol.session)
}

// Nested in the serialized suite that owns the stub table: sibling suites run in
// parallel and race each other's routes.
extension TMDBRequestTests {
  @Suite(.serialized)
  struct Ratings {

    @Test func everySiteIsKeptSeparatelyOnItsOwnScale() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/imdb/movie/tt0133093", json: """
        {"imdb_id":"tt0133093","title":"The Matrix","type":"movie","score":88,
         "ratings":[{"source":"imdb","value":8.7,"votes":2000000},
                    {"source":"metacritic","value":73},
                    {"source":"letterboxd","value":4.3},
                    {"source":"tomatoes","value":83}]}
        """)

        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt0133093", kind: .movie)))
        let ratings = try #require(snapshot.ratings)

        #expect(ratings.count == 4)
        // Normalised so two sources are comparable...
        #expect(ratings.first { $0.source == "metacritic" }?.value == 7.3)
        #expect(ratings.first { $0.source == "letterboxd" }?.value == 8.6)
        // ...and the site's own number still recoverable, because 73% and 7.3
        // read differently to a person.
        #expect(ratings.first { $0.source == "metacritic" }?.native == 73)
        #expect(ratings.first { $0.source == "letterboxd" }?.native == 4.3)
        #expect(ratings.first { $0.source == "imdb" }?.votes == 2000000)
    }

    @Test func theBlendedScoreIsNotReportedAsARating() async throws {
        // MDBList's own `score` is an average of the sites it lists. Reporting
        // it would put an average where a source belongs.
        StubURLProtocol.reset()
        StubURLProtocol.stub("/imdb/movie/tt1", json: """
        {"imdb_id":"tt1","score":88,"ratings":[{"source":"imdb","value":8.7}]}
        """)

        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt1", kind: .movie)))
        #expect(snapshot.rating == nil)
        #expect(snapshot.ratings?.count == 1)
    }

    @Test func aSiteWithNoScoreIsDroppedRatherThanScoredZero() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/imdb/movie/tt2", json: """
        {"imdb_id":"tt2","ratings":[{"source":"imdb","value":7.1},
                                    {"source":"letterboxd","value":null},
                                    {"source":"tomatoes","value":0}]}
        """)

        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt2", kind: .movie)))
        #expect(snapshot.ratings?.map(\.source) == ["imdb"])
    }

    @Test func withoutAnIDItAsksNothingRatherThanSearching() async throws {
        StubURLProtocol.reset()
        // MDBList has no title search, so a name-only lookup is unanswerable.
        #expect(MDBListProvider.route(for: Lookup(search: "The Matrix", kind: .movie)) == nil)
        #expect(try await mdbList().snapshot(for: Lookup(search: "The Matrix", kind: .movie)) == nil)
        #expect(StubURLProtocol.requested.isEmpty, "and it made no request to find that out")
    }

    @Test func idRoutesPreferIMDbThenTMDB() {
        #expect(MDBListProvider.route(for: Lookup(ids: Identifiers(imdb: "tt9", tmdb: 5), kind: .series))
                == "/imdb/show/tt9/")
        #expect(MDBListProvider.route(for: Lookup(ids: Identifiers(tmdb: 5), kind: .movie))
                == "/tmdb/movie/5/")
        #expect(MDBListProvider.route(for: Lookup(ids: Identifiers(myAnimeList: 21)))
                == "/mal/any/21/")
    }

    @Test func anIDOnlyProviderIsAskedAgainOnceTheIDsAreKnown() async throws {
        StubURLProtocol.reset()
        // A search by name: TMDB finds the id, MDBList could not have.
        StubURLProtocol.stub("/search/movie", json: #"{"results":[{"id":603,"title":"The Matrix","popularity":9}]}"#)
        StubURLProtocol.stub("/movie/603", json: #"{"id":603,"imdb_id":"tt0133093","title":"The Matrix"}"#)
        StubURLProtocol.stub("/imdb/movie/tt0133093", json: """
        {"imdb_id":"tt0133093","ratings":[{"source":"imdb","value":8.7}]}
        """)

        let slate = MetadataAggregator(providers: [
            TMDBProvider(accessToken: "t", session: StubURLProtocol.session),
            mdbList(),
        ])
        let result = await slate.metadata(for: Lookup(search: "The Matrix", kind: .movie))

        #expect(result.ids.imdb == "tt0133093")
        #expect(result.ratings.best?.count == 1, "MDBList answered on the second pass")
        #expect(result.provenance[.ratings] == .mdbList)
    }

    @Test func theSecondPassDoesNotHappenWhenNothingNewWasLearned() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/imdb/movie/tt5", json: #"{"imdb_id":"tt5","ratings":[{"source":"imdb","value":6}]}"#)

        let slate = MetadataAggregator(providers: [mdbList()])
        _ = await slate.metadata(for: Lookup(imdbID: "tt5", kind: .movie))

        #expect(StubURLProtocol.requested.count == 1, "the id was known from the start")
    }

    @Test func theKeyRidesAsABearerHeaderAndNeverInTheURL() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/imdb/movie/tt6", json: #"{"imdb_id":"tt6"}"#)
        _ = try? await mdbList().snapshot(for: Lookup(imdbID: "tt6", kind: .movie))

        // MDBList also accepts ?apikey=; Slate deliberately does not use it.
        #expect(!StubURLProtocol.requested.contains { $0.absoluteString.contains("apikey") })
        #expect(!StubURLProtocol.requested.contains { $0.absoluteString.contains("test-key") })
    }
}
}
