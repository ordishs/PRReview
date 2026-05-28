# Plan 8 — Registered local clone

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop re-cloning a repo the user already has locally — let them point each PR's repo at an existing clone, and have the worktree be created off that clone.

**Architecture:** A pure `GitOriginParser` extracts owner/repo from any common origin-URL form. A `CloneRegistering` protocol (production: `GitCloneRegistrar`) validates that a picked folder is a git repo whose `origin` matches the PR's repo. `AppModel` gains `registerClone(for:localPath:)` (validates → persists `RegisteredRepo` via `ReviewStore`) and `registeredClonePath(for:)` (cached lookup). `DiffLoading.loadDiff` gains a `registeredClonePath: String?` param; `WorktreeDiffLoader` passes it to `WorktreeManager.resolveClone(...)` instead of `nil`. A small `DiffToolbarView` shows either a `📁 local: …` badge or a `Use local clone…` button that opens a folder picker.

**Tech Stack:** Swift 6, SwiftUI, the existing `WorktreeKit`/`DiffKit`/`CommandSupport`/`ReviewStore`/`AppCore` packages.

**Companion spec:** `docs/superpowers/specs/2026-05-28-diff-pane-enhancements-design.md`

**Plan sequence:** …7-diff-pane ✅ · **8-registered-clone (this)** · 9-diff-ux (file tree + split + hunk/file headers).

---

## Scope notes

- **Wiring + UX only.** The backend (`RegisteredRepo`, `ReviewStore.repo(forRemote:)/upsert/allRepos`, `WorktreeManager.resolveClone(registeredClonePath:)`) already exists.
- **Behavioral note (write into the plan, not the code):** registering after a PR's worktree was already created (against a managed clone) does not delete/recreate that worktree. The registration takes effect for **future** PRs from that repo (and is the path that lets you "add a PR from a local repo without ever cloning"). Worth surfacing in the UI later, but not part of this plan.
- **No `project.yml` changes.** App already depends on `AppCore` + `PRReviewModels` + `DiffKit`.

---

## File structure (this plan)

```
Core/Sources/AppCore/
    GitOriginParser.swift               (Task 1, new)
    CloneRegistering.swift              (Task 2, new — protocol + RegistrationError + GitCloneRegistrar)
    DiffLoading.swift                   (Task 2, edit — add registeredClonePath param)
    WorktreeDiffLoader.swift            (Task 2, edit — pass param through)
    AppModel.swift                      (Task 2, edit — registeredRepos cache, registerClone, registeredClonePath, loadDiff signature)
    AppModelFactory.swift               (Task 2, edit — build GitCloneRegistrar)

Core/Tests/AppCoreTests/
    GitOriginParserTests.swift          (Task 1, new — 7 tests)
    GitCloneRegistrarTests.swift        (Task 2, new — 3 tests)
    AppModelTests.swift                 (Task 2, edit — update 7 init sites + StubDiffLoader signature + add StubRegistrar + add 3 register-related tests + 1 pass-through test)

App/
    DiffToolbarView.swift               (Task 3, new)
    DiffPaneView.swift                  (Task 3, edit — VStack { DiffToolbarView; existing content })
```

---

## Task 1: `GitOriginParser`

**Files:**
- Create: `Core/Tests/AppCoreTests/GitOriginParserTests.swift`
- Create: `Core/Sources/AppCore/GitOriginParser.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/GitOriginParserTests.swift`:

```swift
import Testing
import AppCore

@Test func parsesHttpsURL() {
    let result = GitOriginParser.parse("https://github.com/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesHttpsURLWithDotGit() {
    let result = GitOriginParser.parse("https://github.com/bsv-blockchain/teranode.git")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesSshURL() {
    let result = GitOriginParser.parse("git@github.com:bsv-blockchain/teranode.git")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesUppercaseHost() {
    let result = GitOriginParser.parse("https://GitHub.COM/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesWwwHost() {
    let result = GitOriginParser.parse("https://www.github.com/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func rejectsNonGithubHost() {
    #expect(GitOriginParser.parse("https://gitlab.com/o/r") == nil)
}

@Test func rejectsMalformed() {
    #expect(GitOriginParser.parse("not a url") == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'GitOriginParser' in scope`.

