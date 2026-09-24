import Foundation
import Testing
@testable import Slate

/// Bleach's shape: TMDB files the run as one season, and a `TVDB Order`
/// ordering splits it into arcs. Trimmed to three entries.
private let bleachGroupJSON = """
{
  "id": "5e2a1a1e",
  "name": "TVDB Order",
  "groups": [
    { "order": 0, "name": "Specials", "episodes": [
        { "id": 900, "name": "OVA", "season_number": 0, "episode_number": 1 },
        { "id": 901, "name": "OVA 2", "season_number": 0, "episode_number": 2 } ] },
    { "order": 1, "name": "The Substitute", "episodes": [
        \((1...20).map { "{ \"id\": \($0), \"name\": \"Ep \($0)\", \"season_number\": 1, \"episode_number\": \($0) }" }.joined(separator: ",\n")) ] },
    { "order": 2, "name": "The Entry", "episodes": [
        \((21...41).map { "{ \"id\": \($0), \"name\": \"Ep \($0)\", \"season_number\": 1, \"episode_number\": \($0) }" }.joined(separator: ",\n")) ] }
  ]
}
"""

private func bleachStructure() throws -> SeasonStructure {
    let group = try JSONDecoder().decode(
        TMDBProvider.EpisodeGroupPayload.self, from: Data(bleachGroupJSON.utf8)
    )
    return SeasonStructure(
        seasons: TMDBProvider.seasons(from: group),
        orderingName: group.name,
        nativeSeasons: [Season(number: 1, name: "Season 1", episodeCount: 366),
                        Season(number: 2, name: "Thousand-Year Blood War", episodeCount: 13)],
        provider: .tmdb
    )
}

struct FlatteningTests {
    @Test func aLongRunUnderOneNumberIsFlattened() {
        #expect(TMDBProvider.isFlattened([Season(number: 1, episodeCount: 366),
                                          Season(number: 2, episodeCount: 13)]))
    }

    @Test func aLoneSeasonFarLongerThanASeasonIsFlattenedToo() {
        // Jujutsu Kaisen: one season of 59 on TMDB, two seasons everywhere else.
        // It slipped under the 60 bar by a single episode.
        #expect(TMDBProvider.isFlattened([Season(number: 1, episodeCount: 59)]))
        #expect(TMDBProvider.isFlattened([Season(number: 0, episodeCount: 4),
                                          Season(number: 1, episodeCount: 50)]))
    }

    @Test func aLongishSingleSeasonIsNotEvidenceOfAnything() {
        // Frieren is 38 episodes under one number, and read at two cours this
        // split it into 16/12/10 — cours, not seasons, and not how anyone
        // numbers it. Thirty-eight is not unambiguously more than one season.
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 38)]))
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 26)]))
    }

    @Test func ordinaryTelevisionIsLeftAlone() {
        // A twelve-part series genuinely has one season; nothing to fix.
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 12)]))
        // One long season among many is a different, weaker signal than one long
        // season alone — this must stay out.
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 39),
                                           Season(number: 2, episodeCount: 30)]))
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 24),
                                           Season(number: 2, episodeCount: 25)]))
    }

    @Test func specialsDoNotCountAsAFlattenedRun() {
        #expect(!TMDBProvider.isFlattened([Season(number: 0, episodeCount: 90),
                                           Season(number: 1, episodeCount: 12)]))
    }

    private func summary(_ name: String, type: Int, groups: Int, episodes: Int)
    -> TMDBProvider.EpisodeGroupSummary {
        let json = """
        {"id":"\(name)","name":"\(name)","type":\(type),"group_count":\(groups),"episode_count":\(episodes)}
        """
        return try! JSONDecoder().decode(TMDBProvider.EpisodeGroupSummary.self, from: Data(json.utf8))
    }

    @Test func tvdbOrderWinsByName() {
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("Story Arc", type: 5, groups: 21, episodes: 366),
            summary("TVDB Order", type: 1, groups: 16, episodes: 366),
        ], coveringAtLeast: 366)

        #expect(chosen?.name == "TVDB Order")
    }

    @Test func storyArcIsNeverAFallback() {
        // Bleach has three, splitting the same run 21, 12 and 25 ways. Picking
        // one arbitrarily is the silent renumbering this exists to avoid.
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("Arcs", type: 5, groups: 21, episodes: 366),
            summary("Crunchyroll Season Split", type: 5, groups: 12, episodes: 366),
        ], coveringAtLeast: 366)

        #expect(chosen == nil)
    }

    @Test func theShowsOwnDivisionsAreAcceptedWhenNothingBetterExists() {
        // Jujutsu Kaisen's real groups: no TVDB Order, no air-date ordering, so
        // it stayed one season of 59. A `production`/`tv` ordering is what it
        // actually has, and picking it deterministically beats leaving it flat.
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("Italian Parts", type: 4, groups: 3, episodes: 59),
            summary("Story Arcs", type: 5, groups: 7, episodes: 48),
            summary("Saga Española", type: 5, groups: 4, episodes: 69),
            summary("Seasons", type: 6, groups: 4, episodes: 64),
            summary("季", type: 6, groups: 3, episodes: 59),
            summary("Seasons", type: 6, groups: 4, episodes: 69),
        ], coveringAtLeast: 59)

        #expect(chosen?.name == "Seasons")
        #expect(chosen?.episode_count == 64, "tightest coverage of the two named Seasons")
    }

    @Test func aReleasesOwnCutIsNeverTheShowsSeasons() {
        // Digital and DVD orderings are how somebody shipped it, not how it
        // aired; absolute order *is* the flat run being corrected.
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("Absolute", type: 2, groups: 4, episodes: 92),
            summary("Blu-ray Box", type: 3, groups: 6, episodes: 92),
            summary("Italian Parts", type: 4, groups: 3, episodes: 92),
        ], coveringAtLeast: 62)

        #expect(chosen == nil)
    }

    @Test func anOrderingThatMissesEpisodesIsRejected() {
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("TVDB Order", type: 1, groups: 16, episodes: 300),
        ], coveringAtLeast: 366)

        #expect(chosen == nil, "a partial ordering would strand the rest unmapped")
    }
}

