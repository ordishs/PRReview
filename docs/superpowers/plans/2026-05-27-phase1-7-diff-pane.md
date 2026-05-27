# PR Review — Phase 1, Plan 7: Wire the Diff pane

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Diff tab live — select a PR → its branch is checked out locally → the merge-base diff renders in a native SwiftUI view.

**Architecture:** `AppCore` gains a `DiffLoading` protocol and a production `WorktreeDiffLoader` that composes the existing `WorktreeManager` (resolve clone → lazy worktree → merge-base) and `DiffService` (git diff → `[DiffFile]`). `AppModel` gains a `diffState` and `loadDiff(for:)` that drives it and persists the worktree path. The `App` target renders `diffState` in a native unified-diff view that replaces the Diff placeholder, triggered by `.task(id: review.id)` when the Diff tab is shown.

**Tech Stack:** Swift 6, SwiftUI, the existing `WorktreeKit` / `DiffKit` / `CommandSupport` / `ReviewStore` packages.

**Plan sequence:** …5-diffkit ✅ · **7-diff-pane (this)** · then the Claude terminal pane.

---

## Scope notes

- **Lazy checkout on viewing the Diff tab.** The worktree is created on first diff-load for a review and its path persisted on the `Review`; subsequent loads reuse it.
- **Diff base** = `merge-base(HEAD, origin/<baseBranch>)`, matching GitHub.
- **Credentials caveat:** cloning a **private** repo over https needs git credentials — `gh auth setup-git` configures that. Public PRs clone without setup. A clone/auth failure surfaces as a `.failed` state with the git stderr (not a crash).
- **Deferred:** split view, tree-sitter syntax highlighting, row virtualization for huge diffs, clickable lines / comment posting. This renders a clean unified view.
- `AppCore` gains dependencies on `WorktreeKit` and `DiffKit`; the app target gains the `DiffKit` product (the diff views use `DiffFile`/`DiffLine`).

---

## Task 1: `WorktreeDiffLoader` + `AppModel` diff state (`AppCore`)

**Files:**
- Create: `Core/Sources/AppCore/DiffLoading.swift`
- Create: `Core/Sources/AppCore/WorktreeDiffLoader.swift`
- Modify: `Core/Sources/AppCore/AppModel.swift` (add `diffState`, `loadDiff(for:)`, `diffLoader` init param)
- Modify: `Core/Sources/AppCore/AppModelFactory.swift` (build the loader)
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (pass a stub loader; add diff-state tests)
- Modify: `Core/Package.swift` (`AppCore` deps += `WorktreeKit`, `DiffKit`)

- [ ] **Step 1: Update the failing tests**

In `Core/Tests/AppCoreTests/AppModelTests.swift`, add this stub and helper near the top (after the existing `StubRunner`/`prJSON`/`tempStoreURL` declarations):

```swift
import DiffKit

private struct StubDiffLoader: DiffLoading {
    var files: [DiffFile] = []
    var shouldThrow = false
    func loadDiff(for review: Review) async throws -> DiffResult {
        if shouldThrow {
            throw DiffError.gitFailed(exitCode: 1, message: "stub failure")
        }
        return DiffResult(worktreePath: "/tmp/wt", files: files)
    }
}

private func sampleReview() -> Review {
    Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix", author: "icellan",
        headBranch: "fix/centrifuge", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func stubClient() -> GitHubClient {
    GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
}
```

Then update the FOUR existing `AppModel(store:client:)` constructions in this file to pass a stub loader — change each `AppModel(store: store, client: client)` to:

```swift
AppModel(store: store, client: client, diffLoader: StubDiffLoader())
```

Then add these two new tests:

```swift
@Test @MainActor func loadDiffSetsLoadedState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let file = DiffFile(oldPath: "foo.txt", newPath: "foo.txt", changeKind: .modified, hunks: [], addedCount: 1, removedCount: 0)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: [file]))

    await model.loadDiff(for: sampleReview())

    #expect(model.diffState == .loaded([file]))
}

@Test @MainActor func loadDiffSetsFailedStateOnError() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(shouldThrow: true))

    await model.loadDiff(for: sampleReview())

    if case .failed = model.diffState {
    } else {
        Issue.record("expected .failed, got \(model.diffState)")
    }
}

@Test @MainActor func loadDiffPersistsWorktreePath() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: []))
    await model.load()

    await model.loadDiff(for: review)

    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allReviews().first?.worktreePath == "/tmp/wt")
}
```

- [ ] **Step 2: Update the manifest** — replace the `AppCore` target line and add nothing else changed:

In `Core/Package.swift`, change the `AppCore` target dependencies to:

```swift
        .target(name: "AppCore", dependencies: ["PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "WorktreeKit", "DiffKit"]),
```

And change the `AppCoreTests` test target dependencies to:

```swift
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "DiffKit"]),
```

