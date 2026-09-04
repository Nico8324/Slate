import Foundation
import Testing
@testable import Slate

private func art(
    _ kind: ArtworkKind, _ language: String?, rating: Double = 5, width: Int = 1000,
    provider: Provider = .tmdb, path: String = "/a.jpg"
) -> Artwork {
    Artwork(
        kind: kind, url: URL(string: "https://image.tmdb.org/t/p/original\(path)")!,
        language: language, width: width, height: width, rating: rating, provider: provider
    )
}

struct ArtworkChoiceTests {
    @Test func aPosterIsChosenForTheLanguageTheViewerReads() {
        let set = ArtworkSet(posters: [
            art(.poster, "ja", rating: 9), art(.poster, "en", rating: 4), art(.poster, nil, rating: 8),
        ])

        #expect(set.best(.poster, preferring: ["en"])?.language == "en",
                "even though the Japanese one is rated higher")
        #expect(set.best(.poster, preferring: ["ja"])?.language == "ja")
    }

    @Test func aTextlessPosterBeatsOneInALanguageNobodyAskedFor() {
        let set = ArtworkSet(posters: [art(.poster, "de", rating: 9), art(.poster, nil, rating: 2)])

        #expect(set.best(.poster, preferring: ["en"])?.isTextless == true)
    }

    @Test func aTextlessBackdropWinsOutright() {
        // The one that can sit behind a title without two sets of words fighting.
        let set = ArtworkSet(backdrops: [
            art(.backdrop, "en", rating: 9, width: 3840), art(.backdrop, nil, rating: 1, width: 1280),
        ])

        #expect(set.best(.backdrop, preferring: ["en"])?.isTextless == true)
    }

    @Test func ratingThenSizeDecidesWithinATier() {
        let set = ArtworkSet(posters: [
            art(.poster, "en", rating: 6, width: 4000, path: "/low.jpg"),
            art(.poster, "en", rating: 8, width: 1000, path: "/high.jpg"),
        ])
        #expect(set.best(.poster)?.url.path.contains("high") == true)

        let sameRating = ArtworkSet(posters: [
            art(.poster, "en", rating: 8, width: 1000, path: "/small.jpg"),
            art(.poster, "en", rating: 8, width: 4000, path: "/big.jpg"),
        ])
        #expect(sameRating.best(.poster)?.url.path.contains("big") == true)
    }

    @Test func languagePreferenceIsOrdered() {
        let set = ArtworkSet(posters: [art(.poster, "de"), art(.poster, "fr"), art(.poster, "en")])

        #expect(set.best(.poster, preferring: ["fr", "en"])?.language == "fr")
        #expect(set.best(.poster, preferring: ["de", "fr"])?.language == "de")
    }

    @Test func nothingToChooseFromIsNilRatherThanAPlaceholder() {
        #expect(ArtworkSet().best(.poster) == nil)
        #expect(ArtworkSet().isEmpty)
    }



    @Test func anEmptyLanguageIsTextlessNotALanguage() throws {
        // TMDB says "" for an image with no text on it.
        let json = """
        {"posters":[{"file_path":"/p.jpg","iso_639_1":"","vote_average":7.0,"width":2000,"height":3000}]}
        """
        let images = try JSONDecoder().decode(TMDBProvider.Images.self, from: Data(json.utf8))
        let poster = try #require(images.posters?.first?.artwork(.poster))

        #expect(poster.isTextless)
        #expect(poster.language == nil)
    }

    @Test func setsFromSeveralProvidersMerge() {
        var set = ArtworkSet(posters: [art(.poster, "en")])
        set.merge(ArtworkSet(posters: [art(.poster, nil, provider: .aniList)],
                             backdrops: [art(.backdrop, nil, provider: .aniList)]))

        #expect(set.posters.count == 2)
        #expect(set.backdrops.count == 1)
    }
}
