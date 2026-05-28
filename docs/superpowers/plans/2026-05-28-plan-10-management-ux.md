# Plan 10 — Management UX

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move local-clone registration out of the PR Diff toolbar into a global "Manage Local Clones" sheet reachable from a macOS menu, and add a "Remove from List" action for PRs (right-click and `⌫`).

**Architecture:** `AppCore` gains three `AppModel` actions (`registerLocalClone(at:)`, `removeRegisteredRepo(remoteIdentity:)`, `removeReview(id:)`) and a new `CloneRegistering.detectRepositories(at:)` method that returns every GitHub `owner/repo` parsed from `git remote -v`. The App target gains a `ManageLocalClonesView` sheet, a `Repositories ▸ Manage Local Clones…` menu via SwiftUI `.commands`, and sidebar context-menu + `.onDeleteCommand` for review removal. The Diff toolbar loses the "Use local clone…" button and is conditionally hidden when no clone is registered.

**Tech Stack:** Swift 6, SwiftUI (`fileImporter`, `.commands`, `.contextMenu`, `.onDeleteCommand`), existing `AppCore` / `ReviewStore` / `CommandSupport`.

**Companion spec:** `docs/superpowers/specs/2026-05-28-management-ux-design.md`

**Plan sequence:** …8-registered-clone ✅ · **10-management-ux (this)** · 9-diff-ux (file tree + split view — deferred).

---

## File structure

```
Core/Sources/AppCore/
    CloneRegistering.swift   (edit — add detectRepositories method on protocol + impl)
    AppModel.swift           (edit — add registerLocalClone, removeRegisteredRepo, removeReview)

Core/Tests/AppCoreTests/
    GitCloneRegistrarTests.swift  (edit — add 3 detectRepositories tests)
    AppModelTests.swift           (edit — update StubRegistrar; add 5 tests)

App/
    DiffToolbarView.swift           (edit — strip the Use-local-clone button, badge-only)
    DiffPaneView.swift              (edit — conditionally render toolbar+divider)
    PRReviewApp.swift               (edit — add .commands menu + showingManage state + sheet)
    ManageLocalClonesView.swift     (new — the sheet)
    ContentView.swift               (edit — sidebar .contextMenu + .onDeleteCommand)
```

No `project.yml` change. No `RegisteredRepo` schema change. No `AppModel` init-signature change.

---

## Task 1: AppCore — detection, registration, removal