(Leave every other target line unchanged.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'DiffLoading'` / `cannot find 'DiffResult'` / `AppModel` has no `diffState` or `diffLoader:` initializer.

- [ ] **Step 4: Create the loader protocol + state**

Create `Core/Sources/AppCore/DiffLoading.swift`:

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
    func loadDiff(for review: Review) async throws -> DiffResult
}
```

- [ ] **Step 5: Create the production loader**

Create `Core/Sources/AppCore/WorktreeDiffLoader.swift`:

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

    public func loadDiff(for review: Review) async throws -> DiffResult {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: nil
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

- [ ] **Step 6: Extend `AppModel`**

In `Core/Sources/AppCore/AppModel.swift`, add the stored property and init parameter, and the method. The class becomes (showing the full file):

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

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading

    public init(store: ReviewStore, client: GitHubClient, diffLoader: DiffLoading) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
    }

    public func load() async {
        reviews = await store.allReviews()
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

    public func loadDiff(for review: Review) async {
        diffState = .loading
        do {
            let result = try await diffLoader.loadDiff(for: review)
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

- [ ] **Step 7: Update the factory**

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

        return AppModel(store: store, client: client, diffLoader: diffLoader)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 49 tests total (46 prior + 3 new `AppModel` diff tests), 0 failures.

- [ ] **Step 9: Commit**

```bash
git add Core
git commit -m "feat: add WorktreeDiffLoader and AppModel diff state"
```

---

## Task 2: Native SwiftUI diff view (`App`)

**Files:**
- Modify: `project.yml` (app depends on `DiffKit` product too)
- Create: `App/DiffPaneView.swift`
- Modify: `App/DetailView.swift` (take `model`, render `DiffPaneView` for the Diff tab)
- Modify: `App/ContentView.swift` (pass `model` to `DetailView`)

- [ ] **Step 1: Add the `DiffKit` product to the app**

In `project.yml`, the `PRReview` target `dependencies` list becomes exactly:

```yaml
    dependencies:
      - package: PRReviewCore
        product: PRReviewModels
      - package: PRReviewCore
        product: AppCore
      - package: PRReviewCore
        product: DiffKit
```

(Everything else in `project.yml` unchanged.)

- [ ] **Step 2: Create the diff view**

Create `App/DiffPaneView.swift`:

```swift
import SwiftUI
import PRReviewModels
import DiffKit
import AppCore

struct DiffPaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
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

- [ ] **Step 3: Wire `DetailView` to use it**

Replace the ENTIRE contents of `App/DetailView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import AppCore

struct DetailView: View {
    let model: AppModel
    let review: Review
    @State private var pane: Pane = .github

    enum Pane: String, CaseIterable, Identifiable {
        case claude = "Claude Review"
        case github = "GitHub"
        case diff = "Diff"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch pane {
            case .github:
                WebPane(url: review.url)
            case .diff:
                DiffPaneView(model: model, review: review)
            case .claude:
                placeholder(title: "Claude review", subtitle: "The embedded terminal lands with the Claude pane.")
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Pass `model` from `ContentView`**

In `App/ContentView.swift`, change the detail-column line `DetailView(review: review)` to:

```swift
                DetailView(model: model, review: review)
```

(No other change to `ContentView.swift`.)

- [ ] **Step 5: Generate, build, launch (with `open -n`)**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID. (`open -n` forces a new instance so you see the rebuilt binary, not a stale one.) Do NOT attempt GUI interaction — the human does the E2E.

- [ ] **Step 6 (manual, the human):** add/select a PR (a public one, e.g. `https://github.com/cli/cli/pull/1`), switch to the **Diff** tab → after a short checkout, the native unified diff renders (file headers with +/− counts, line numbers, green/red lines). A private repo without `gh auth setup-git` will show a `.failed` state with the git error instead.

- [ ] **Step 7: Commit**

```bash
git add project.yml App
git commit -m "feat: render native unified diff in the Diff pane"
```

---

## Self-review

- **Coverage:** the Diff tab now performs lazy worktree checkout (`WorktreeManager`) and renders the merge-base diff (`DiffService`) natively. `AppModel.loadDiff` drives `idle/loading/loaded/failed` and persists the worktree path. Failure (e.g. clone auth) is surfaced, not crashed.
- **Placeholder scan:** none — full files/edits and commands given. `AppModel` diff logic is unit-tested via a `StubDiffLoader` (loaded/failed/persist); the SwiftUI diff rendering is verified by the manual E2E.
- **Type consistency:** `DiffLoading.loadDiff(for:) -> DiffResult`; `WorktreeDiffLoader` uses `WorktreeManager.resolveClone/createWorktree/mergeBase` and `DiffService.diff` with their real signatures; `AppModel.init(store:client:diffLoader:)` (all call sites updated); views read `model.diffState` and `DiffFile`/`DiffHunk`/`DiffLine` fields; `DetailView(model:review:)`. `project.yml` adds the `DiffKit` product the diff views import.

## Definition of done

- `swift test --package-path Core` → 49 tests passing, 0 failures.
- App builds; selecting a (public) PR and opening the Diff tab checks out the worktree and renders a native unified diff; the worktree path persists on the review.
- Two commits; working tree clean.
- Known follow-ups: the Claude terminal pane; private-repo clone UX (`gh auth setup-git` / registered clones); split view, syntax highlighting, virtualization, clickable lines.
