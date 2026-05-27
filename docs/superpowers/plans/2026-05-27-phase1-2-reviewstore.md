# PR Review — Phase 1, Plan 2: ReviewStore

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the durable persistence layer — the value-type data model plus a `ReviewStore` actor that loads and atomically saves the app's state as a single JSON document.

**Architecture:** The shared value types (`Review`, `RegisteredRepo`, `Settings`, and supporting enums) live in the `PRReviewModels` target so every other module can use them. The `ReviewStore` target holds a single `actor ReviewStore` that owns the in-memory `StoreState`, exposes CRUD methods, and persists to `managedRoot/store.json` via atomic writes. All logic is exercised through `swift test`.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package Manager, Swift Testing, Foundation (`Codable`, `JSONEncoder`, `FileManager`).

**Companion spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md` (see "Data model & persistence").

**Plan sequence (Phase 1):** 1-scaffold ✅ → **2-reviewstore (this)** → 3-githubkit → 4-worktreekit → 5-diffkit → 6-app-integration.

---

## Scope notes

- **No `project.yml` / app changes in this plan.** `ReviewStore` is built and tested in isolation with `swift test`. The app target only needs to link it during Plan 6 (App integration), where it's actually consumed. Adding the dependency now would create an unused link, so it is intentionally deferred — this is the conscious resolution of the carry-forward note from Plan 1's final review.
- **Persisted vs derived:** this store holds only durable facts (reviews, registered repos, settings). Volatile status (Claude transcript state, live PR state, diffs) is derived at runtime in later plans and never stored here.
- **Module/type naming:** the target is `ReviewStore` and the actor is also `ReviewStore`. This same-name pattern is already proven to compile and pass in this package — Plan 1's `PRReviewModels` enum lives in the `PRReviewModels` module and its test references `PRReviewModels.schemaVersion` successfully. Type-in-expression lookup resolves to the type.

---

## Task 1: Durable model types in `PRReviewModels`

**Files:**
- Create: `Core/Sources/PRReviewModels/PRState.swift`
- Create: `Core/Sources/PRReviewModels/ReviewOrigin.swift`
- Create: `Core/Sources/PRReviewModels/DiffMode.swift`
- Create: `Core/Sources/PRReviewModels/Review.swift`
- Create: `Core/Sources/PRReviewModels/RegisteredRepo.swift`
- Create: `Core/Sources/PRReviewModels/Settings.swift`
- Test: `Core/Tests/PRReviewModelsTests/ModelsTests.swift`

> The existing `Schema.swift` (`schemaVersion`) and `SchemaTests.swift` stay unchanged. We add new files alongside them.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRReviewModelsTests/ModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import PRReviewModels

@Test func reviewIDIsOwnerRepoNumber() {
    #expect(Review.makeID(owner: "bsv-blockchain", repo: "teranode", number: 944) == "bsv-blockchain/teranode#944")
}

@Test func reviewRoundTripsThroughCodable() throws {
    let review = Review(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix",
        author: "icellan",
        headBranch: "fix/centrifuge",
        baseBranch: "main",
        origin: .added,
        prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(review)
    let decoded = try JSONDecoder().decode(Review.self, from: data)
    #expect(decoded == review)
    #expect(decoded.id == "bsv-blockchain/teranode#944")
}

@Test func settingsDefaultHasExpectedValues() {
    let settings = Settings.default
    #expect(settings.managedRoot.hasSuffix("PRReview"))
    #expect(settings.discoveryQueries == ["review-requested:@me", "assignee:@me"])
    #expect(settings.pollIntervalSeconds == 120)
    #expect(settings.diffMode == .unified)
    #expect(settings.notificationsEnabled == true)
}

@Test func reviewOriginDecodesFromString() throws {
    let decoded = try JSONDecoder().decode(ReviewOrigin.self, from: Data("\"both\"".utf8))
    #expect(decoded == .both)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'Review' in scope`, `cannot find 'Settings' in scope`, `cannot find 'ReviewOrigin' in scope` (the types don't exist yet).

- [ ] **Step 3: Create the enums**

Create `Core/Sources/PRReviewModels/PRState.swift`:

```swift
public enum PRState: String, Codable, Sendable {
    case open
    case draft
    case merged
    case closed
}
```

Create `Core/Sources/PRReviewModels/ReviewOrigin.swift`:

```swift
public enum ReviewOrigin: String, Codable, Sendable {
    case discovered
    case added
    case both
}
```

Create `Core/Sources/PRReviewModels/DiffMode.swift`:

```swift
public enum DiffMode: String, Codable, Sendable {
    case unified
    case split
}
```

- [ ] **Step 4: Create the `Review` type**

Create `Core/Sources/PRReviewModels/Review.swift`:

```swift
import Foundation

public struct Review: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var owner: String
    public var repo: String
    public var number: Int
    public var url: URL
    public var title: String
    public var author: String
    public var headBranch: String
    public var baseBranch: String
    public var origin: ReviewOrigin
    public var prState: PRState
    public var worktreePath: String?
    public var notes: String?
    public var claudeFlags: [String]?
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        owner: String,
        repo: String,
        number: Int,
        url: URL,
        title: String,
        author: String,
        headBranch: String,
        baseBranch: String,
        origin: ReviewOrigin,
        prState: PRState,
        worktreePath: String? = nil,
        notes: String? = nil,
        claudeFlags: [String]? = nil,
        addedAt: Date,
        lastOpenedAt: Date? = nil
    ) {
        self.id = Review.makeID(owner: owner, repo: repo, number: number)
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.origin = origin
        self.prState = prState
        self.worktreePath = worktreePath
        self.notes = notes
        self.claudeFlags = claudeFlags
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    public static func makeID(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }
}
```

- [ ] **Step 5: Create the `RegisteredRepo` type**

Create `Core/Sources/PRReviewModels/RegisteredRepo.swift`:

```swift
public struct RegisteredRepo: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var remoteIdentity: String
    public var localClonePath: String
    public var defaultBase: String

    public init(remoteIdentity: String, localClonePath: String, defaultBase: String) {
        self.id = remoteIdentity
        self.remoteIdentity = remoteIdentity
        self.localClonePath = localClonePath
        self.defaultBase = defaultBase
    }
}
```

- [ ] **Step 6: Create the `Settings` type**

Create `Core/Sources/PRReviewModels/Settings.swift`:

```swift
import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var managedRoot: String
    public var discoveryQueries: [String]
    public var pollIntervalSeconds: Int
    public var ghPath: String?
    public var gitPath: String?
    public var claudePath: String?
    public var claudeLaunchArgs: [String]
    public var notificationsEnabled: Bool
    public var diffMode: DiffMode
    public var diffIgnoreWhitespace: Bool

    public init(
        managedRoot: String,
        discoveryQueries: [String],
        pollIntervalSeconds: Int,
        ghPath: String? = nil,
        gitPath: String? = nil,
        claudePath: String? = nil,
        claudeLaunchArgs: [String],
        notificationsEnabled: Bool,
        diffMode: DiffMode,
        diffIgnoreWhitespace: Bool
    ) {
        self.managedRoot = managedRoot
        self.discoveryQueries = discoveryQueries
        self.pollIntervalSeconds = pollIntervalSeconds
        self.ghPath = ghPath
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.claudeLaunchArgs = claudeLaunchArgs
        self.notificationsEnabled = notificationsEnabled
        self.diffMode = diffMode
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
    }

    public static let `default` = Settings(
        managedRoot: Settings.defaultManagedRoot(),
        discoveryQueries: ["review-requested:@me", "assignee:@me"],
        pollIntervalSeconds: 120,
        claudeLaunchArgs: [],
        notificationsEnabled: true,
        diffMode: .unified,
        diffIgnoreWhitespace: false
    )

    public static func defaultManagedRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PRReview", isDirectory: true).path
    }
}
```

> `claudeLaunchArgs` defaults to empty — the security posture (e.g. `--dangerously-skip-permissions`) is the user's choice, configured later, not baked into the model default.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 5 tests total (the original `schemaVersionIsOne` plus the 4 new ones), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Core
git commit -m "feat: add durable model types to PRReviewModels"
```

---

## Task 2: The `ReviewStore` actor with atomic JSON persistence

**Files:**
- Create: `Core/Tests/ReviewStoreTests/ReviewStoreTests.swift`
- Modify: `Core/Package.swift` (add the `ReviewStoreTests` test target)
- Replace: `Core/Sources/ReviewStore/ReviewStore.swift` (placeholder enum → the actor)
- Create: `Core/Sources/ReviewStore/StoreState.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/ReviewStoreTests/ReviewStoreTests.swift`:

```swift
import Testing
import Foundation
import PRReviewModels
import ReviewStore

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("prreview-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private func sampleReview(number: Int = 944, title: String = "centrifuge fix") -> Review {
    Review(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: number,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
        title: title,
        author: "icellan",
        headBranch: "fix/centrifuge",
        baseBranch: "main",
        origin: .added,
        prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func newStoreCreatesFileAndStartsEmpty() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let reviews = await store.allReviews()
    #expect(reviews.isEmpty)
}

@Test func upsertAddsThenReplacesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(sampleReview(title: "first"))
    var all = await store.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.title == "first")

    try await store.upsert(sampleReview(title: "second"))
    all = await store.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.title == "second")
}