**Files:**
- Modify: `Core/Sources/AppCore/CloneRegistering.swift`
- Modify: `Core/Sources/AppCore/AppModel.swift`
- Modify: `Core/Tests/AppCoreTests/GitCloneRegistrarTests.swift`
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift`

- [ ] **Step 1: Write the failing tests**

(a) **Update `Core/Tests/AppCoreTests/GitCloneRegistrarTests.swift`** — keep the existing four tests as-is, and add these three at the bottom of the file:

```swift
@Test func detectRepositoriesReturnsAllGitHubRemotes() async throws {
    let stdout = remoteListing([
        (name: "origin", url: "git@github.com:ordishs/teranode.git"),
        (name: "upstream", url: "https://github.com/bsv-blockchain/teranode.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    let identities = try await registrar.detectRepositories(at: "/some/path")
    #expect(identities.sorted() == ["bsv-blockchain/teranode", "ordishs/teranode"])
}

@Test func detectRepositoriesReturnsEmptyWhenNoGitHubRemotes() async throws {
    let stdout = remoteListing([
        (name: "origin", url: "git@gitlab.com:internal/repo.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    let identities = try await registrar.detectRepositories(at: "/some/path")
    #expect(identities.isEmpty)
}

@Test func detectRepositoriesThrowsWhenNotAGitRepository() async {
    let runner = StubRunner(result: CommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: not a git repository"))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        _ = try await registrar.detectRepositories(at: "/some/path")
    }
}
```

(`remoteListing` and `StubRunner` already exist in that test file.)

(b) **Update `Core/Tests/AppCoreTests/AppModelTests.swift`** — replace the existing `StubRegistrar` struct to satisfy the new protocol method, then add the five new tests.

Find the existing `StubRegistrar` and replace it with:

```swift
private struct StubRegistrar: CloneRegistering {
    var shouldThrow: RegistrationError? = nil
    var detectedRepositories: [String] = []
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        if let error = shouldThrow {
            throw error
        }
    }
    func detectRepositories(at localPath: String) async throws -> [String] {
        if let error = shouldThrow {
            throw error
        }
        return detectedRepositories
    }
}
```

Add these five tests at the bottom of the file:

```swift
@Test @MainActor func registerLocalCloneRegistersAllDetected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: ["ordishs/teranode", "bsv-blockchain/teranode"])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: registrar)

    await model.registerLocalClone(at: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredRepos.count == 2)
    let identities = model.registeredRepos.map(\.remoteIdentity).sorted()
    #expect(identities == ["github.com/bsv-blockchain/teranode", "github.com/ordishs/teranode"])
    #expect(model.registeredRepos.allSatisfy { $0.localClonePath == "/Users/me/dev/teranode" })
}

@Test @MainActor func registerLocalCloneSetsErrorWhenNoReposFound() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: [])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: registrar)

    await model.registerLocalClone(at: "/Users/me/empty")

    #expect(model.errorMessage != nil)
    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeRegisteredRepoDeletes() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())
    await model.load()
    #expect(model.registeredRepos.count == 1)

    await model.removeRegisteredRepo(remoteIdentity: "github.com/bsv-blockchain/teranode")

    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeReviewRemovesFromStoreAndClearsSelection() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())
    await model.load()
    model.selection = review.id

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(model.selection == nil)
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allReviews().isEmpty)
}

@Test @MainActor func removeReviewBestEffortRemovesWorktreeDir() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let tempWorktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: tempWorktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = tempWorktree
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tempWorktree))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `CloneRegistering` protocol has no `detectRepositories` member; `AppModel` has no `registerLocalClone`/`removeRegisteredRepo`/`removeReview`.

- [ ] **Step 3: Extend the `CloneRegistering` protocol and its production impl**

Replace the ENTIRE contents of `Core/Sources/AppCore/CloneRegistering.swift` with:

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
    func detectRepositories(at localPath: String) async throws -> [String]
}

public struct GitCloneRegistrar: CloneRegistering {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        let entries = try await fetchRemoteEntries(localPath: localPath)
        let expected = "\(expectedOwner)/\(expectedRepo)".lowercased()
        var actualMatches: [String] = []
        for entry in entries {
            let actual = "\(entry.owner)/\(entry.repo)"
            if actual.lowercased() == expected {
                return
            }
            if !actualMatches.contains(actual) {
                actualMatches.append(actual)
            }
        }
        let actualList = actualMatches.isEmpty ? "no github remotes" : actualMatches.joined(separator: ", ")
        throw RegistrationError.originMismatch(expected: "\(expectedOwner)/\(expectedRepo)", actual: actualList)
    }

    public func detectRepositories(at localPath: String) async throws -> [String] {
        let entries = try await fetchRemoteEntries(localPath: localPath)
        var found: [String] = []
        for entry in entries {
            let identity = "\(entry.owner)/\(entry.repo)"
            if !found.contains(identity) {
                found.append(identity)
            }
        }
        return found
    }

    private func fetchRemoteEntries(localPath: String) async throws -> [(owner: String, repo: String)] {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", localPath, "remote", "-v"]
        )
        guard result.exitCode == 0 else {
            throw RegistrationError.notAGitRepository(message: result.standardError)
        }
        var entries: [(owner: String, repo: String)] = []
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let urlPart = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            if let (owner, repo) = GitOriginParser.parse(urlPart) {
                entries.append((owner: owner, repo: repo))
            }
        }
        return entries
    }
}
```

- [ ] **Step 4: Add the new `AppModel` methods**

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

    public func registerLocalClone(at localPath: String) async {
        do {
            let identities = try await cloneRegistrar.detectRepositories(at: localPath)
            guard !identities.isEmpty else {
                errorMessage = "No GitHub repositories found in \(localPath)"
                return
            }
            for identity in identities {
                let entry = RegisteredRepo(remoteIdentity: "github.com/\(identity)", localClonePath: localPath, defaultBase: "main")
                try await store.upsert(entry)
            }
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeRegisteredRepo(remoteIdentity: String) async {
        do {
            try await store.removeRepo(id: remoteIdentity)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeReview(id: String) async {
        guard let review = reviews.first(where: { $0.id == id }) else { return }
        if let worktreePath = review.worktreePath, FileManager.default.fileExists(atPath: worktreePath) {
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        do {
            try await store.removeReview(id: id)
            reviews = await store.allReviews()
            if selection == id {
                selection = nil
            }
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 0 failures. New tests (3 detectRepositories + 5 AppModel = 8 new) all pass; existing tests still green. The total should be around 72.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "feat: add detectRepositories, registerLocalClone, remove actions"
```

