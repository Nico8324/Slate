import Foundation
import Testing
@testable import Slate

/// The 2026-09-23 review: what Cinema needed from Slate, and the bugs found
/// reading it for that. Nested under `TMDBRequestTests` because it shares the
/// stubbed network, which only one suite at a time may drive.
extension TMDBRequestTests {
@Suite(.serialized)
struct ReviewFixes {

    private func tmdb(language: String = "en-US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, session: StubURLProtocol.session)
    }

    private func stubFilm(_ json: String) {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/movie", json: #"{"results":[{"id":1,"title":"X"}]}"#)
        StubURLProtocol.stub("/movie/1", json: json)
    }

    // MARK: - Crew

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
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":2,"name":"Tulsa King"}]}"#)
        StubURLProtocol.stub("/tv/2", json: """
        {"id":2,"name":"Tulsa King","created_by":[{"id":9,"name":"Taylor Sheridan"}]}
        """)
        let crew = try #require(await tmdb().snapshot(for: Lookup(search: "Tulsa King", kind: .series))?.crew)
        #expect(crew == [CrewMember(personID: 9, name: "Taylor Sheridan", job: "Creator", department: .creator)])
    }

    // MARK: - Trailers

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
        let details = try #require(StubURLProtocol.requested.first { $0.path == "/3/movie/1" })
        #expect(details.query?.contains("include_video_language=fr,en,null") == true,
                "without it a French lookup never saw the studio's own trailers")
    }

    @Test func aThirdLanguageFilmAsksForItsOwnTrailersOnce() async throws {
        stubFilm(#"{"id":1,"title":"X","original_language":"ja","videos":{"results":[]}}"#)
        StubURLProtocol.stub("/movie/1/videos", json: """
        {"results":[{"key":"jp","site":"YouTube","type":"Trailer","iso_639_1":"ja"}]}
        """)
        let snapshot = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie)))
        #expect(snapshot.trailerYouTubeID == "jp")
        #expect(StubURLProtocol.requested.filter { $0.path == "/3/movie/1/videos" }.count == 1)
    }

    // MARK: - Recommendations, ratings, cast, images

    @Test func recommendationsRideOnTheDetailsRequest() async throws {
        stubFilm("""
        {"id":1,"title":"X","recommendations":{"results":[
          {"id":8,"media_type":"movie","title":"Y","release_date":"2020-01-01"},
          {"id":9,"media_type":"person","name":"Not a title"}]}}
        """)
        let recommended = try #require(await tmdb().snapshot(for: Lookup(search: "X", kind: .movie))?.recommendations)
        #expect(recommended.map(\.title) == ["Y"])
        #expect(StubURLProtocol.requested.filter { $0.path.hasPrefix("/3/movie/") }.count == 1)
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

    // MARK: - Seasons

    @Test func aFilmHasNoSeasonsAndNoRequestIsMade() async throws {
        StubURLProtocol.reset()
        #expect(try await tmdb().seasons(for: Identifiers(tmdb: 603), kind: .movie) == nil)
        #expect(StubURLProtocol.requested.isEmpty)
    }

    @Test func aFallbackAfterAFailedRequestIsNotCached() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"seasons":[{"season_number":1,"episode_count":366}]}"#)
        StubURLProtocol.stub("/tv/1/episode_groups", .init(status: 404, body: "{}"))
        let provider = tmdb()
        let first = try await provider.seasons(for: Identifiers(tmdb: 1))
        #expect(first?.ordering == .native)
        let groupRequests = StubURLProtocol.requested.filter { $0.path.hasSuffix("/episode_groups") }.count
        _ = try await provider.seasons(for: Identifiers(tmdb: 1))
        #expect(StubURLProtocol.requested.filter { $0.path.hasSuffix("/episode_groups") }.count > groupRequests,
                "asked again rather than serving the fallback for the cache's lifetime")
    }

    @Test func episodesCarryTheirRunningTime() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/tv/1/season/1", json: """
        {"episodes":[{"episode_number":1,"runtime":65},{"episode_number":2,"runtime":0}]}
        """)
        let episodes = try await tmdb().episodes(ofShow: 1, nativeSeason: 1)
        #expect(episodes.map(\.runtimeMinutes) == [65, nil])
    }

    @Test func twoSpecialsGroupsBecomeOneSeasonZero() {
        typealias Payload = TMDBProvider.EpisodeGroupPayload
        func item(_ season: Int, _ episode: Int) -> Payload.Entry.Item {
            .init(id: nil, name: nil, air_date: nil, season_number: season, episode_number: episode)
        }
        let seasons = TMDBProvider.seasons(from: Payload(id: "g", name: "g", groups: [
            .init(order: 0, name: "Specials", episodes: [item(0, 1), item(0, 2)]),
            .init(order: 1, name: "Arc", episodes: [item(1, 1)]),
            .init(order: 2, name: "OVAs", episodes: [item(0, 3)]),
        ]))
        #expect(seasons.map(\.number) == [0, 1])
        #expect(seasons.first?.episodes?.map(\.number) == [1, 2, 3])
        #expect(seasons.first?.episodes?.last?.native == EpisodePosition(season: 0, episode: 3))
    }

    // MARK: - Lookups

    @Test func aBareTMDBIDWithoutAKindIsAnInvalidQuestion() async {
        await #expect(throws: SlateError.invalidLookup) {
            try await tmdb().snapshot(for: Lookup(ids: Identifiers(tmdb: 1399)))
        }
    }

    @Test func aLooseMatchLosesAKindConflictToAPreciseOne() {
        var loose = Snapshot(ids: Identifiers(aniList: 1), kind: .series, title: "Love Live!")
        loose.matchedLoosely = true
        let precise = Snapshot(ids: Identifiers(imdb: "tt3", tmdb: 3), kind: .movie, title: "Love")
        let result = MetadataAggregator(providers: []).assemble([.aniList: loose, .tmdb: precise])
        #expect(result.kind.best == .movie)
        #expect(result.ids.imdb == "tt3")
        #expect(result.failures[.aniList] != nil)
    }

    @Test func idsLearnedMidLookupAreNotTreatedAsExplicit() async {
        struct TMDBLike: MetadataProvider {
            let provider = Provider.tmdb
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                Snapshot(ids: Identifiers(imdb: "tt1"), kind: .series, title: "TMDB")
            }
        }
        struct Bridge: MetadataProvider {
            let provider = Provider.fribb
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                lookup.ids.imdb == nil ? nil : Snapshot(ids: Identifiers(aniList: 10, myAnimeList: 5))
            }
        }
        struct AniListLike: MetadataProvider {
            let provider = Provider.aniList
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                lookup.ids.aniList == nil ? nil
                    : Snapshot(ids: Identifiers(aniList: 10, myAnimeList: 6), kind: .series, title: "AniList")
            }
        }
        let result = await MetadataAggregator(providers: [TMDBLike(), Bridge(), AniListLike()])
            .metadata(for: Lookup(search: "X"))
        #expect(result.title.value(from: .aniList) == "AniList",
                "the bridge's MyAnimeList id disagreed, which priority settles — not a rejection")
    }

    @Test func artworkWithNoLanguageOrRatingRanksLast() throws {
        let banner = Artwork(kind: .backdrop, url: URL(string: "https://a.invalid/banner.jpg")!, provider: .aniList)
        let backdrop = Artwork(kind: .backdrop, url: URL(string: "https://t.invalid/b.jpg")!,
                               language: "en", rating: 0, provider: .tmdb)
        let set = ArtworkSet(backdrops: [banner, backdrop])
        #expect(set.best(.backdrop)?.provider == .tmdb)
    }

    // MARK: - Transport

    @Test func aZeroLifetimeCacheKeepsNothing() async {
        let cache = ResponseCache(ttl: 0)
        await cache.store(Data([1, 2, 3]), for: "k")
        #expect(await cache.data(for: "k") == nil)
    }

    @Test func theCacheStaysWithinItsByteBudget() async {
        let cache = ResponseCache(limit: 10, ttl: 60, byteLimit: 5)
        await cache.store(Data([1, 2, 3]), for: "a")
        await cache.store(Data([4, 5, 6]), for: "b")
        #expect(await cache.data(for: "a") == nil, "evicted, oldest first")
        #expect(await cache.data(for: "b") != nil)
    }

    @Test func aDroppedConnectionIsRetriedButACancelledOneIsNot() {
        #expect(HTTP.isTransient(URLError(.timedOut)))
        #expect(HTTP.isTransient(URLError(.networkConnectionLost)))
        #expect(!HTTP.isTransient(URLError(.cancelled)))
        #expect(!HTTP.isTransient(URLError(.badServerResponse)))
    }

    // MARK: - Lists

    @Test func officialListsReadTheAskedKindInRankOrder() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond { request in
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
        let mdbList = MDBListProvider(apiKey: "key", session: StubURLProtocol.session)
        let page = try await mdbList.titles(in: .imdbMovieMeter, kind: .movie)

        #expect(page.titles.map(\.title) == ["The Housemaid", "Tenet"], "rank order; a row nothing can look up is dropped")
        #expect(page.titles.first?.ids == Identifiers(imdb: "tt27543632", tmdb: 1368166))
        #expect(page.titles.first?.posterURL != nil)
        #expect(page.titles.first?.provider == .mdbList)
        #expect(page.nextCursor == "abc")
    }

    @Test func officialListsWithoutAKeySaySo() async {
        await #expect(throws: SlateError.missingCredential(.mdbList)) {
            try await MDBListProvider(apiKey: "", session: StubURLProtocol.session).titles(in: .trending, kind: .series)
        }
    }
}
}
