# CLAUDE.md

## Working rules across the three repositories

Slate is one of three repositories worked on by three agents — **Slate** (*what
is this?*), **CinemaResolvers** (*where do I get it?*), **Cinema** (*where do I
watch it?*).

The agreed ruleset lives in Cinema and Cinema is its authority:
[`Docs/three-repos.md`](https://github.com/Nico8324/Cinema/blob/main/Docs/three-repos.md)
(locally, `../Cinema/Docs/three-repos.md`). Read it there rather than trusting a
summary here — a second copy is a copy that drifts.

The points that bite most often in *this* repository:

- **Commit only here.** A cross-repo need is a message to that repo's agent, not
  an edit.
- **Depend on nothing.** Cinema depends on Slate; Slate depends on neither of
  the others. Mirror a small shape — `ResolveInput` mirrors `ResolveRequest` —
  rather than coupling two packages.
- **No API built on a guess about a caller.** It arrives when a real call site
  does.
- **Pre-1.0, the *minor* is the breaking one.** Brief Cinema on the version bump
  intended *before* tagging it, including behaviour that breaks with no
  signature moving.

## What belongs here, and what does not

Slate settles **provider versus provider**: that AniList outranks TMDB for anime
is a fact about AniList and TMDB. It does not settle **human versus machine** —
whether a hand-edit outranks a refresh is a fact about the consuming app's
schema and its user, and it stays there.

Filenames are the app's input, not an answer to *what is this*. Title
normalisation for comparison lives here; extracting a season or an episode from
a path does not.

## Contracts that are easy to break without noticing

- **No credential ever lives in this repository.** It is injected by the app,
  rotated through `updateAPIKey(_:)`, and sent as `Authorization: Bearer` —
  never in a query string.
- **One provider instance for the life of the app.** The request allowance lives
  in the instance, so a provider constructed per lookup is paced against
  nothing. Changing this breaks a caller with no signature moving.
- **`deduplicatedNames` promises the ordering**, not just the deduplication: the
  first spelling survives so a romaji-first list stays romaji-first. Both halves
  are claims about names, never about a destination — a transport with its own
  folding rule folds at its own boundary.
- **Nothing here acts on provenance.** `provenance`, `provider(of:)` and
  `bestProvider` report; no code in this package branches on them. That is what
  makes the public initialisers on `Attributed`, `Field` and `Artwork` safe
  despite carrying a claim about origin: a fabricated attribution can only
  mislead whoever fabricated it, and an app rebuilding persisted metadata is
  supplying it honestly. The day something in here branches on provenance, every
  one of those initialisers becomes a door into a claim the package relies on —
  a breaking change with no signature moving, and one to brief before tagging.
- **Nothing is clamped.** An absolute number past the end of a run, an ordering
  that does not account for an episode, a rating in a region the provider does
  not cover — each returns `nil`. A plausible answer hides the problem; an
  absent one shows it.

## Commands

```bash
swift build
swift test          # 64 tests, no network — TMDB paths use StubURLProtocol
```

Live checks against the real APIs need a TMDB v4 read token, which is not in
this repository and must not be added to it.