---

## Task 2: SwiftUI — menu, Manage sheet, sidebar removal

**Files:**
- Modify: `App/DiffToolbarView.swift`
- Modify: `App/DiffPaneView.swift`
- Modify: `App/PRReviewApp.swift`
- Create: `App/ManageLocalClonesView.swift`
- Modify: `App/ContentView.swift`

### Verification model

GUI wiring; no unit tests. Verify by **build succeeds + app launches without crashing** (`pgrep`). Use `open -n` to force a fresh instance. Do NOT attempt GUI interaction — the human runs the E2E.

- [ ] **Step 1: Replace `App/DiffToolbarView.swift`** (strip the "Use local clone…" button; badge-only):

```swift
import SwiftUI
import PRReviewModels
import AppCore

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        HStack {
            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .font(.callout)
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
```

- [ ] **Step 2: Update `App/DiffPaneView.swift`** to conditionally render the toolbar + divider only when a clone is registered.

Find the existing block at the top of `DiffPaneView.body`:

```swift
        VStack(spacing: 0) {
            DiffToolbarView(model: model, review: review)
            Divider()
            Group {
```

Replace it with:

```swift
        VStack(spacing: 0) {
            if model.registeredClonePath(for: review) != nil {
                DiffToolbarView(model: model, review: review)
                Divider()
            }
            Group {
```

Leave the rest of the file unchanged.

- [ ] **Step 3: Create `App/ManageLocalClonesView.swift`:**

```swift
import SwiftUI
import PRReviewModels
import AppCore

struct ManageLocalClonesView: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var showingFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local Clones").font(.headline)
                Spacer()
                Button("Add…") { showingFolderPicker = true }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            if model.registeredRepos.isEmpty {
                Text("No local clones registered. Click Add… to choose a folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                List(model.registeredRepos) { repo in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.remoteIdentity)
                                .font(.callout)
                                .bold()
                            Text(tildeShortened(repo.localClonePath))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.removeRegisteredRepo(remoteIdentity: repo.remoteIdentity) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 220)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 320)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.registerLocalClone(at: url.path) }
        }
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
```

- [ ] **Step 4: Replace `App/PRReviewApp.swift`** — add the menu, state, and sheet:

```swift
import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var showingManage = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
                } else if let startupError {
                    Text(startupError)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ProgressView().frame(minWidth: 900, minHeight: 600)
                }
            }
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    await created.load()
                    model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
        .commands {
            CommandMenu("Repositories") {
                Button("Manage Local Clones…") {
                    showingManage = true
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(model == nil)
            }
        }
    }
}
```

- [ ] **Step 5: Update `App/ContentView.swift`** — add the sidebar `.contextMenu` and `.onDeleteCommand`.

Find the existing sidebar `List` block (it currently looks like):