- [ ] **Step 3: Create the parser**

Create `Core/Sources/AppCore/GitOriginParser.swift`:

```swift
import Foundation

public enum GitOriginParser {
    public static func parse(_ url: String) -> (owner: String, repo: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        if let range = withoutGit.range(of: "^https?://(www\\.)?github\\.com/", options: [.regularExpression, .caseInsensitive]) {
            return extract(from: String(withoutGit[range.upperBound...]))
        }
        if let range = withoutGit.range(of: "^git@github\\.com:", options: [.regularExpression, .caseInsensitive]) {
            return extract(from: String(withoutGit[range.upperBound...]))
        }
        return nil
    }

    private static func extract(from path: String) -> (owner: String, repo: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 56 tests total (49 prior + 7 new parser tests), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "feat: add GitOriginParser for github origin URLs"
```

---

## Task 2: Wiring — `CloneRegistering`, `AppModel` registration, `DiffLoading` pass-through

**Files:**
- Create: `Core/Sources/AppCore/CloneRegistering.swift`
- Create: `Core/Tests/AppCoreTests/GitCloneRegistrarTests.swift`
- Replace: `Core/Sources/AppCore/DiffLoading.swift` (add `registeredClonePath` to the protocol method)
- Replace: `Core/Sources/AppCore/WorktreeDiffLoader.swift` (accept the new param, pass it through)
- Replace: `Core/Sources/AppCore/AppModel.swift` (registeredRepos cache, registerClone, registeredClonePath, updated loadDiff, updated init)
- Replace: `Core/Sources/AppCore/AppModelFactory.swift` (build `GitCloneRegistrar`)
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (StubDiffLoader signature, add StubRegistrar, update 7 init sites, add 4 new tests)

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/AppCoreTests/GitCloneRegistrarTests.swift`:

```swift
import Testing
import Foundation
import CommandSupport
import AppCore

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

@Test func validateSucceedsWhenOriginMatches() async throws {
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "https://github.com/bsv-blockchain/teranode.git\n", standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
}

@Test func validateThrowsOnOriginMismatch() async {
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "https://github.com/other-org/other-repo.git\n", standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
    }
}

@Test func validateThrowsWhenNotAGitRepository() async {
    let runner = StubRunner(result: CommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: not a git repository"))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
    }
}
```

In `Core/Tests/AppCoreTests/AppModelTests.swift`:

(a) Add this stub near the top, after the existing `StubDiffLoader`:

```swift
private struct StubRegistrar: CloneRegistering {
    var shouldThrow: RegistrationError? = nil
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        if let error = shouldThrow {
            throw error
        }
    }
}

private actor RecordingDiffLoader: DiffLoading {
    private(set) var lastRegisteredClonePath: String?
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        lastRegisteredClonePath = registeredClonePath
        return DiffResult(worktreePath: "/tmp/wt", files: [])
    }
}
```

(b) Change the existing `StubDiffLoader.loadDiff` method to the new protocol signature:

```swift
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        if shouldThrow {
            throw DiffError.gitFailed(exitCode: 1, message: "stub failure")
        }
        return DiffResult(worktreePath: "/tmp/wt", files: files)
    }
```

(c) Update **every** existing `AppModel(store: store, client: client, diffLoader: …)` construction to also pass `cloneRegistrar: StubRegistrar()` as the new fourth argument. There are exactly 7 such sites (`addPRFetchesStoresAndSelects`, `addPRSetsErrorOnInvalidURL`, `loadReadsExistingReviews`, `addPRSurfacesCommandFailureAndDismisses`, `loadDiffSetsLoadedState`, `loadDiffSetsFailedStateOnError`, `loadDiffPersistsWorktreePath`).

(d) Add these four new tests:

```swift
@Test @MainActor func registerCloneSucceedsAndPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())
    await model.load()

    await model.registerClone(for: review, localPath: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredClonePath(for: review) == "/Users/me/dev/teranode")
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.repo(forRemote: "github.com/bsv-blockchain/teranode")?.localClonePath == "/Users/me/dev/teranode")
}