@Test func removeReviewDeletesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    try await store.removeReview(id: review.id)
    let all = await store.allReviews()
    #expect(all.isEmpty)
}

@Test func reviewsPersistAcrossReload() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview(number: 901, title: "prune subtrees"))

    let reloaded = try ReviewStore(fileURL: url)
    let all = await reloaded.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.number == 901)
    #expect(all.first?.id == "bsv-blockchain/teranode#901")
}

@Test func registeredRepoLookupByRemote() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let repo = RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    )
    try await store.upsert(repo)
    let found = await store.repo(forRemote: "github.com/bsv-blockchain/teranode")
    #expect(found?.localClonePath == "/Users/me/dev/teranode")
}

@Test func settingsUpdatePersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var settings = await store.settings()
    settings.diffMode = .split
    settings.pollIntervalSeconds = 300
    try await store.updateSettings(settings)

    let reloaded = try ReviewStore(fileURL: url)
    let reloadedSettings = await reloaded.settings()
    #expect(reloadedSettings.diffMode == .split)
    #expect(reloadedSettings.pollIntervalSeconds == 300)
}
```

- [ ] **Step 2: Register the test target in the manifest**

Replace the entire contents of `Core/Package.swift` with (this adds the `ReviewStoreTests` test target; everything else is unchanged from Plan 1):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRReviewModels", targets: ["PRReviewModels"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "ClaudeSessionKit", targets: ["ClaudeSessionKit"]),
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels"]),
        .target(name: "WorktreeKit", dependencies: ["PRReviewModels"]),
        .target(name: "DiffKit", dependencies: ["PRReviewModels"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
    ]
)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'ReviewStore' in scope` used as an initializer (the `ReviewStore` target currently only contains the placeholder `enum ReviewStoreModule`, not the actor).