struct CorrectionRefusalTests {
    /// Hunter x Hunter's shape: the long run survives as season one and the OVAs
    /// are filed beside it, so nothing was actually fixed.
    private let hunterShaped = """
    { "id": "g", "name": "Complete Series", "groups": [
      { "order": 1, "name": "Hunter x Hunter", "episodes": [
          \((1...62).map { "{ \"season_number\": 1, \"episode_number\": \($0) }" }.joined(separator: ",")) ] },
      { "order": 2, "name": "OVA", "episodes": [
          \((1...8).map { "{ \"season_number\": 2, \"episode_number\": \($0) }" }.joined(separator: ",")) ] } ] }
    """

    @Test func anOrderingThatLeavesTheLongRunStandingIsRefused() throws {
        let group = try JSONDecoder().decode(
            TMDBProvider.EpisodeGroupPayload.self, from: Data(hunterShaped.utf8)
        )
        let seasons = TMDBProvider.seasons(from: group)
        let flattest = 62
        let biggestNow = seasons.filter { $0.number > 0 }.map(\.episodeCount).max() ?? 0

        #expect(seasons.filter { $0.number > 0 }.count > 1, "it does split into several")
        #expect(!(biggestNow < flattest), "but the 62-episode run is still there, so it fixed nothing")
    }
}

struct SeasonStructureTests {
    @Test func bleachBecomesArcsInsteadOfOneFlatSeason() throws {
        let structure = try bleachStructure()

        #expect(structure.ordering == .episodeGroup(name: "TVDB Order"))
        #expect(structure.absoluteNumbering == .stated)
        #expect(structure.numberedSeasons.map(\.number) == [1, 2])
        #expect(structure.numberedSeasons.map(\.episodeCount) == [20, 21])
        #expect(structure.numberedSeasons.first?.name == "The Substitute")
    }

    @Test func specialsKeepSeasonZeroRatherThanPushingTheRunAlong() throws {
        let structure = try bleachStructure()

        #expect(structure.seasons.first?.number == 0)
        #expect(!structure.numberedSeasons.contains { $0.number == 0 })
    }