@Test @MainActor func registerCloneSetsErrorOnValidationFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(shouldThrow: .originMismatch(expected: "bsv-blockchain/teranode", actual: "x/y"))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: registrar)

    await model.registerClone(for: sampleReview(), localPath: "/wrong/path")

    #expect(model.errorMessage != nil)
    #expect(model.registeredClonePath(for: sampleReview()) == nil)
}

@Test @MainActor func loadDiffPassesRegisteredClonePathToLoader() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, cloneRegistrar: StubRegistrar())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == "/Users/me/dev/teranode")
}

@Test @MainActor func loadDiffPassesNilWhenNoRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, cloneRegistrar: StubRegistrar())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'GitCloneRegistrar'`/`'CloneRegistering'`/`'RegistrationError'`/`AppModel` `cloneRegistrar:` initializer or `registerClone`/`registeredClonePath`/new `loadDiff` signature.

- [ ] **Step 3: Create the registration protocol + production registrar**

Create `Core/Sources/AppCore/CloneRegistering.swift`:

```swift
import Foundation
import CommandSupport

public enum RegistrationError: Error, Equatable {
    case notAGitRepository(message: String)
    case unrecognizedOrigin(url: String)
    case originMismatch(expected: String, actual: String)
}

public protocol CloneRegistering: Sendable {
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws
}

public struct GitCloneRegistrar: CloneRegistering {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", localPath, "remote", "get-url", "origin"]
        )
        guard result.exitCode == 0 else {
            throw RegistrationError.notAGitRepository(message: result.standardError)
        }
        let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (actualOwner, actualRepo) = GitOriginParser.parse(url) else {
            throw RegistrationError.unrecognizedOrigin(url: url)
        }
        let actual = "\(actualOwner)/\(actualRepo)".lowercased()
        let expected = "\(expectedOwner)/\(expectedRepo)".lowercased()
        guard actual == expected else {
            throw RegistrationError.originMismatch(expected: "\(expectedOwner)/\(expectedRepo)", actual: "\(actualOwner)/\(actualRepo)")
        }
    }
}
```

- [ ] **Step 4: Update the `DiffLoading` protocol**

Replace the ENTIRE contents of `Core/Sources/AppCore/DiffLoading.swift` with:

```swift
import DiffKit
import PRReviewModels

public enum DiffLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded([DiffFile])
    case failed(String)
}

public struct DiffResult: Sendable, Equatable {
    public var worktreePath: String
    public var files: [DiffFile]

    public init(worktreePath: String, files: [DiffFile]) {
        self.worktreePath = worktreePath
        self.files = files
    }
}

public protocol DiffLoading: Sendable {
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult
}
```

- [ ] **Step 5: Update `WorktreeDiffLoader`**

Replace the ENTIRE contents of `Core/Sources/AppCore/WorktreeDiffLoader.swift` with:

```swift
import Foundation
import PRReviewModels
import WorktreeKit
import DiffKit

public struct WorktreeDiffLoader: DiffLoading {
    private let worktreeManager: WorktreeManager
    private let diffService: DiffService

    public init(worktreeManager: WorktreeManager, diffService: DiffService) {
        self.worktreeManager = worktreeManager
        self.diffService = diffService
    }

    public func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: registeredClonePath
        )
        let worktreePath: String
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            worktreePath = existing
        } else {
            worktreePath = try await worktreeManager.createWorktree(
                clonePath: clonePath,
                owner: review.owner,
                repo: review.repo,
                number: review.number
            )
        }
        let base = try await worktreeManager.mergeBase(worktreePath: worktreePath, baseRef: "origin/\(review.baseBranch)")
        let files = try await diffService.diff(worktreePath: worktreePath, baseRef: base)
        return DiffResult(worktreePath: worktreePath, files: files)
    }
}
```

- [ ] **Step 6: Update `AppModel`**

Replace the ENTIRE contents of `Core/Sources/AppCore/AppModel.swift` with:

```swift
import Foundation
import Observation
import PRReviewModels
import ReviewStore
import GitHubKit

@MainActor
@Observable
public final class AppModel {
    public private(set) var reviews: [Review] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var diffState: DiffLoadState = .idle
    public private(set) var registeredRepos: [RegisteredRepo] = []

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let cloneRegistrar: CloneRegistering

