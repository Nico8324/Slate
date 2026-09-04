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