    @Test func anAbsoluteNumberFindsItsArc() throws {
        let structure = try bleachStructure()

        #expect(structure.position(ofAbsolute: 1) == EpisodePosition(season: 1, episode: 1))
        #expect(structure.position(ofAbsolute: 20) == EpisodePosition(season: 1, episode: 20))
        #expect(structure.position(ofAbsolute: 21) == EpisodePosition(season: 2, episode: 1))
        #expect(structure.position(ofAbsolute: 41) == EpisodePosition(season: 2, episode: 21))
    }

    @Test func runningOffTheEndIsUnmappedRatherThanClamped() throws {
        let structure = try bleachStructure()

        #expect(structure.position(ofAbsolute: 999) == nil)
        #expect(structure.position(ofAbsolute: 0) == nil)
    }


    @Test func anArcTranslatesToTheRangeAnIndexerCanBeAsked() throws {
        let structure = try bleachStructure()

        let range = structure.nativeRange(ofSeason: 2)
        #expect(range?.season == 1)
        #expect(range?.episodes == 21...41, "The Entry is TMDB S1 E21–41")
    }

    @Test func anAbsoluteFilenameNumberReachesTheProvidersOwnNumbering() throws {
        let structure = try bleachStructure()

        // A pack file called `Bleach - 21` has to be filed twice over: under the
        // arc a person browses, and under the number the provider knows it by.
        // The two calls chain, so an acquisition layer reading an absolute number
        // off a filename has somewhere to put it.
        let shown = try #require(structure.position(ofAbsolute: 21))
        let native = try #require(structure.nativePosition(ofSeason: shown.season, episode: shown.episode))

        #expect(shown == EpisodePosition(season: 2, episode: 1), "arc two, first episode")
        #expect(native == EpisodePosition(season: 1, episode: 21), "TMDB still calls it S1E21")
    }

    @Test func aShownSeasonKnowsWhichRealSeasonItLivesIn() throws {
        let structure = try bleachStructure()

        // Bleach's arc season 2 is inside TMDB's season 1. Handing "2" to an
        // artwork endpoint would return Thousand-Year Blood War's posters —
        // a real picture of the wrong thing.
        #expect(structure.nativeSeason(ofSeason: 2) == 1)
        #expect(structure.nativeSeason(ofSeason: 99) == nil)
    }

    @Test func anUncorrectedShowsSeasonsAreItsOwn() {
        let structure = SeasonStructure(
            nativeSeasons: [Season(number: 1, episodeCount: 24), Season(number: 2, episodeCount: 25)],
            provider: .tmdb
        )

        #expect(structure.nativeSeason(ofSeason: 2) == 2)
    }

    @Test func translationWorksInBothDirections() throws {
        let structure = try bleachStructure()

        #expect(structure.nativePosition(ofSeason: 2, episode: 1) == EpisodePosition(season: 1, episode: 21))
        #expect(structure.position(ofNativeSeason: 1, episode: 21) == EpisodePosition(season: 2, episode: 1))
        #expect(structure.position(ofNativeSeason: 1, episode: 999) == nil)
    }

    @Test func anUncorrectedShowKeepsItsOwnSeasonsAndSaysSo() {
        let structure = SeasonStructure(
            nativeSeasons: [Season(number: 1, episodeCount: 24), Season(number: 2, episodeCount: 25)],
            provider: .tmdb
        )

        #expect(structure.ordering == .native)
        #expect(structure.absoluteNumbering == .derived, "walked, not stated — the reading can be wrong")
        #expect(structure.position(ofAbsolute: 25) == EpisodePosition(season: 2, episode: 1))
        #expect(structure.nativeRange(ofSeason: 1) == nil)
    }
}

