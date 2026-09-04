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

    @Test func ordinaryTelevisionIsLeftAlone() {
        // A twelve-part series genuinely has one season; nothing to fix.
        #expect(!TMDBProvider.isFlattened([Season(number: 1, episodeCount: 12)]))
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

    @Test func anOrderingThatMissesEpisodesIsRejected() {
        let chosen = TMDBProvider.preferredGroup(among: [
            summary("TVDB Order", type: 1, groups: 16, episodes: 300),
        ], coveringAtLeast: 366)

        #expect(chosen == nil, "a partial ordering would strand the rest unmapped")
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

    @Test func absoluteAndPositionAreInverses() throws {
        let structure = try bleachStructure()

        #expect(structure.absolute(ofSeason: 2, episode: 1) == 21)
        #expect(structure.absolute(ofSeason: 2, episode: 21) == 41)
        #expect(structure.absolute(ofSeason: 2, episode: 22) == nil)
    }

    @Test func anArcTranslatesToTheRangeAnIndexerCanBeAsked() throws {
        let structure = try bleachStructure()

        let range = structure.nativeRange(ofSeason: 2)
        #expect(range?.season == 1)
        #expect(range?.episodes == 21...41, "The Entry is TMDB S1 E21–41")
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
