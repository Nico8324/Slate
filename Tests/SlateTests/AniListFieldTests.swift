import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  @Suite(.serialized)
  struct AniListFields {

    /// Attack on Titan's real shape, trimmed to what is asserted.
    private func stub() {
        StubURLProtocol.reset()
        StubURLProtocol.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[{
          "id":16498,"idMal":16498,"format":"TV","episodes":25,"popularity":837840,
          "status":"FINISHED",
          "title":{"romaji":"Shingeki no Kyojin","english":"Attack on Titan"},
          "studios":{"edges":[
            {"isMain":true,"node":{"name":"WIT STUDIO"}},
            {"isMain":false,"node":{"name":"Pony Canyon"}},
            {"isMain":false,"node":{"name":"Dentsu"}}]},
          "tags":[{"name":"Kaiju","rank":93},{"name":"Tragedy","rank":88},
                  {"name":"Philosophy","rank":41}],
          "relations":{"edges":[
            {"relationType":"ADAPTATION","node":{"id":53390,"format":"MANGA","title":{"romaji":"Shingeki no Kyojin"}}},
            {"relationType":"SEQUEL","node":{"id":20958,"idMal":25777,"format":"TV","title":{"romaji":"Shingeki no Kyojin Season 2"}}},
            {"relationType":"SIDE_STORY","node":{"id":18397,"format":"OVA","title":{"romaji":"Shingeki no Kyojin OVA"}}}]},
          "characters":{"edges":[
            {"role":"MAIN","node":{"name":{"full":"Eren Yeager"}},
             "voiceActors":[{"id":95672,"name":{"full":"Yuuki Kaji"},"image":{"large":"https://s4.anilist.co/e.png"}}]},
            {"role":"SUPPORTING","node":{"name":{"full":"Hange Zoe"}},"voiceActors":[]}]}
        }]}}}
        """)
    }

    private func snapshot() async throws -> Snapshot {
        stub()
        return try #require(await AniListProvider(session: StubURLProtocol.session)
            .snapshot(for: Lookup(search: "Attack on Titan")))
    }

    @Test func aSequelIsALinkBecauseItIsASeparateWork() async throws {
        // Season 2 has its own id and its own episode numbering from one. The
        // sequel edge is the only thing tying it to season 1.
        let relations = try #require(await snapshot().relations)
        let sequel = try #require(relations.first { $0.kind == .sequel })

        #expect(sequel.title == "Shingeki no Kyojin Season 2")
        #expect(sequel.ids.aniList == 20958)
        #expect(sequel.ids.myAnimeList == 25777)
        #expect(relations.map(\.kind).contains(.sideStory))
    }

    @Test func aRelatedMangaIsNotSomethingALibraryCanPlay() async throws {
        let relations = try #require(await snapshot().relations)

        #expect(relations.contains { $0.kind == .adaptation && !$0.isWatchable })
        #expect(relations.filter(\.isWatchable).count == 2)
    }

    @Test func theStudioIsTheAnimatorNotTheCommittee() async throws {
        // AniList lists producers, licensors and broadcasters beside the studio;
        // naming all of them answers a question nobody asked.
        #expect(try await snapshot().studios == ["WIT STUDIO"])
    }

    @Test func aTagTwoPeopleAgreedOnIsNotAKeyword() async throws {
        #expect(try await snapshot().keywords == ["Kaiju", "Tragedy"], "rank 41 is noise")
    }

    @Test func anAnimeCastIsItsVoiceActors() async throws {
        let cast = try #require(await snapshot().cast)

        #expect(cast.count == 1, "a character with no listed actor is not a credit")
        #expect(cast.first?.name == "Yuuki Kaji")
        #expect(cast.first?.character == "Eren Yeager")
        #expect(cast.first?.profileURL != nil)
    }

    @Test func statusIsOneVocabularyAcrossProviders() async throws {
        // AniList says FINISHED, TMDB says Ended. A consumer comparing the two
        // should not have to know either word.
        #expect(try await snapshot().status == .ended)
        #expect(ReleaseStatus(providerValue: "Returning Series") == .airing)
        #expect(ReleaseStatus(providerValue: "RELEASING") == .airing)
        #expect(ReleaseStatus(providerValue: "NOT_YET_RELEASED") == .upcoming)
        #expect(ReleaseStatus(providerValue: "Released") == .released)
        #expect(ReleaseStatus(providerValue: "nonsense") == nil, "an unknown word is not a status")
    }

    @Test func anAnimeIsJapaneseUnlessSomethingSaysOtherwise() async throws {
        let snapshot = try await snapshot()
        #expect(snapshot.originalLanguage == "ja")
        #expect(snapshot.originCountries == ["JP"])
    }
  }
}
