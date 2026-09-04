import Foundation

extension TMDBProvider: SeasonProvider {

    /// How a series is divided — corrected, where TMDB's own answer is one
    /// nobody else uses.
    ///
    /// Ordinarily this is simply what TMDB says and nothing is corrected. It
    /// intervenes only when TMDB is *clearly* flattening a long run, and only
    /// towards an ordering that accounts for every episode the show is said to
    /// have. That narrowness is the whole safety argument: choosing an ordering
    /// is a decision, not a lookup — Bleach carries thirteen and they disagree
    /// with each other — and getting it wrong silently renumbers a library.
    public func seasons(for ids: Identifiers) async throws -> SeasonStructure? {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        guard let showID = try await showID(for: ids) else { return nil }
        if let cached = seasonCache[showID] { return cached }

        let resolved = try await resolveSeasons(showID: showID)
        seasonCache[showID] = resolved
        return resolved
    }

    /// Forgets what was worked out — for a test, or for someone who changed the
    /// metadata language, since ordering names are localised even though the
    /// numbering is not.
    public func forgetSeasons() {
        seasonCache.removeAll()
    }

    /// The episodes of one season, for the ordinary path where they are not
    /// already in hand. The episode-group path fills them for free.
    public func episodes(ofShow showID: Int, season: Int) async throws -> [Episode] {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }
        let url = try URL.build(Self.api, path: "/tv/\(showID)/season/\(season)")
        return try await http.json(SeasonPage.self, url: url, headers: headers).episodes.map {
            Episode(
                season: $0.season_number ?? season,
                number: $0.episode_number,
                title: $0.name?.nilIfEmpty,
                airDate: $0.air_date?.asReleaseDate,
                tmdbID: $0.id,
                stillURL: $0.still_path.flatMap { URL(string: "\(Self.images)/original\($0)") }
            )
        }
    }

    // MARK: - Deciding

    private func resolveSeasons(showID: Int) async throws -> SeasonStructure? {
        let page = try await http.json(ShowPage.self,
                                       url: try URL.build(Self.api, path: "/tv/\(showID)"),
                                       headers: headers)
        let native = page.seasons?.map {
            Season(number: $0.season_number, name: $0.name?.nilIfEmpty, episodeCount: $0.episode_count ?? 0)
        } ?? []
        guard !native.isEmpty else { return nil }

        let plain = SeasonStructure(nativeSeasons: native, provider: .tmdb)
        guard Self.isFlattened(native) else { return plain }

        let total = native.filter { $0.number > 0 }.reduce(0) { $0 + $1.episodeCount }
        let summaries = try await http.json(
            EpisodeGroupsResponse.self,
            url: try URL.build(Self.api, path: "/tv/\(showID)/episode_groups"),
            headers: headers
        ).results
        guard let chosen = Self.preferredGroup(among: summaries, coveringAtLeast: total) else {
            return plain
        }

        let group = try await http.json(
            EpisodeGroupPayload.self,
            url: try URL.build(Self.api, path: "/tv/episode_group/\(chosen.id)"),
            headers: headers
        )
        let seasons = Self.seasons(from: group)
        // An ordering that turns out not to divide anything is not a correction,
        // and adopting it would swap one flat season for another while claiming
        // to have fixed something.
        guard seasons.filter({ $0.number > 0 }).count > 1 else { return plain }

        // Nor is one that leaves the long run standing and files extras beside
        // it. Hunter x Hunter's `Complete Series` ordering returns the 62-episode
        // run untouched as season one, then the OVAs as seasons two to four — so
        // the flattening it was chosen to fix survives, now wearing a correction's
        // label. The run must actually be broken up.
        let flattest = native.filter { $0.number > 0 }.map(\.episodeCount).max() ?? 0
        let biggestNow = seasons.filter { $0.number > 0 }.map(\.episodeCount).max() ?? 0
        guard biggestNow < flattest else { return plain }

        return SeasonStructure(seasons: seasons, orderingName: group.name,
                               nativeSeasons: native, provider: .tmdb)
    }

    /// Whether TMDB has collapsed a long run into a season nobody else counts as
    /// one.
    ///
    /// *Any* single season past the threshold, not "the show has only one
    /// season" — Bleach has two on TMDB, the 366-episode run and Thousand-Year
    /// Blood War beside it, so asking for a lone season would leave the very case
    /// this exists for uncorrected.
    ///
    /// The threshold keeps ordinary television out. A twelve-part series
    /// genuinely has one season; sixty episodes under one number is a database
    /// convenience nobody outside the database shares.
    static func isFlattened(_ seasons: [Season]) -> Bool {
        let numbered = seasons.filter { $0.number > 0 }
        if numbered.contains(where: { $0.episodeCount >= 60 }) { return true }
        // And the case the threshold alone misses: a show filed as a *single*
        // season far longer than any season really runs. Jujutsu Kaisen is one
        // season of 59 on TMDB and two seasons everywhere else — it slipped under
        // the bar by a single episode.
        //
        // Fifty, not two cours. Read at 24 this caught Frieren, whose 38 episodes
        // TMDB files as one season, and split it into broadcast *cours* — 16, 12,
        // 10 — which is not how anyone numbers it: releases run straight through
        // to 28. Anime seasons are twelve or thirteen, occasionally twenty-six;
        // fifty in one season is unambiguously more than one, and thirty-eight is
        // not unambiguously anything.
        return numbered.count == 1 && (numbered.first?.episodeCount ?? 0) >= 50
    }

    /// Which ordering to trust, of the several a show may carry.
    ///
    /// Three tiers, narrowing from "the one everybody agrees on" to "the show's
    /// own divisions", and never reaching an alternate cut of the run.
    ///
    /// `TVDB Order` by name first, because that is the one that agrees with
    /// Wikipedia and with TheTVDB, which between them are what a release group's
    /// "Season 2" means — and it arrives through TMDB, so it costs no second
    /// credential. After that, an original-air-date ordering: the same intent
    /// expressed through TMDB's type field.
    ///
    /// Story-arc orderings are deliberately *not* a fallback. They are the same
    /// idea done to different standards — Bleach has three, splitting 366
    /// episodes 21, 12 and 25 ways — and picking one arbitrarily is precisely the
    /// silent renumbering to avoid.
    ///
    /// Eligible only if it accounts for at least every episode the show is said
    /// to have; a partial ordering would file what it knows and strand the rest.
    static func preferredGroup(
        among groups: [EpisodeGroupSummary], coveringAtLeast episodeCount: Int
    ) -> EpisodeGroupSummary? {
        let eligible = groups.filter { $0.group_count > 1 && $0.episode_count >= episodeCount }

        if let tvdb = eligible.first(where: { $0.name.caseInsensitiveCompare("TVDB Order") == .orderedSame }) {
            return tvdb
        }
        if let airDate = eligible.first(where: { $0.type == EpisodeGroupSummary.originalAirDate }) {
            return airDate
        }

        // Last, the show's own divisions. Jujutsu Kaisen and Hunter x Hunter
        // have neither of the above and were left as one long season each —
        // which is the thing this whole type exists to prevent. What they do
        // have is a `production` or `tv` ordering, which means "how this show is
        // actually divided" rather than an alternate cut of it.
        //
        // Deliberately not: `absolute` (that *is* the flat run being corrected),
        // `dvd` and `digital` (a release's cut, not the show's), and `storyArc`
        // (the same idea done to different standards — Bleach carries three that
        // split one run 21, 12 and 25 ways).
        let divisions = eligible.filter {
            $0.type == EpisodeGroupSummary.production || $0.type == EpisodeGroupSummary.tv
        }
        // Shows carry several of these and they disagree, so the choice must be
        // deterministic rather than "whichever the API listed first": a Latin
        // name over 季 for a library that reads Latin, then the fewest groups —
        // the least aggressive re-cut — then the tightest coverage.
        let ranked = divisions.sorted { lhs, rhs in
            let (l, r) = (lhs.name.isMostlyLatin, rhs.name.isMostlyLatin)
            if l != r { return l }
            if lhs.group_count != rhs.group_count { return lhs.group_count < rhs.group_count }
            if lhs.episode_count != rhs.episode_count { return lhs.episode_count < rhs.episode_count }
            return lhs.name < rhs.name
        }
        return ranked.first
    }

    /// Reads an ordering into seasons.
    ///
    /// Entries whose `order` is `0` are TMDB's specials and keep season 0 rather
    /// than being renumbered into the run — filing four specials as "season one"
    /// would push every real season along by one.
    static func seasons(from group: EpisodeGroupPayload) -> [Season] {
        group.groups.sorted { $0.order < $1.order }.map { entry in
            Season(
                number: entry.order,
                name: entry.name.nilIfEmpty,
                episodeCount: entry.episodes.count,
                episodes: entry.episodes.enumerated().map { index, episode in
                    Episode(
                        season: entry.order,
                        number: index + 1,
                        title: episode.name?.nilIfEmpty,
                        airDate: episode.air_date?.asReleaseDate,
                        tmdbID: episode.id,
                        native: EpisodePosition(season: episode.season_number,
                                                episode: episode.episode_number)
                    )
                }
            )
        }
    }

    func showID(for ids: Identifiers) async throws -> Int? {
        if let id = ids.tmdb { return id }
        guard let imdb = ids.imdb else { return nil }
        let url = try URL.build(Self.api, path: "/find/\(imdb)", query: ["external_source": "imdb_id"])
        return try await http.json(FindTVResponse.self, url: url, headers: headers).tv_results.first?.id
    }

    // MARK: - Payloads

    struct EpisodeGroupSummary: Decodable, Sendable {
        static let originalAirDate = 1
        static let production = 6
        static let tv = 7

        let id: String
        let name: String
        let type: Int
        let group_count: Int
        let episode_count: Int
    }

    struct EpisodeGroupPayload: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            struct Item: Decodable, Sendable {
                let id: Int?
                let name: String?
                let air_date: String?
                let season_number: Int
                let episode_number: Int
            }
            let order: Int
            let name: String
            let episodes: [Item]
        }
        let id: String
        let name: String
        let groups: [Entry]
    }

    struct EpisodeGroupsResponse: Decodable { let results: [EpisodeGroupSummary] }

    private struct ShowPage: Decodable {
        struct SeasonEntry: Decodable {
            let season_number: Int
            let episode_count: Int?
            let name: String?
        }
        let seasons: [SeasonEntry]?
    }

    private struct SeasonPage: Decodable {
        struct EpisodeEntry: Decodable {
            let id: Int?
            let name: String?
            let air_date: String?
            let still_path: String?
            let season_number: Int?
            let episode_number: Int
        }
        let episodes: [EpisodeEntry]
    }

    private struct FindTVResponse: Decodable {
        struct Hit: Decodable { let id: Int }
        var tv_results: [Hit] = []
    }
}
