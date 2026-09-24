import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  struct Ratings {
    let stub = Stub()

    private func mdbList() -> MDBListProvider {
        MDBListProvider(apiKey: "test-key", transport: stub.transport)
    }

    @Test func everySiteIsKeptSeparatelyOnItsOwnScale() async throws {
        stub.stub("/imdb/movie/tt0133093", json: """
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

    /// Trakt and TMDB send percentages and Metacritic's users score out of ten; a table that
    /// assumed ten for everything unlisted read Trakt's 85 as 85 out of 10.
    @Test func sitesOutsideTheOldTableLandOnTheirOwnScales() async throws {
        stub.stub("/imdb/movie/tt0133094", json: """
        {"imdb_id":"tt0133094","title":"X","type":"movie",
         "ratings":[{"source":"trakt","value":85},
                    {"source":"metacriticuser","value":8.9},
                    {"source":"rogerebert","value":4},
                    {"source":"tmdb","value":70,"score":70}]}
        """)
        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt0133094", kind: .movie)))
        let ratings = try #require(snapshot.ratings)
        #expect(ratings.first { $0.source == "trakt" }?.value == 8.5)
        #expect(ratings.first { $0.source == "metacriticuser" }?.value == 8.9)
        #expect(ratings.first { $0.source == "rogerebert" }?.value == 10)
        #expect(ratings.first { $0.source == "tmdb" }?.value == 7)
        #expect(ratings.allSatisfy { $0.value <= 10 })
    }

    @Test func theBlendedScoreIsNotReportedAsARating() async throws {
        // MDBList's own `score` is an average of the sites it lists. Reporting
        // it would put an average where a source belongs.
        stub.stub("/imdb/movie/tt1", json: """
        {"imdb_id":"tt1","score":88,"ratings":[{"source":"imdb","value":8.7}]}
        """)

        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt1", kind: .movie)))
        #expect(snapshot.rating == nil)
        #expect(snapshot.ratings?.count == 1)
    }

    @Test func aSiteWithNoScoreIsDroppedRatherThanScoredZero() async throws {
        stub.stub("/imdb/movie/tt2", json: """
        {"imdb_id":"tt2","ratings":[{"source":"imdb","value":7.1},
                                    {"source":"letterboxd","value":null},
                                    {"source":"tomatoes","value":0}]}
        """)

        let snapshot = try #require(await mdbList().snapshot(for: Lookup(imdbID: "tt2", kind: .movie)))
        #expect(snapshot.ratings?.map(\.source) == ["imdb"])
    }

    @Test func withoutAnIDItAsksNothingRatherThanSearching() async throws {
        // MDBList has no title search, so a name-only lookup is unanswerable.
        #expect(MDBListProvider.route(for: Lookup(search: "The Matrix", kind: .movie)) == nil)
        #expect(try await mdbList().snapshot(for: Lookup(search: "The Matrix", kind: .movie)) == nil)
        #expect(stub.requested.isEmpty, "and it made no request to find that out")
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
        // A search by name: TMDB finds the id, MDBList could not have.
        stub.stub("/search/movie", json: #"{"results":[{"id":603,"title":"The Matrix","popularity":9}]}"#)
        stub.stub("/movie/603", json: #"{"id":603,"imdb_id":"tt0133093","title":"The Matrix"}"#)
        stub.stub("/imdb/movie/tt0133093", json: """
        {"imdb_id":"tt0133093","ratings":[{"source":"imdb","value":8.7}]}
        """)

        let slate = MetadataAggregator(providers: [
            TMDBProvider(accessToken: "t", transport: stub.transport),
            mdbList(),
        ])
        let result = await slate.metadata(for: Lookup(search: "The Matrix", kind: .movie))

        #expect(result.ids.imdb == "tt0133093")
        #expect(result.ratings.best?.count == 1, "MDBList answered on the second pass")
        #expect(result.provenance[.ratings] == .mdbList)
    }

    @Test func theSecondPassDoesNotHappenWhenNothingNewWasLearned() async throws {
        stub.stub("/imdb/movie/tt5", json: #"{"imdb_id":"tt5","ratings":[{"source":"imdb","value":6}]}"#)

        let slate = MetadataAggregator(providers: [mdbList()])
        _ = await slate.metadata(for: Lookup(imdbID: "tt5", kind: .movie))

        #expect(stub.requested.count == 1, "the id was known from the start")
    }

    @Test func theKeyRidesAsTheOnlyFormMDBListAcceptsAndStaysOutOfLogs() async throws {
        stub.stub("/imdb/movie/tt6", json: #"{"imdb_id":"tt6"}"#)
        _ = try? await mdbList().snapshot(for: Lookup(imdbID: "tt6", kind: .movie))

        // MDBList takes an API key only as `?apikey=`. Its `Authorization: Bearer`
        // is for OAuth tokens, and a real key sent that way was answered with 401:
        // this test used to require the opposite, and passed while nothing worked.
        let url = try #require(stub.requested.first)
        #expect(url.query?.contains("apikey=test-key") == true)
        #expect(!Log.redactingQuery(url).contains("test-key"), "what the log prints has no query string")
    }
}
}

extension TMDBRequestTests {
  struct MergedRatings {
    private func assembled() -> TitleMetadata {
        MetadataAggregator(providers: []).assemble([
            .mdbList: Snapshot(ratings: [
                Rating(source: "imdb", value: 8.4),
                Rating(source: "tmdb", value: 8.2, outOf: 10, votes: 1),
            ]),
            .tmdb: Snapshot(ratings: [Rating(source: "tmdb", value: 8.5, outOf: 10, votes: 30_000)]),
            .aniList: Snapshot(ratings: [Rating(source: "anilist", value: 8.4)]),
        ])
    }

    @Test func everySourceSurvivesTheFieldsOneWinner() {
        #expect(assembled().ratings.best?.map(\.source) == ["imdb", "tmdb"],
                "the field itself is unchanged — MDBList still wins it")
        #expect(assembled().allRatings.map(\.source) == ["imdb", "tmdb", "anilist"],
                "AniList's score is not dropped for having lost the field")
    }

    @Test func aSourceTwoProvidersBothReportIsKeptOnce() throws {
        let tmdbEntries = assembled().allRatings.filter { $0.source == "tmdb" }
        #expect(tmdbEntries.count == 1)
        #expect(tmdbEntries.first?.votes == 1,
                "MDBList outranks TMDB for this field, so its spelling of the shared source wins")
    }
  }
}

struct MDBListChartTests {
    let stub = Stub()

    @Test func officialListsReadTheAskedKindInRankOrder() async throws {
        stub.respond { request in
            // MDBList takes an API key only as `?apikey=`; `Bearer` is for OAuth
            // tokens and answered a real key with 401.
            #expect(request.url?.query?.contains("apikey=key") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.path == "/lists/official/moviemeter/items")
            #expect(request.url?.query?.contains("mediatype=movie") == true)
            return .init(body: """
            {"movies":[
              {"rank":2,"title":"Tenet","release_year":2020,"imdb_id":"tt6723592","ids":{"imdb":"tt6723592","tmdb":577922}},
              {"rank":1,"title":"The Housemaid","release_year":2025,"imdb_id":"tt27543632","ids":{"tmdb":1368166},"poster":"https://image.tmdb.org/t/p/w500/p.jpg"},
              {"rank":3,"title":"No ids","release_year":2025}],
             "shows":[{"rank":1,"title":"Tulsa King","imdb_id":"tt16358384"}],
             "pagination":{"next_cursor":"abc"}}
            """)
        }
        let mdbList = MDBListProvider(apiKey: "key", transport: stub.transport)
        let page = try await mdbList.titles(in: .imdbMovieMeter, kind: .movie)

        #expect(page.titles.map(\.title) == ["The Housemaid", "Tenet"], "rank order; a row nothing can look up is dropped")
        #expect(page.titles.first?.ids == Identifiers(imdb: "tt27543632", tmdb: 1368166))
        #expect(page.titles.first?.posterURL != nil)
        #expect(page.titles.first?.provider == .mdbList)
        #expect(page.nextCursor == "abc")
    }

    @Test func officialListsWithoutAKeySaySo() async {
        await #expect(throws: SlateError.missingCredential(.mdbList)) {
            try await MDBListProvider(apiKey: "", transport: stub.transport).titles(in: .trending, kind: .series)
        }
    }
}
