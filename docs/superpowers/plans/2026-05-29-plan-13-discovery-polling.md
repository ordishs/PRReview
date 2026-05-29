# PR Review — Plan 13: Discovery Polling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-populate the sidebar with PRs matching `Settings.discoveryQueries` via background `gh search prs` polling. Discovered PRs merge with manually-added ones via deduplication on review id; origin is promoted to `.both` on crossover. `prState` refreshes on every poll.

**Architecture:** New lightweight `DiscoveryHit` value type + `GitHubClient.searchPRs(query:)` method in `GitHubKit`. `AppModel` gains a `discoveryTask` (Task loop, same pattern as Plan 12's tick task) and an internal `discoverNow()` that fans out queries, dedups hits, fetches full metadata for new PRs via the existing `fetchReview`, and upserts. Polling is started by `PRReviewApp.swift` after `load()` so tests can drive `discoverNow()` directly without touching the background task.

**Tech Stack:** Swift 6, Foundation. Existing `GitHubKit`, `AppCore`, and `ReviewStore` packages. `gh search prs` CLI invocation. No new SPM dependencies.

**Master design spec:** `docs/superpowers/specs/2026-05-29-discovery-polling-design.md`
**Plan sequence:** 11-claude-pane ✅ · 12-claude-status ✅ · **13-discovery-polling (this)** · then Phase 3 (worktree refresh, Settings UI).

---

## Scope notes

- Discovery is auto-only — no manual "Refresh now" button, no on/off toggle. `Settings.default.discoveryQueries` and `Settings.default.pollIntervalSeconds` (120s) are used straight from the existing defaults.
- Per-PR `gh pr view` follow-up via `client.fetchReview(for:origin:.discovered)` fills head/base branches and closing-issue number for newly-discovered PRs. Existing reviews skip the follow-up — only `prState` and `title` refresh.
- Sidebar has zero changes. Discovered and manually-added PRs render identically; `origin` is metadata only.
- Polling start is **moved out of `load()`** into a separate `startDiscoveryPolling()` method. Tests don't call `startDiscoveryPolling()`; they invoke `discoverNow()` directly. `PRReviewApp.swift` calls both `load()` and `startDiscoveryPolling()` on app startup.
- `StubRunner` in `AppModelTests.swift` gets a queued-results constructor for tests that need different responses per call (search → fetchReview).
- "Remove from List" + re-discovery footgun is documented in the spec as a deferred backlog item.

---

## Task 1: `GitHubKit` — `DiscoveryHit` + `searchPRs` (TDD)

**Files:**
- Modify: `Core/Sources/GitHubKit/GitHubClient.swift` (add `DiscoveryHit`, `searchPRs(query:)`, `mapDiscoveryState`, private `GHSearchHit` decode struct)
- Modify: `Core/Tests/GitHubKitTests/GitHubClientTests.swift` (add 5 tests)

- [ ] **Step 1: Write the failing tests**

Append the following at the END of `Core/Tests/GitHubKitTests/GitHubClientTests.swift` (after `fetchReviewPopulatesClosingIssueNumber`):

```swift
private let sampleSearchJSON = """
[
  {
    "number": 944,
    "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 17,
    "title": "WIP",
    "url": "https://github.com/foo/bar/pull/17",
    "state": "open",
    "isDraft": true,
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "foo/bar" }
  }
]
"""

private let sampleSearchJSONWithMalformedRepo = """
[
  {
    "number": 944,
    "title": "ok",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 99,
    "title": "broken",
    "url": "https://example.com/x",
    "state": "open",
    "isDraft": false,
    "author": { "login": "x" },
    "repository": { "nameWithOwner": "no-slash-here" }
  }
]
"""

@Test func searchPRsParsesResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")

    let hits = try await client.searchPRs(query: "review-requested:@me")

    #expect(hits.count == 2)
    #expect(hits[0].owner == "bsv-blockchain")
    #expect(hits[0].repo == "teranode")
    #expect(hits[0].number == 944)
    #expect(hits[0].title == "fix(asset/centrifuge): speak bidirectional Centrifuge protocol")
    #expect(hits[0].authorLogin == "icellan")
    #expect(hits[0].state == "open")
    #expect(hits[0].isDraft == false)
    #expect(hits[0].id == "bsv-blockchain/teranode#944")

    #expect(hits[1].owner == "foo")
    #expect(hits[1].repo == "bar")
    #expect(hits[1].isDraft == true)
    #expect(hits[1].authorLogin == "alice")

    let args = await runner.lastArguments
    #expect(args == ["search", "prs", "review-requested:@me", "--json", "number,title,url,state,isDraft,author,repository", "--limit", "100"])
}

@Test func searchPRsHandlesEmptyResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "assignee:@me")

    #expect(hits.isEmpty)
}

@Test func searchPRsThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "auth required"))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    await #expect(throws: GitHubError.self) {
        try await client.searchPRs(query: "review-requested:@me")
    }
}

@Test func searchPRsSkipsMalformedRepository() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSONWithMalformedRepo, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "x")

    #expect(hits.count == 1)
    #expect(hits.first?.owner == "bsv-blockchain")
    #expect(hits.first?.repo == "teranode")
}

@Test func mapDiscoveryStateNormalizesCasing() {
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: false) == .open)
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: true) == .draft)
    #expect(GitHubClient.mapDiscoveryState(state: "merged", isDraft: false) == .merged)
    #expect(GitHubClient.mapDiscoveryState(state: "closed", isDraft: false) == .closed)
    #expect(GitHubClient.mapDiscoveryState(state: "MERGED", isDraft: false) == .merged)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `cannot find 'DiscoveryHit'`, `value of type 'GitHubClient' has no member 'searchPRs'`, `no member 'mapDiscoveryState'`.

- [ ] **Step 3: Add the new types and method**

Append the following to `Core/Sources/GitHubKit/GitHubClient.swift` (after the existing `GHPullRequest` struct, at the end of the file):

```swift
public struct DiscoveryHit: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let state: String
    public let isDraft: Bool

    public var id: String { "\(owner)/\(repo)#\(number)" }
    public var ref: PRRef { PRRef(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String, isDraft: Bool) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
        self.isDraft = isDraft
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
        let raw: [GHSearchHit]
        do {
            raw = try JSONDecoder().decode([GHSearchHit].self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
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
```

Note: `searchPRs` is defined in an `extension GitHubClient` block. Because the stored `runner` and `ghPath` properties are `private` (declared in the main `struct GitHubClient` body), the extension in the SAME FILE has access to them (Swift's same-file `private` scope rule). If the extension is moved to a separate file later, the properties would need to be promoted to `internal` or the method moved back into the struct body.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 5 new tests added, bringing total to 98 (93 prior + 5 new). 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/GitHubKit/GitHubClient.swift Core/Tests/GitHubKitTests/GitHubClientTests.swift
git commit -m "feat: add GitHubClient.searchPRs and DiscoveryHit" --no-verify
```

Verify `git log -1 --pretty=%B` is clean (no AI/Claude/Anthropic/Generated/Co-Authored-By trailers).

---

## Task 2: `AppModel` discovery polling integration (TDD)

**Files:**
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (extend `StubRunner`, add 5 new tests)
- Modify: `Core/Sources/AppCore/AppModel.swift` (add `discoveryTask`, `startDiscoveryPolling`, `discoverNow`, `mergeDiscoveryHits`; cancel discoveryTask in `terminateAllClaudeSessions`)
- Modify: `App/PRReviewApp.swift` (call `created.startDiscoveryPolling()` after `created.load()`)

- [ ] **Step 1: Extend `StubRunner` to support queued results**

In `Core/Tests/AppCoreTests/AppModelTests.swift`, replace the existing `StubRunner` declaration (around lines 12-16) with:

```swift
private actor StubRunner: CommandRunner {
    private var results: [CommandResult]
    private let fallback: CommandResult?

    init(result: CommandResult) {
        self.results = []
        self.fallback = result
    }

    init(results: [CommandResult]) {
        self.results = results
        self.fallback = nil
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        if !results.isEmpty {
            return results.removeFirst()
        }
        if let fallback {
            return fallback
        }
        throw NSError(domain: "StubRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "queue exhausted"])
    }
}
```

The single-result constructor (`init(result:)`) keeps the existing tests working — it now puts the result in `fallback` so it's returned forever. The new queued constructor (`init(results:)`) returns each result once, in order.

- [ ] **Step 2: Add the 5 new discovery tests**

Append the following to the end of `Core/Tests/AppCoreTests/AppModelTests.swift` (after `firstIdleTransitionFiresNotificationOnce`):

```swift
private let sampleSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let sampleMergedSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "merged",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let emptySearchJSON = "[]"

private let prFetchJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

@Test @MainActor func discoverNowPopulatesNewReviews() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.reviews.first?.origin == .discovered)
}

@Test @MainActor func discoverNowPromotesAddedToBoth() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.origin == .both)
}

@Test @MainActor func discoverNowKeepsPRsFallingOutOfQuery() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var existing = sampleReview()
    existing.origin = .discovered
    try await store.upsert(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
}

@Test @MainActor func discoverNowUpdatesPRState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var existing = sampleReview()
    existing.prState = .open
    existing.origin = .discovered
    try await store.upsert(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleMergedSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverNowDeduplicatesAcrossQueries() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
}
```

These tests rely on `Settings.default.discoveryQueries` returning exactly two queries (`["review-requested:@me", "assignee:@me"]`). Each test queues two search responses, in order. The new-PR tests also queue a third response for the `fetchReview` follow-up.

The tests use the existing stubs (`StubDiffLoader`, `StubWorktreeProvider`, `StubRegistrar`, `StubNotificationPoster`, `sampleReview`, `tempStoreURL`) — no new stubs needed.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `value of type 'AppModel' has no member 'discoverNow'`.

- [ ] **Step 4: Add discovery polling to `AppModel.swift`**

In `Core/Sources/AppCore/AppModel.swift`:

A. Add a new private stored property next to `tickTask`:

Change the existing:
```swift
    private var tickTask: Task<Void, Never>?
```

to:
```swift
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
```

B. Add `startDiscoveryPolling()`, `discoverNow()`, and `mergeDiscoveryHits(_:)` after the existing `tickAllActiveStatuses()` method (around line 78). Insert this block:

```swift
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

C. Add `discoveryTask` cancellation in `terminateAllClaudeSessions`. Change the existing first two lines from:

```swift
    public func terminateAllClaudeSessions() {
        tickTask?.cancel()
        tickTask = nil
```

to:

```swift
    public func terminateAllClaudeSessions() {
        tickTask?.cancel()
        tickTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
```

No other changes to `AppModel.swift`. `load()` does NOT call `startDiscoveryPolling()` — that's intentional, so tests don't trigger the background poll. App startup calls it explicitly (Step 5).

- [ ] **Step 5: Wire `startDiscoveryPolling()` into app startup**

In `App/PRReviewApp.swift`, find the `.task` block that constructs the model. The existing block is:

```swift
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    await created.load()
                    model = created
                    appDelegate.model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
```

Change it to:

```swift
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    await created.load()
                    created.startDiscoveryPolling()
                    model = created
                    appDelegate.model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
```

Only `created.startDiscoveryPolling()` is added — one line, between `await created.load()` and `model = created`. Everything else is unchanged.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 5 new AppModel discovery tests, bringing total to 103 (98 + 5). 0 failures.

- [ ] **Step 7: Build the app + brief launch verification**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID. Do NOT interact with the app — the human runs E2E.

After confirming the app starts cleanly: `pkill -9 -x PRReview` to clean up before handoff.

- [ ] **Step 8 (HUMAN runs this — DO NOT execute):** Manual E2E checklist:

1. Empty the store: `rm "$HOME/Library/Application Support/PRReview/store.json"` (optional, for a clean test).
2. Launch the app. Within ~5 seconds, PRs matching `review-requested:@me` and `assignee:@me` appear in the sidebar with no manual action.
3. Open one of them and verify: title is correct, author is correct, owner/repo line shows the right repo, status dot eventually appears (Plan 12), the Diff/Claude/GitHub tabs all work.
4. Manually add a PR via `+` that you know is ALSO in `review-requested:@me` (use one of the discovered ones). Within ~2 minutes (next poll interval), the entry should still be a single sidebar row — no duplicate. Inspecting the store at `~/Library/Application Support/PRReview/store.json` should show `"origin": "both"` for that entry.
5. While the app is running, merge or close one of your discovered PRs upstream on GitHub. Wait ~2 minutes for the next poll. The sidebar entry should remain visible (not auto-removed), and the JSON store should show the updated `prState` (e.g. `"merged"`).
6. Right-click → "Remove from List" on a discovered PR. Within ~2 minutes, it should reappear (known footgun, deferred to backlog).
7. Quit the app. Re-launch. PRs still appear (loaded from store first, then refreshed by the poll).

- [ ] **Step 9: Commit**

```bash
git add Core App
git commit -m "feat: auto-populate sidebar via gh search prs discovery polling" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Self-review

- **Spec coverage:**
  - Decision #1 (per-PR `gh pr view` follow-up) → Task 2 Step 4B `mergeDiscoveryHits` calls `client.fetchReview(for: hit.ref, origin: .discovered)` for new PRs.
  - Decision #2 (auto-start lifecycle) → Task 2 Step 5 (`PRReviewApp.swift` calls `startDiscoveryPolling()` after `load()`). Note the deviation from the spec's wording: polling is started by App startup, not `load()`, so tests don't have to fight the background task.
  - Decision #3 (dedup behaviors) → Task 2 Step 4B implements origin promotion (`.added → .both`), keeps fallouts (no remove on absence), updates `prState` + `title`.
  - Decision #4 (silent failure) → `try?` at every layer (search, fetchReview, upsert).
  - Decision #5 (no visual distinction) → zero `App/ContentView.swift` changes; sidebar shows all reviews uniformly.
  - Decision #6 (`gh search prs` field set) → Task 1 Step 3 uses exactly `"number,title,url,state,isDraft,author,repository"`.
  - Decision #7 (sequential concurrency) → Task 2 Step 4B uses `for query in queries` with `await`, not `withTaskGroup`.
  - Decision #8 (queued `StubRunner`) → Task 2 Step 1 extends the stub backwards-compatibly.
  - "Remove from List" footgun → flagged as a known issue in Step 8 manual E2E item 6.
- **Placeholder scan:** None. Every step has full file contents or precise call-site edits. No "TBD" / "implement later" / "similar to" / "add appropriate error handling".
- **Type consistency:**
  - `DiscoveryHit` struct shape consistent between Task 1 definition, Task 2 test data, and AppModel consumer.
  - `searchPRs(query:) async throws -> [DiscoveryHit]` signature consistent across definition, test calls, and AppModel.discoverNow.
  - `GitHubClient.mapDiscoveryState(state:isDraft:)` consistent between Task 1 definition and AppModel.mergeDiscoveryHits.
  - `AppModel.discoverNow()` is `internal` (no modifier), `startDiscoveryPolling()` is `public`. Tests call the internal one; production calls the public one.
  - `StubRunner` queued constructor (`init(results:)`) used in Task 2 tests, single-result constructor (`init(result:)`) preserved for existing tests.

## Definition of done

- `swift test --package-path Core` → 103 tests, 0 failures (93 prior + 5 GitHubKit search tests + 5 AppCore discovery tests).
- App builds; on launch, sidebar auto-populates with PRs matching `Settings.default.discoveryQueries` within ~5 seconds; subsequent polls every 120s update `prState`/`title` and dedup against manually-added PRs.
- 2 commits; working tree clean.
- Known follow-ups (out of scope): manual "Refresh now" button; persistent dismissal of discovered PRs ("Remove from List" footgun); Settings UI for editing queries and poll interval; rate-limit / banner-after-N-failures handling.
