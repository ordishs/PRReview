# PR Review — Plan 13: Discovery Polling + Merged Queue Design Spec

- **Date:** 2026-05-29
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Plan number:** 13 (completes Phase 2)
- **Master spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md`
- **Prior plan:** `docs/superpowers/specs/2026-05-28-claude-status-design.md` (Plan 12)

## Summary

Add background discovery: at app launch and every `Settings.pollIntervalSeconds`,
run each query in `Settings.discoveryQueries` via `gh search prs`, dedup the
results, and upsert into `ReviewStore`. New PRs get full metadata via a follow-up
`gh pr view`; existing PRs get their `prState` + `title` refreshed from the
search result, and have their `origin` promoted to `.both` if they were
previously `.added`. PRs that fall out of the discovery query are left in the
sidebar — the user dismisses them via the existing context menu. The merged
queue (manual + discovered) becomes the canonical sidebar source, just like the
master spec described.

## Goals

- Sidebar auto-populates on launch with PRs matching the user's discovery
  queries (default: `review-requested:@me`, `assignee:@me`).
- Discovered + manually-added PRs merge into a single deduplicated list keyed
  by review id.
- `prState` reflects upstream changes (open → merged/closed) on every poll
  interval.
- Failure of one query (or one PR's metadata fetch) doesn't block the rest of
  the cycle.
- No UI churn: discovered PRs look identical to manually-added ones in the
  sidebar; `origin` is metadata only.

## Non-goals

- Persistent dismissal of a discovered PR (removing it via context menu
  re-discovers on next poll — known footgun, deferred to backlog).
- Per-query origin tagging (one set of discoveries, not labeled by source
  query).
- User-toggleable polling (no Settings UI yet; default-on).
- Manual "Refresh now" button (auto-only; can be added later if useful).
- Configurable `--limit` on `gh search prs` (hardcoded to 100 per query).
- Hot-reload of `Settings.discoveryQueries` (we re-read on each poll, so a
  future Settings UI change applies on the next interval — but there's no UI
  yet).
- Surfacing query failures (silent retry; user notices only persistent
  outages).

## Key decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Metadata fill strategy | Per-PR `gh pr view` follow-up on first discovery | Reuses existing `fetchReview` path; ~5-10 extra calls on first poll, zero on subsequent polls |
| 2 | Poll lifecycle | Auto-start on `AppModel.load()`; loops every `pollIntervalSeconds`; cancelled in `terminateAllClaudeSessions` | Same pattern as the Plan 12 tick task; no separate UI surface |
| 3 | Dedup behaviors | Promote `.added → .both` on crossover; keep PRs that fall out; update `prState` + `title` every poll | Per master spec; preserves user intent on manual adds |
| 4 | Failure handling | Silent `try?` at every layer (search, fetch, upsert) | Transient errors are common; loud surfacing would be noisy |
| 5 | Sidebar UX | No visual distinction between discovered and added PRs | Origin is metadata only; cleanest scan; user mental model is "PRs I'm reviewing" |
| 6 | `gh search prs` field set | `number,title,url,state,isDraft,author,repository` | Minimum needed for dedup + state refresh; head/base/issue come from the follow-up |
| 7 | Concurrency model | Sequential per query; await each search call serially within one poll cycle | Two queries × ~200ms = negligible; `withTaskGroup` is YAGNI |
| 8 | Test stub | Extend `StubRunner` to support a results queue | Backwards-compatible with existing tests; minimum refactor |

## Architecture

### New types in `GitHubKit`

```swift
public struct DiscoveryHit: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let state: String       // raw: "open"/"closed"/"merged" (lowercase)
    public let isDraft: Bool

    public var id: String { "\(owner)/\(repo)#\(number)" }
    public var ref: PRRef { PRRef(owner: owner, repo: repo, number: number) }
}
```

`DiscoveryHit` is a lightweight value type matching exactly what `gh search prs`
returns. It's the input to the merger; it never reaches the sidebar or the
store. `Review` remains the canonical sidebar model.

### `GitHubClient.searchPRs(query:)`

```swift
extension GitHubClient {
    public func searchPRs(query: String) async throws -> [DiscoveryHit] {
        let fields = "number,title,url,state,isDraft,author,repository"
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["search", "prs", query, "--json", fields, "--limit", "100"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let raw = try JSONDecoder().decode([GHSearchHit].self, from: Data(result.standardOutput.utf8))
        return raw.compactMap { row -> DiscoveryHit? in
            let parts = row.repository.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return DiscoveryHit(
                owner: parts[0],
                repo: parts[1],
                number: row.number,
                title: row.title,
                url: row.url,
                authorLogin: row.author.login,
                state: row.state,
                isDraft: row.isDraft
            )
        }
    }

    public static func mapDiscoveryState(state: String, isDraft: Bool) -> PRState {
        mapState(state: state.uppercased(), isDraft: isDraft)
    }
}

private struct GHSearchHit: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: Author
    let repository: Repository
}
```

**Defensive parsing:** the outer JSON decode is `try` — a totally malformed
response throws `GitHubError.decodingFailed`. Individual rows with a malformed
`nameWithOwner` are silently dropped via `compactMap`. The state casing is
normalized by `mapDiscoveryState` (search returns lowercase, `gh pr view`
returns uppercase; the existing `mapState` expects uppercase).

### `AppModel` additions

```swift
private var discoveryTask: Task<Void, Never>?