```swift
            List(model.reviews, selection: $model.selection) { review in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(review.number) · \(review.title)")
                        .lineLimit(1)
                    Text("\(review.owner)/\(review.repo) · \(review.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
```

Replace it with:

```swift
            List(model.reviews, selection: $model.selection) { review in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(review.number) · \(review.title)")
                        .lineLimit(1)
                    Text("\(review.owner)/\(review.repo) · \(review.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await model.removeReview(id: review.id) }
                    } label: {
                        Label("Remove from List", systemImage: "trash")
                    }
                }
            }
            .onDeleteCommand {
                if let id = model.selection {
                    Task { await model.removeReview(id: id) }
                }
            }
```

Leave the rest of `ContentView.swift` unchanged.

- [ ] **Step 6: Generate, build, launch (with `open -n`):**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID.

- [ ] **Step 7: Self-review** — only the four specified `App/*.swift` files modified and one new (`ManageLocalClonesView.swift`); no comments; the menu item is in the menu bar; `⌘⇧L` opens the sheet; the Diff tab's local-clone toolbar appears only when a clone is registered for the selected PR's repo.

- [ ] **Step 8 (manual, NOT yours):** human runs the E2E — opens **Repositories ▸ Manage Local Clones…**, clicks **Add…**, picks the teranode workspace, confirms both `ordishs/teranode` and `bsv-blockchain/teranode` appear in the list; both teranode PRs now show the `📁 local: …` badge; clicking the trash on a row removes it; the Diff toolbar disappears for PRs whose repo isn't registered; right-clicking a PR in the sidebar shows "Remove from List" and removes it (and its worktree dir); pressing `⌫` with a PR selected does the same.

- [ ] **Step 9: Commit**

```bash
git add App
git commit -m "feat: Manage Local Clones menu and sheet, Remove PR action"
```

---

## Self-review (this plan vs. the spec)

- **Spec coverage:**
  - Decision A (auto-detect all GitHub remotes) → Task 1 `detectRepositories` + `registerLocalClone` upserts one entry per identity.
  - Decision B (best-effort worktree cleanup) → Task 1 `removeReview` calls `FileManager.removeItem` inside `try?` before `store.removeReview`.
  - Decision C (menu name + `⌘⇧L`) → Task 2 `.commands { CommandMenu("Repositories") { Button("Manage Local Clones…") { … }.keyboardShortcut("L", modifiers: [.command, .shift]) } }`.
  - Decision D (badge-only toolbar) → Task 2 strip of the button in `DiffToolbarView` + conditional hide in `DiffPaneView`.
  - Three Manage UI requirements (list / Add / Remove) → Task 2 `ManageLocalClonesView`.
  - Two sidebar removal affordances (right-click and `⌫`) → Task 2 `.contextMenu` + `.onDeleteCommand`.
  - Test gaps from spec ("Testing" section) → Task 1 adds the eight named tests.
- **Placeholder scan:** none — full file contents, exact diffs, exact commands.
- **Type consistency:** `CloneRegistering.detectRepositories(at:) async throws -> [String]` matches between protocol, production, and stub. `AppModel.init(store:client:diffLoader:cloneRegistrar:)` is unchanged (no new param) — all prior call sites stay green. `model.registerLocalClone(at:)`, `model.removeRegisteredRepo(remoteIdentity:)`, `model.removeReview(id:)` are referenced identically in tests and views. The sheet binds `isPresented` two ways (parent + child) consistently.

## Definition of done

- `swift test --package-path Core` → 0 failures; the eight new tests are present and green.
- App builds (`** BUILD SUCCEEDED **`) and launches via `open -n`.
- Manual E2E (Step 8 of Task 2) passes: registration via the menu detects both repos in a fork+upstream clone; trash buttons remove single registrations; Diff toolbar appears only when a clone is registered; right-click and `⌫` both remove a PR from the list and clean up its worktree dir.
- Two commits; working tree clean; no `project.yml` / `RegisteredRepo` schema / `AppModel` init-signature changes.
