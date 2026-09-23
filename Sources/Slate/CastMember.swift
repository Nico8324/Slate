import Foundation

/// Someone in the credits.
public struct CastMember: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// Who they play. Television credits aggregate several roles across a run;
    /// this is the one they are most billed for.
    public let character: String?
    public let profileURL: URL?
    /// Billing order, lowest first, as the provider gives it.
    public let order: Int?

    public init(id: Int, name: String, character: String? = nil, profileURL: URL? = nil, order: Int? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.order = order
    }
}

extension Array where Element == CastMember {
    /// One entry per person, in billing order, their roles joined.
    ///
    /// Providers list someone once per role — a film credits an actor twice when
    /// they play two parts, AniList a voice actor once per character — and
    /// ``CastMember/id`` is the person, so a list that repeats them breaks
    /// anything keyed by `id`: SwiftUI's `ForEach` shows the wrong rows.
    var mergedByPerson: [CastMember] {
        var order: [Int] = []
        var byPerson: [Int: CastMember] = [:]
        for member in self {
            guard let existing = byPerson[member.id] else {
                order.append(member.id)
                byPerson[member.id] = member
                continue
            }
            let characters = [existing.character, member.character].compactMap { $0 }.deduplicatedNames
            byPerson[member.id] = CastMember(
                id: existing.id, name: existing.name,
                character: characters.isEmpty ? nil : characters.joined(separator: " / "),
                profileURL: existing.profileURL ?? member.profileURL,
                order: [existing.order, member.order].compactMap { $0 }.min()
            )
        }
        return order.compactMap { byPerson[$0] }
    }
}

/// Someone behind the camera: who directed it, wrote it, or created the show.
///
/// Only those three. A film's full crew runs to hundreds of lines — grips,
/// caterers, the second unit's accountant — and a library shows the handful a
/// person recognises. Everyone else is one ``TMDBProvider/person(id:)`` away.
public struct CrewMember: Sendable, Equatable, Identifiable {
    public let personID: Int
    public let name: String
    /// As the provider spells it: `Director`, `Screenplay`, `Novel`, `Creator`.
    public let job: String
    public let department: Department
    public let profileURL: URL?

    /// Person and job: a writer-director is credited once for each.
    public var id: String { "\(personID)-\(job)" }

    public enum Department: String, Sendable, Hashable {
        case directing, writing
        /// A series' creator — a credit television has and film does not.
        case creator
    }

    public init(personID: Int, name: String, job: String, department: Department, profileURL: URL? = nil) {
        self.personID = personID
        self.name = name
        self.job = job
        self.department = department
        self.profileURL = profileURL
    }
}