/// The 2026-09-19 bug hunt's seasons findings.
struct SeasonBugHuntTests {
    private func structure(_ groups: String, native: [Season]) throws -> SeasonStructure {
        let group = try JSONDecoder().decode(
            TMDBProvider.EpisodeGroupPayload.self,
            from: Data(#"{"id":"g","name":"TVDB Order","groups":[\#(groups)]}"#.utf8)
        )
        return SeasonStructure(seasons: TMDBProvider.seasons(from: group), orderingName: group.name,
                               nativeSeasons: native, provider: .tmdb)
    }

    private func episodes(_ season: Int, _ range: ClosedRange<Int>) -> String {
        range.map { #"{"season_number":\#(season),"episode_number":\#($0)}"# }.joined(separator: ",")
    }

    @Test func anArcInTheSecondNativeSeasonHasAbsoluteNumbersPastTheFirst() throws {
        let tybw = try structure(
            #"{"order":1,"name":"A","episodes":[\#(episodes(1, 1...366))]},{"order":2,"name":"TYBW","episodes":[\#(episodes(2, 1...13))]}"#,
            native: [Season(number: 1, episodeCount: 366), Season(number: 2, episodeCount: 13)]
        )
        #expect(tybw.nativeRange(ofSeason: 2)?.episodes == 1...13)
        #expect(tybw.absoluteRange(ofSeason: 2) == 367...379)
        #expect(tybw.absoluteRange(ofSeason: 1) == 1...366)
    }

    @Test func aGroupOrderedFromZeroIsNotSpecials() throws {
        let s = try structure(
            #"{"order":0,"name":"First arc","episodes":[\#(episodes(1, 1...3))]},{"order":1,"name":"Second","episodes":[\#(episodes(1, 4...6))]}"#,
            native: [Season(number: 1, episodeCount: 6)]
        )
        #expect(s.numberedSeasons.map(\.number) == [1, 2])
    }

    @Test func aRecapListedTwiceIsNotAContiguousRange() throws {
        let s = try structure(
            #"{"order":1,"name":"A","episodes":[\#(episodes(1, 21...22)),{"season_number":1,"episode_number":22},{"season_number":1,"episode_number":24}]}"#,
            native: [Season(number: 1, episodeCount: 30)]
        )
        #expect(s.nativeRange(ofSeason: 1) == nil)
    }

    @Test func anAbsoluteNumberIsReadThroughTheProvidersOwnNumbering() throws {
        // The group opens with a special from season 0: walking the group's
        // seasons would put absolute 4 at arc 1 episode 4 (native E3).
        let s = try structure(
            #"{"order":1,"name":"A","episodes":[{"season_number":0,"episode_number":1},\#(episodes(1, 1...5))]}"#,
            native: [Season(number: 1, episodeCount: 5)]
        )
        #expect(s.position(ofAbsolute: 4) == EpisodePosition(season: 1, episode: 5))
    }
}

@Suite("Unmappable absolute numbers")
struct AbsoluteFallbackTests {
    /// A group ordering over a ten-episode provider season that accounts for six
    /// of them — and skips native 6, the way a group holding a recap does.
    private func structure() -> SeasonStructure {
        func episode(_ shown: Int, _ number: Int, native: Int) -> Episode {
            Episode(season: shown, number: number, native: EpisodePosition(season: 1, episode: native))
        }
        return SeasonStructure(
            seasons: [
                Season(number: 1, episodeCount: 3, episodes: [
                    episode(1, 1, native: 1), episode(1, 2, native: 2), episode(1, 3, native: 3),
                ]),
                Season(number: 2, episodeCount: 3, episodes: [
                    episode(2, 1, native: 4), episode(2, 2, native: 5), episode(2, 3, native: 7),
                ]),
            ],
            orderingName: "Arcs",
            nativeSeasons: [Season(number: 1, episodeCount: 10)],
            provider: .tmdb
        )
    }

    @Test func anAccountedForNumberStillReads() {
        #expect(structure().position(ofAbsolute: 5) == EpisodePosition(season: 2, episode: 2))
    }

    /// Native 6 is the episode the ordering skipped. Walking the group's own
    /// seasons instead answers S2E3 — a real-looking position the group never
    /// claimed for this number, and one episode along from the truth.
    @Test func anUnaccountedForNumberIsUnmappedRatherThanGuessed() {
        #expect(structure().position(ofAbsolute: 6) == nil)
    }

    @Test func aNumberPastTheRunIsUnmappedToo() {
        #expect(structure().position(ofAbsolute: 99) == nil)
    }

    /// Unchanged for the ordinary case: no group, so the seasons shown are the
    /// provider's own and walking them is the only reading there is.
    @Test func plainSeasonsStillWalk() {
        let plain = SeasonStructure(
            nativeSeasons: [Season(number: 1, episodeCount: 12), Season(number: 2, episodeCount: 12)],
            provider: .tmdb
        )
        #expect(plain.position(ofAbsolute: 13) == EpisodePosition(season: 2, episode: 1))
    }
}

@Suite("The season cache has a ceiling")
struct SeasonCacheTests {
    /// The one cache in the package that had no limit, holding a full
    /// SeasonStructure — every episode of every season — per show, for the life
    /// of the provider. A library scan is thousands of shows.
    @Test func theOldestShowsFallOutFirst() async {
        let provider = TMDBProvider(accessToken: "t", transport: Stub().transport)
        let plain = SeasonStructure(nativeSeasons: [Season(number: 1, episodeCount: 12)], provider: .tmdb)

        for showID in 1...300 { await provider.rememberSeasons(plain, for: showID) }

        let cache = await provider.seasonCache
        #expect(cache.count == 256)
        #expect(cache[1] == nil, "the first show asked about is the first to go")
        #expect(cache[300] != nil, "the one just asked about is kept")
    }

    /// Re-asking about a show already cached must not add a second order entry,
    /// or the cache would evict live shows while short of its limit.
    @Test func reRememberingAShowDoesNotGrowTheOrder() async {
        let provider = TMDBProvider(accessToken: "t", transport: Stub().transport)
        for _ in 1...500 { await provider.rememberSeasons(nil, for: 7) }

        let cache = await provider.seasonCache
        #expect(cache.count == 1)
        #expect(cache[7] != nil)
    }
}

struct SeasonRequestTests {
    let stub = Stub()

    private func tmdb(language: String = "en-US") -> TMDBProvider {
        TMDBProvider(accessToken: "t", language: language, transport: stub.transport)
    }

    @Test func aFilmHasNoSeasonsAndNoRequestIsMade() async throws {
        #expect(try await tmdb().seasons(for: Identifiers(tmdb: 603), kind: .movie) == nil)
        #expect(stub.requested.isEmpty)
    }

    @Test func aFallbackAfterAFailedRequestIsNotCached() async throws {
        stub.stub("/tv/1", json: #"{"id":1,"seasons":[{"season_number":1,"episode_count":366}]}"#)
        stub.stub("/tv/1/episode_groups", .init(status: 404, body: "{}"))
        let provider = tmdb()
        let first = try await provider.seasons(for: Identifiers(tmdb: 1))
        #expect(first?.ordering == .native)
        let groupRequests = stub.requested.filter { $0.path.hasSuffix("/episode_groups") }.count
        _ = try await provider.seasons(for: Identifiers(tmdb: 1))
        #expect(stub.requested.filter { $0.path.hasSuffix("/episode_groups") }.count > groupRequests,
                "asked again rather than serving the fallback for the cache's lifetime")
    }

    @Test func episodesCarryTheirRunningTime() async throws {
        stub.stub("/tv/1/season/1", json: """
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

    @Test func inflatedGroupCountsDoNotHideMissingEpisodes() async throws {
        stub.stub("/tv/1", json: #"{"seasons":[{"season_number":1,"episode_count":60}]}"#)
        stub.stub("/tv/1/episode_groups", json: """
        {"results":[{"id":"g","name":"TVDB Order","type":1,"group_count":2,"episode_count":60}]}
        """)
        // Sixty rows, but episode 30 occurs twice and episode 60 is absent.
        let groups = [Array(1...30), Array(30...59)].enumerated().map { index, numbers in
            let episodes = numbers.map {
                "{\"season_number\":1,\"episode_number\":\($0)}"
            }.joined(separator: ",")
            return "{\"order\":\(index),\"name\":\"Arc\",\"episodes\":[\(episodes)]}"
        }.joined(separator: ",")
        stub.stub("/tv/episode_group/g", json: "{\"id\":\"g\",\"name\":\"TVDB Order\",\"groups\":[\(groups)]}")
        let provider = TMDBProvider(accessToken: "t", transport: stub.transport)
        let result = try await provider.seasons(for: Identifiers(tmdb: 1))
        #expect(result?.ordering == .native)
        #expect(result?.position(ofAbsolute: 60) == EpisodePosition(season: 1, episode: 60))
    }
}