- [ ] **Step 4: Implement the actor**

Replace the entire contents of `Core/Sources/ReviewStore/ReviewStore.swift` with:

```swift
import Foundation
import PRReviewModels

public actor ReviewStore {
    private let fileURL: URL
    private var state: StoreState

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.state = try ReviewStore.loadOrCreate(at: fileURL)
    }

    public func allReviews() -> [Review] {
        state.reviews
    }

    public func review(id: String) -> Review? {
        state.reviews.first { $0.id == id }
    }

    public func upsert(_ review: Review) throws {
        if let index = state.reviews.firstIndex(where: { $0.id == review.id }) {
            state.reviews[index] = review
        } else {
            state.reviews.append(review)
        }
        try persist()
    }

    public func removeReview(id: String) throws {
        state.reviews.removeAll { $0.id == id }
        try persist()
    }

    public func allRepos() -> [RegisteredRepo] {
        state.registeredRepos
    }

    public func repo(forRemote remoteIdentity: String) -> RegisteredRepo? {
        state.registeredRepos.first { $0.remoteIdentity == remoteIdentity }
    }

    public func upsert(_ repo: RegisteredRepo) throws {
        if let index = state.registeredRepos.firstIndex(where: { $0.id == repo.id }) {
            state.registeredRepos[index] = repo
        } else {
            state.registeredRepos.append(repo)
        }
        try persist()
    }

    public func removeRepo(id: String) throws {
        state.registeredRepos.removeAll { $0.id == id }
        try persist()
    }

    public func settings() -> Settings {
        state.settings
    }

    public func updateSettings(_ settings: Settings) throws {
        state.settings = settings
        try persist()
    }

    private func persist() throws {
        let data = try ReviewStore.makeEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func loadOrCreate(at url: URL) throws -> StoreState {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode(StoreState.self, from: data)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let initial = StoreState(
            schemaVersion: PRReviewModels.schemaVersion,
            reviews: [],
            registeredRepos: [],
            settings: .default
        )
        let data = try makeEncoder().encode(initial)
        try data.write(to: url, options: [.atomic])
        return initial
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

> `JSONEncoder`/`JSONDecoder` are built fresh in helper functions rather than stored as `static let`, because under Swift 6 a `static let` of a non-`Sendable` type (which these are) is a concurrency-safety error. The cost of constructing them per save is negligible at this scale.

- [ ] **Step 5: Add the persisted document type**

Create `Core/Sources/ReviewStore/StoreState.swift`:

```swift
import PRReviewModels