    public init(store: ReviewStore, client: GitHubClient, diffLoader: DiffLoading, cloneRegistrar: CloneRegistering) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.cloneRegistrar = cloneRegistrar
    }

    public func load() async {
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
    }

    public func addPR(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let ref = try PRRef.parse(urlString)
            let review = try await client.fetchReview(for: ref)
            try await store.upsert(review)
            reviews = await store.allReviews()
            selection = review.id
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registeredClonePath(for review: Review) -> String? {
        let identity = "github.com/\(review.owner)/\(review.repo)"
        return registeredRepos.first { $0.remoteIdentity == identity }?.localClonePath
    }

    public func registerClone(for review: Review, localPath: String) async {
        do {
            try await cloneRegistrar.validate(localPath: localPath, expectedOwner: review.owner, expectedRepo: review.repo)
            let identity = "github.com/\(review.owner)/\(review.repo)"
            let entry = RegisteredRepo(remoteIdentity: identity, localClonePath: localPath, defaultBase: review.baseBranch)
            try await store.upsert(entry)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func loadDiff(for review: Review) async {
        diffState = .loading
        do {
            let result = try await diffLoader.loadDiff(for: review, registeredClonePath: registeredClonePath(for: review))
            if review.worktreePath != result.worktreePath {
                var updated = review
                updated.worktreePath = result.worktreePath
                try await store.upsert(updated)
                reviews = await store.allReviews()
            }
            diffState = .loaded(result.files)
        } catch {
            diffState = .failed(String(describing: error))
        }
    }

    public func selectedReview() -> Review? {
        guard let selection else { return nil }
        return reviews.first { $0.id == selection }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
```

- [ ] **Step 7: Update `AppModelFactory`**

Replace the ENTIRE contents of `Core/Sources/AppCore/AppModelFactory.swift` with:

```swift
import Foundation
import PRReviewModels
import ReviewStore
import GitHubKit
import CommandSupport
import WorktreeKit
import DiffKit

public enum AppModelFactory {
    @MainActor
    public static func makeDefault() throws -> AppModel {
        let settings = Settings.default
        let storeURL = URL(fileURLWithPath: settings.managedRoot).appendingPathComponent("store.json")
        let store = try ReviewStore(fileURL: storeURL)

        let ghPath = settings.ghPath ?? ToolResolver.resolve("gh") ?? "/opt/homebrew/bin/gh"
        let gitPath = settings.gitPath ?? ToolResolver.resolve("git") ?? "/opt/homebrew/bin/git"

        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        let worktreeManager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: settings.managedRoot)
        let diffService = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
        let diffLoader = WorktreeDiffLoader(worktreeManager: worktreeManager, diffService: diffService)
        let cloneRegistrar = GitCloneRegistrar(runner: ProcessCommandRunner(), gitPath: gitPath)

        return AppModel(store: store, client: client, diffLoader: diffLoader, cloneRegistrar: cloneRegistrar)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 62 tests total (56 prior + 3 GitCloneRegistrar + 3 register-related + ~~0 already-passing pass-through~~ … actually 56 + 3 + 4 = 63 if the existing-tests still count; recount on the green output. If the count differs by ±1, that's fine — what matters is 0 failures and that ALL `registerClone…` and `loadDiff…Path…` tests pass).

> Don't gate on the exact count — gate on 0 failures and the named new tests being present and green.

- [ ] **Step 9: Commit**

```bash
git add Core
git commit -m "feat: register local clones and pass them to the diff loader"
```

---

## Task 3: Diff toolbar UI (local-clone control)

**Files:**
- Create: `App/DiffToolbarView.swift`
- Modify: `App/DiffPaneView.swift` (wrap existing body in a `VStack` with the toolbar on top)

### Verification model

GUI wiring; no unit tests. You verify by **build succeeds + app launches without crashing** (`pgrep`). Do Steps 1–4 + Step 6 (commit); skip the interactive Step 5 (the human does the add/register E2E).

- [ ] **Step 1: Create the toolbar view**

Create `App/DiffToolbarView.swift`:

```swift
import SwiftUI
import PRReviewModels
import AppCore

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review
    @State private var showingFolderPicker = false

    var body: some View {
        HStack {
            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Use local clone…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(8)
        .font(.callout)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                await model.registerClone(for: review, localPath: url.path)
                if model.errorMessage == nil {
                    await model.loadDiff(for: review)
                }
            }
        }
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
```

- [ ] **Step 2: Wire the toolbar into `DiffPaneView`**

Replace the ENTIRE contents of `App/DiffPaneView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import DiffKit
import AppCore

struct DiffPaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        VStack(spacing: 0) {
            DiffToolbarView(model: model, review: review)
            Divider()
            Group {
                switch model.diffState {
                case .idle, .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Checking out worktree and computing diff…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                case .loaded(let files):
                    if files.isEmpty {
                        Text("No changes")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(files) { file in
                                    DiffFileView(file: file)
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
        }
        .task(id: review.id) {
            await model.loadDiff(for: review)
        }
    }
}

private struct DiffFileView: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.newPath ?? file.oldPath ?? "?")
                    .font(.system(.body, design: .monospaced))
                    .bold()
                Spacer()
                Text("+\(file.addedCount)").foregroundStyle(.green)
                Text("−\(file.removedCount)").foregroundStyle(.red)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))

            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(symbol + line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.system(.caption, design: .monospaced))
        .background(background)
    }

    private var symbol: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }
}
```

- [ ] **Step 3: Generate, build, launch (with `open -n`)**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID.

- [ ] **Step 4: Self-review**

Confirm: only the two specified files in `App/` changed; no comments added; `DiffToolbarView` is fileImporter-based; `DiffPaneView` still has `.task(id: review.id)` on the outer `VStack` so loading still triggers.

- [ ] **Step 5 (manual, the human):** select a PR whose repo you've cloned locally. The Diff tab shows **"Use local clone…"**. Click it, pick the folder (the existing local checkout). On success, the badge changes to `local: ~/path/to/clone`. Add a *second* PR from the same repo; that PR's diff loads instantly (no fresh clone). Picking the *wrong* folder (different repo) shows an error alert. (The first PR's existing worktree stays where it was — registration takes effect for the next PR from that repo.)

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "feat: add Use-local-clone toolbar to the Diff pane"
```

---

## Self-review (this plan vs. the spec)

- **Spec coverage:** Decision #4 (folder picker on demand) → Task 3 `DiffToolbarView` with `fileImporter`. Decision #5 (validate origin matches; allow https/ssh/.git/uppercase) → Task 1 `GitOriginParser` + Task 2 `GitCloneRegistrar`. The wiring requirement (`WorktreeDiffLoader` looks up the registered path) → Task 2's protocol pass-through. Persistence via `RegisteredRepo` → Task 2's `AppModel.registerClone`. The `📁 local` badge → Task 3.
- **Placeholder scan:** none — full file contents and exact commands; tests assert real behavior (URL forms, origin match/mismatch/no-repo, persistence, pass-through to the loader).
- **Type consistency:** `GitOriginParser.parse(_:) -> (owner:String, repo:String)?` is referenced identically across tests, registrar, and (in Plan 9) potential reuse. `CloneRegistering.validate(localPath:expectedOwner:expectedRepo:) async throws` matches between protocol, production impl, and the stub. `RegistrationError` cases match the registrar's `throw` sites. `AppModel.init(store:client:diffLoader:cloneRegistrar:)` matches every call site (production factory + 7 existing tests + 4 new tests). `DiffLoading.loadDiff(for:registeredClonePath:)` matches `WorktreeDiffLoader`, `StubDiffLoader`, and `RecordingDiffLoader`. The `RegisteredRepo` constructor (`remoteIdentity:localClonePath:defaultBase:`) and `ReviewStore.repo(forRemote:)` match the existing module.

## Definition of done

- `swift test --package-path Core` passes (0 failures), with all new tests (`Git*ParserTests`, `GitCloneRegistrarTests`, the 4 new AppModel tests) green.
- The app builds and launches with `open -n`.
- Manual E2E: selecting a PR from a repo you have locally shows "Use local clone…", picking the folder validates and persists, and a *subsequent* PR from the same repo loads its diff from that path with no fresh clone.
- Three commits; working tree clean.