public func load() async {
    reviews = await store.allReviews()
    registeredRepos = await store.allRepos()
    startTickTimerIfNeeded()
}

public func startDiscoveryPolling() {
    guard discoveryTask == nil else { return }
    discoveryTask = Task { @MainActor in
        await self.discoverNow()
        let intervalNs = UInt64(Settings.default.pollIntervalSeconds) * 1_000_000_000
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: intervalNs)
            await self.discoverNow()
        }
    }
}
```

Polling is started by `PRReviewApp.swift` after `load()` returns rather than by
`load()` itself. This keeps tests deterministic — they call `await model.load()`
without triggering the background poll, and exercise `discoverNow()` directly
instead.

```swift
func discoverNow() async {
    let queries = Settings.default.discoveryQueries
    var hitsByID: [String: DiscoveryHit] = [:]
    for query in queries {
        guard let results = try? await client.searchPRs(query: query) else { continue }
        for hit in results {
            hitsByID[hit.id] = hit
        }
    }
    await mergeDiscoveryHits(Array(hitsByID.values))
}

private func mergeDiscoveryHits(_ hits: [DiscoveryHit]) async {
    let existingByID = Dictionary(reviews.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for hit in hits {
        if let existing = existingByID[hit.id] {
            var updated = existing
            updated.title = hit.title
            updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
            if existing.origin == .added { updated.origin = .both }
            try? await store.upsert(updated)
        } else {
            guard let fresh = try? await client.fetchReview(for: hit.ref, origin: .discovered) else { continue }
            try? await store.upsert(fresh)
        }
    }
    reviews = await store.allReviews()
}
```

`discoverNow` is `internal` (no `public` modifier) so tests can drive it
directly without waiting for the poll interval. Production callers are the
discovery task and (potentially future) a manual refresh button.

### Cleanup

`terminateAllClaudeSessions()` gains two new lines at the top (alongside the
existing `tickTask.cancel()`):

```swift
discoveryTask?.cancel()
discoveryTask = nil
```

### `StubRunner` extension (test infrastructure)

The existing `StubRunner` returns the same `CommandResult` on every call,
which doesn't work for the discovery tests (two `gh search prs` calls + one
`gh pr view` call need different responses). Extend it to support a results
queue:

```swift
private actor StubRunner: CommandRunner {
    private var results: [CommandResult]
    private let fallback: CommandResult?

    init(result: CommandResult) {
        self.results = []
        self.fallback = result        // backwards-compatible: single result served from fallback, repeats infinitely
    }

    init(results: [CommandResult]) {
        self.results = results
        self.fallback = nil           // strict queue: throws if exhausted
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        if results.isEmpty {
            if let fallback { return fallback }
            throw NSError(domain: "StubRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "queue exhausted"])
        }
        return results.removeFirst()
    }
}
```

Existing single-result construction continues to work (returns the same result
forever). Tests that need different responses per call use the queue
constructor.

## Data model

No schema changes. `ReviewOrigin` already has `.discovered | .added | .both`.
`Settings.discoveryQueries` and `pollIntervalSeconds` already exist.

## Error handling

| Failure | Surface | Recovery |
|---|---|---|
| One query fails (`gh search prs` non-zero exit) | `try?` skips it; other queries still run | Retry on next interval |
| Single PR's `fetchReview` fails | `try?` skips that PR; others proceed | Retry on next interval |
| `store.upsert` fails | `try?` swallows the error | Retry on next interval; stale state until success |
| Decode of search response throws | The whole query is skipped via `try?` | Retry on next interval |
| Polling task cancellation mid-call | `Task.isCancelled` check at top of loop; in-flight call completes then loop exits | Clean shutdown |

The intentional silence is the spec's main UX trade-off. The alternative
(banner-after-N-failures) was rejected as overkill for Plan 13.

## Testing strategy

**`GitHubKitTests`** — extend `GitHubClientTests.swift`:

- `searchPRsParsesResults` — canned JSON returns two hits across two repos; assert correct field mapping.
- `searchPRsHandlesEmptyResults` — empty array → empty `[DiscoveryHit]`.
- `searchPRsThrowsOnNonZeroExit` — exit code 1 → `GitHubError.commandFailed`.
- `searchPRsSkipsMalformedRepository` — row with `nameWithOwner` missing `/` is dropped; other rows return.
- `mapDiscoveryStateNormalizesCasing` — `"open"` → `.open`, `"merged"` → `.merged`, `"closed"` → `.closed`, plus `isDraft: true` → `.draft`.

**`AppCoreTests`** — extend `AppModelTests.swift`. Uses the queued `StubRunner`:

- `discoverNowPopulatesNewReviews` — empty store → one search hit → one full `fetchReview` follow-up → reviews has one entry, `origin == .discovered`.
- `discoverNowPromotesAddedToBoth` — pre-upserted Review with `.added` → matching search hit → origin promoted to `.both`, no duplicate.
- `discoverNowKeepsPRsFallingOutOfQuery` — pre-upserted discovered Review → empty search → review still in store.
- `discoverNowUpdatesPRState` — pre-upserted with `.open` → search returns `"merged"` → reloaded review has `prState == .merged`.
- `discoverNowDeduplicatesAcrossQueries` — two queries return the same PR → only one `fetchReview` call; one store entry.

**Coverage delta:** 10 new tests (5 GitHubKit + 5 AppCore). 93 → ~103.

**Out of test scope:**
- The Task-loop interval timing — `discoverNow` is the unit-test entry point; the actual periodic firing is verified manually.
- Real `gh search prs` invocation — manual E2E.
- Race between manual add and concurrent discovery — `mergeDiscoveryHits`
  re-checks `self.reviews` before treating a hit as new, so a late `addPR`
  during an `await` point is promoted to `.both` on the same poll cycle. Not
  directly unit-tested (requires `await`-point injection); verified by reasoning.

## Build phasing context

This plan completes **Phase 2 · Intelligence** from the master spec:

> "`GitHubKit` discovery/polling + dedup (the merged queue), transcript tailing
> → sidebar badges + verdict snippet"

The transcript-tailing half was Plan 12. After Plan 13 lands, Phase 2 is
complete and the app delivers:

- Full sidebar (Phase 1: scaffold + worktree + Claude pane + diff pane)
- Discovery polling + merged queue (Plan 13)
- Live Claude status badges + review-ready notifications (Plan 12)

Remaining work: Phase 3 (Notifications & polish — review-ready is partly done;
worktree refresh on force-push and Settings UI remain) and Phase 4
(Comments — clickable diff line → review comment via `gh`).

## Open questions / risks

- **"Remove from List" doesn't stick for discovered PRs.** If a user removes a
  PR via the sidebar context menu and it's still in the discovery query, the
  next poll re-discovers it. The user has no way to permanently dismiss a
  discovered PR. Captured for backlog as a "dismiss/snooze" feature; not in
  Plan 13 scope.
- **`Settings.default.discoveryQueries` is read fresh on each poll** — designed
  to support a future Settings UI where the user can edit queries without
  restarting. No UI today, so the queries are always the default.
- **The 120-second default poll interval** is reasonable but unconfigurable
  without code edits. The `pollIntervalSeconds` field exists; needs Settings
  UI to surface.
- **Multiple `discoveryQueries` returning many PRs each** could result in a
  burst of `fetchReview` calls on first launch. With `--limit 100` per query
  and two queries, worst case is 200 first-discovery `gh pr view` calls. A
  user with that many review requests is an outlier; rate-limit handling is
  not in Plan 13.
- **`gh` auth expired during a poll** — every call fails uniformly; the
  sidebar stops updating but the app keeps running. A future "refresh
  failures" indicator (banner-after-N) would surface this.
- **PRs from forks** — the `gh search prs` `repository.nameWithOwner` is the
  base repo, not the fork. Existing `fetchReview` / `WorktreeProvider` handles
  this correctly (the multi-remote logic from Plan 8). No additional work.

## Out of scope (explicit non-goals)

- Per-query labeling (which query discovered a given PR).
- Settings UI for editing `discoveryQueries` or `pollIntervalSeconds`.
- Manual "Refresh now" button.
- Persistent dismissal of discovered PRs.
- Rate-limit detection / backoff for `gh` API limits.
- Banner / alert on persistent discovery failure.
- Configurable `--limit` on the `gh search prs` query.
- Hot-reload of `Settings` mid-poll.