struct StoreState: Codable, Sendable {
    var schemaVersion: Int
    var reviews: [Review]
    var registeredRepos: [RegisteredRepo]
    var settings: Settings
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — all tests across both test targets (5 in `PRReviewModelsTests`, 6 in `ReviewStoreTests`) pass, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "feat: implement ReviewStore actor with atomic JSON persistence"
```

---

## Self-review (this plan vs. its slice of the spec)

- **Spec coverage:** the spec's "Durable (persisted)" block is fully realized — `Review` (with `id`, identity, cached metadata, `origin`, `worktreePath?`, `prState`, `notes?`, `claudeFlags?`, timestamps), `RegisteredRepo` (remote identity, local clone path, default base), and `Settings` (managedRoot, discoveryQueries, pollInterval, tool paths, claudeLaunchArgs, notifications, diff defaults). The "atomic JSON document at `managedRoot/store.json`" and the actor-isolation requirement are implemented. The "derived/never-persisted" data is correctly excluded.
- **Placeholder scan:** none — every file's full contents and every command's expected output are given. Tests assert real behavior (Codable round-trip equality, upsert-replace semantics, persistence across a fresh store instance, lookup, settings durability), not tautologies.
- **Type consistency:** test call sites match the implementation — `Review.makeID(owner:repo:number:)`, `Review.init(...)` (no `id:` argument; `id` is derived), `ReviewStore(fileURL:)`, `upsert(_:)` overloaded for `Review` and `RegisteredRepo`, `removeReview(id:)`, `repo(forRemote:)`, `settings()`/`updateSettings(_:)`, and `Settings.default` / `Settings.defaultManagedRoot()`. `StoreState` fields (`schemaVersion`, `reviews`, `registeredRepos`, `settings`) match `loadOrCreate`'s initializer. Async/throws annotations on the actor methods match the `try await` / `await` usage in tests.

## Definition of done

- `swift test --package-path Core` → 11 tests passing (5 models + 6 store), 0 failures.
- A fresh `ReviewStore(fileURL:)` against an existing file loads previously-saved reviews/repos/settings (persistence verified).
- `store.json` is written atomically with its parent directory auto-created.
- Two commits made; working tree clean; no `project.yml` or app changes.
