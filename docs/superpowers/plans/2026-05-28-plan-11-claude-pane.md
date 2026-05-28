# PR Review — Phase 1, Plan 11: Claude Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder in `DetailView.swift` for the **Claude Review** tab with a SwiftTerm-backed embedded terminal running `claude --continue` in the PR's worktree. One session per review, kept alive across tab/PR switches, killed on review removal and app quit.

**Architecture:** Grow `ClaudeSessionKit` from an empty namespace into a real module that owns a `ClaudeSession` (per-review `@Observable` class holding a SwiftTerm `LocalProcessTerminalView` and exposing a state machine). Extract a shared `WorktreeProvider` so the Claude pane and the Diff pane resolve the worktree through the same lazy path. `AppModel` gains a session registry keyed by review id; `ClaudePaneView` is an `NSViewRepresentable` that reparents the persistent `TerminalView` instance across SwiftUI rebuilds. App quit walks the registry and SIGTERMs each session.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSViewRepresentable`), SwiftTerm (new SPM dep, pinned `from: "1.2.0"`), the existing `WorktreeKit` / `DiffKit` / `AppCore` / `ReviewStore` packages.

**Master design spec:** `docs/superpowers/specs/2026-05-28-claude-pane-design.md`
**Plan sequence:** …8-registered-clone ✅ · 10-management-ux ✅ · **11-claude-pane (this)** · then Plan 12 (transcript-tailing status badges).

---

## Scope notes

- One session per review, kept alive across tab and PR switches. App quit SIGTERMs each. `Review.claudeFlags` honored.
- Rehydration: `claude --continue` is always passed (last arg). Claude Code starts a fresh session if none exists for that cwd.
- View keep-alive: `ClaudeSession` strongly holds one `LocalProcessTerminalView`. `NSViewRepresentable` reparents it; SwiftUI tab switches don't destroy the terminal buffer or restart the PTY.
- cwd is set by wrapping the spawn in `/bin/sh -c "cd <worktree> && exec <claude> <args>"`. The `exec` replaces the shell with `claude` so signal propagation and process-group semantics are correct.
- **Deferred (out of scope):** transcript tailing → sidebar status badges (Plan 12); Settings UI for `claudeLaunchArgs`/`claudePath`; force-push / worktree-vanished detection while a session is live; suspend-on-pane-switch policy for live PTYs; unit tests for `ClaudeSessionKit` (launch-arg builder + state machine).

---

## Task 1: ClaudeSessionKit module + SwiftTerm dependency (`Core`)

**Files:**
- Modify: `Core/Package.swift`
- Delete: `Core/Sources/ClaudeSessionKit/ClaudeSessionKit.swift` (the empty `public enum ClaudeSessionKit {}` namespace)
- Create: `Core/Sources/ClaudeSessionKit/ClaudeSessionState.swift`
- Create: `Core/Sources/ClaudeSessionKit/ClaudeLaunchBuilder.swift`
- Create: `Core/Sources/ClaudeSessionKit/ClaudeSession.swift`

- [ ] **Step 1: Update `Core/Package.swift`**

Replace the ENTIRE contents of `Core/Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRReviewModels", targets: ["PRReviewModels"]),
        .library(name: "CommandSupport", targets: ["CommandSupport"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "ClaudeSessionKit", targets: ["ClaudeSessionKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["CommandSupport"]),
        .target(
            name: "ClaudeSessionKit",
            dependencies: [
                "PRReviewModels",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "AppCore",
            dependencies: ["PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "WorktreeKit", "DiffKit", "ClaudeSessionKit"]
        ),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "DiffKit", "ClaudeSessionKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit", "CommandSupport"]),
    ]
)
```

(Differences from the current file: added the `dependencies` block with SwiftTerm; added `SwiftTerm` product to `ClaudeSessionKit`; added `ClaudeSessionKit` to `AppCore` deps and to `AppCoreTests` deps. Every other line is unchanged.)

- [ ] **Step 2: Delete the empty namespace file**

Run: `rm Core/Sources/ClaudeSessionKit/ClaudeSessionKit.swift`

(The file currently contains only `public enum ClaudeSessionKit {}` and is being replaced by the three real source files below.)

- [ ] **Step 3: Create `ClaudeSessionState.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeSessionState.swift`:

```swift
import Foundation

public enum ClaudeSessionState: Sendable, Equatable {
    case starting
    case running
    case exited(code: Int32)
    case failedToLaunch(String)
}
```

- [ ] **Step 4: Create `ClaudeLaunchBuilder.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeLaunchBuilder.swift`:

```swift
import Foundation
import PRReviewModels

public struct ClaudeLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]

    public init(executable: String, cwd: String, arguments: [String]) {
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
    }
}

public enum ClaudeLaunchBuilder {
    public static func build(
        settings: Settings,
        review: Review,
        worktreePath: String,
        resolvedClaudePath: String
    ) -> ClaudeLaunchSpec {
        let args = settings.claudeLaunchArgs
            + (review.claudeFlags ?? [])
            + ["--continue"]
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args
        )
    }
}
```

- [ ] **Step 5: Create `ClaudeSession.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeSession.swift`:

```swift
import AppKit
import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
public final class ClaudeSession {
    public private(set) var state: ClaudeSessionState = .starting
    public let spec: ClaudeLaunchSpec
    public let terminalView: LocalProcessTerminalView

    private let delegateBridge: DelegateBridge

    public init(spec: ClaudeLaunchSpec) {
        self.spec = spec
        let view = LocalProcessTerminalView(frame: .zero)
        self.terminalView = view
        let bridge = DelegateBridge()
        self.delegateBridge = bridge
        view.processDelegate = bridge
        bridge.onExit = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.state = .exited(code: code)
            }
        }
    }

    public func start() {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            state = .failedToLaunch("claude not found at \(spec.executable)")
            return
        }
        state = .starting
        let shellCommand = makeShellCommand()
        terminalView.startProcess(
            executable: "/bin/sh",
            args: ["-c", shellCommand],
            environment: nil,
            execName: nil
        )
        state = .running
    }

    public func restart() {
        terminate()
        start()
    }

    public func terminate() {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let process = terminalView.process
        Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.running {
                kill(pid, SIGKILL)
            }
        }
    }

    private func makeShellCommand() -> String {
        let escapedCwd = shellEscape(spec.cwd)
        let escapedExec = shellEscape(spec.executable)
        let escapedArgs = spec.arguments.map(shellEscape).joined(separator: " ")
        let argsSuffix = escapedArgs.isEmpty ? "" : " " + escapedArgs
        return "cd \(escapedCwd) && exec \(escapedExec)\(argsSuffix)"
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
private final class DelegateBridge: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: ((Int32) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(exitCode ?? -1)
    }
}
```

(Notes for the implementer:
1. SwiftTerm's `LocalProcessTerminalView` exposes both `startProcess(executable:args:environment:execName:)` and a `.process` property of type `LocalProcess` with `shellPid: pid_t` and `running: Bool`. These have been stable since SwiftTerm 1.0.
2. We wrap the spawn in `/bin/sh -c` because some SwiftTerm releases don't expose a `currentDirectory` parameter on `startProcess`. The `exec` keyword replaces the shell with `claude`, so signals are delivered to claude itself, not a wrapping shell.
3. `kill(pid, SIGTERM)` uses `Foundation`/`Darwin`'s POSIX `kill` — already imported via `AppKit`/`Foundation`.)

- [ ] **Step 6: Verify the package compiles**

Run: `swift build --package-path Core 2>&1 | tail -20`
Expected: `Build complete!` (SwiftPM will resolve and download SwiftTerm on first run; allow ~30s extra). No errors.

If SwiftTerm's `LocalProcessTerminalViewDelegate` protocol has different required methods in the resolved version (the protocol has historically been stable but minor versions occasionally add optional methods), the build error will name them. Add no-op implementations to `DelegateBridge` to satisfy them.

- [ ] **Step 7: Commit**

```bash
git add Core/Package.swift Core/Sources/ClaudeSessionKit
git commit -m "feat: scaffold ClaudeSessionKit with SwiftTerm-backed session"
```

---

## Task 2: Extract `WorktreeProvider` (TDD) (`AppCore`)

**Files:**
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (add `StubWorktreeProvider`, thread it through all existing `AppModel(...)` construction sites)
- Create: `Core/Sources/AppCore/WorktreeProviding.swift`
- Modify: `Core/Sources/AppCore/WorktreeDiffLoader.swift` (compose `WorktreeProviding` instead of doing resolution inline)
- Modify: `Core/Sources/AppCore/AppModel.swift` (add `worktreeProvider` init param — passed through but not yet consumed in this task)
- Modify: `Core/Sources/AppCore/AppModelFactory.swift` (build one shared `WorktreeProvider`)

- [ ] **Step 1: Update the test stubs first (will fail to compile)**

In `Core/Tests/AppCoreTests/AppModelTests.swift`:

Add this new stub after the `RecordingDiffLoader` declaration (around line 68):

```swift
private struct StubWorktreeProvider: WorktreeProviding {
    var result: WorktreeReady = WorktreeReady(clonePath: "/tmp/clone", worktreePath: "/tmp/wt", remoteName: "origin")
    var shouldThrow = false
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady {
        if shouldThrow {
            throw WorktreeProviderError.failed("stub failure")
        }
        return result
    }
}
```

Then update EVERY `AppModel(store: ..., client: ..., diffLoader: ..., cloneRegistrar: ...)` construction in the file (there are 16 of them — verify with `grep -c "AppModel(" Core/Tests/AppCoreTests/AppModelTests.swift`) by inserting `worktreeProvider: StubWorktreeProvider()` between `diffLoader:` and `cloneRegistrar:`. Each call becomes:

```swift
AppModel(store: store, client: <client>, diffLoader: <diffLoader>, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: <registrar>)
```

The 16 call sites are in these tests (search for `AppModel(`):
`addPRFetchesStoresAndSelects`, `addPRSetsErrorOnInvalidURL`, `addPRSurfacesCommandFailureAndDismisses`, `loadReadsExistingReviews`, `loadDiffSetsLoadedState`, `loadDiffSetsFailedStateOnError`, `loadDiffPersistsWorktreePath`, `registerCloneSucceedsAndPersists`, `registerCloneSetsErrorOnValidationFailure`, `loadDiffPassesRegisteredClonePathToLoader`, `loadDiffPassesNilWhenNoRegisteredClone`, `registerLocalCloneRegistersAllDetected`, `registerLocalCloneSetsErrorWhenNoReposFound`, `removeRegisteredRepoDeletes`, `removeReviewRemovesFromStoreAndClearsSelection`, `removeReviewBestEffortRemovesWorktreeDir`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `cannot find 'WorktreeProviding'`, `cannot find 'WorktreeReady'`, `cannot find 'WorktreeProviderError'`, and `extra argument 'worktreeProvider' in call`.

- [ ] **Step 3: Create the protocol + concrete `WorktreeProvider`**

Create `Core/Sources/AppCore/WorktreeProviding.swift`:

```swift
import Foundation
import PRReviewModels
import WorktreeKit

public struct WorktreeReady: Sendable, Equatable {
    public let clonePath: String
    public let worktreePath: String
    public let remoteName: String

    public init(clonePath: String, worktreePath: String, remoteName: String) {
        self.clonePath = clonePath
        self.worktreePath = worktreePath
        self.remoteName = remoteName
    }
}

public enum WorktreeProviderError: Error, Sendable, Equatable {
    case failed(String)
}

public protocol WorktreeProviding: Sendable {
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady
}

public struct WorktreeProvider: WorktreeProviding {
    private let worktreeManager: WorktreeManager

    public init(worktreeManager: WorktreeManager) {
        self.worktreeManager = worktreeManager
    }

    public func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: registeredClonePath
        )
        let remoteName: String
        if registeredClonePath != nil {
            let remotes = try await worktreeManager.listRemotes(clonePath: clonePath)
            let target = "\(review.owner)/\(review.repo)".lowercased()
            remoteName = remotes.first { entry in
                guard let (owner, repo) = GitOriginParser.parse(entry.url) else { return false }
                return "\(owner)/\(repo)".lowercased() == target
            }?.name ?? "origin"
        } else {
            remoteName = "origin"
        }
        let worktreePath: String
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            worktreePath = existing
        } else {
            worktreePath = try await worktreeManager.createWorktree(
                clonePath: clonePath,
                owner: review.owner,
                repo: review.repo,
                number: review.number,
                remoteName: remoteName
            )
        }
        return WorktreeReady(clonePath: clonePath, worktreePath: worktreePath, remoteName: remoteName)
    }
}
```

- [ ] **Step 4: Refactor `WorktreeDiffLoader.swift`**

Replace the ENTIRE contents of `Core/Sources/AppCore/WorktreeDiffLoader.swift` with:

```swift
import Foundation
import PRReviewModels
import WorktreeKit
import DiffKit

public struct WorktreeDiffLoader: DiffLoading {
    private let worktreeProvider: WorktreeProviding
    private let worktreeManager: WorktreeManager
    private let diffService: DiffService

    public init(worktreeProvider: WorktreeProviding, worktreeManager: WorktreeManager, diffService: DiffService) {
        self.worktreeProvider = worktreeProvider
        self.worktreeManager = worktreeManager
        self.diffService = diffService
    }

    public func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        let ready = try await worktreeProvider.ensureWorktree(for: review, registeredClonePath: registeredClonePath)
        try await worktreeManager.fetch(clonePath: ready.clonePath, remoteName: ready.remoteName, ref: review.baseBranch)
        let base = try await worktreeManager.mergeBase(worktreePath: ready.worktreePath, baseRef: "\(ready.remoteName)/\(review.baseBranch)")
        let files = try await diffService.diff(worktreePath: ready.worktreePath, baseRef: base)
        return DiffResult(worktreePath: ready.worktreePath, files: files)
    }
}
```

- [ ] **Step 5: Update `AppModel.swift` init signature**

In `Core/Sources/AppCore/AppModel.swift`:

Add a private stored property and an init parameter (do NOT consume it yet — that's Task 3):

After the `private let cloneRegistrar: CloneRegistering` line, add:

```swift
    private let worktreeProvider: WorktreeProviding
```

Change the `public init(...)` signature from:

```swift
    public init(store: ReviewStore, client: GitHubClient, diffLoader: DiffLoading, cloneRegistrar: CloneRegistering) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.cloneRegistrar = cloneRegistrar
    }
```

to:

```swift
    public init(store: ReviewStore, client: GitHubClient, diffLoader: DiffLoading, worktreeProvider: WorktreeProviding, cloneRegistrar: CloneRegistering) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
    }
```

(No other change to `AppModel.swift` in this task.)

- [ ] **Step 6: Update `AppModelFactory.swift`**

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
        let worktreeProvider = WorktreeProvider(worktreeManager: worktreeManager)
        let diffService = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
        let diffLoader = WorktreeDiffLoader(worktreeProvider: worktreeProvider, worktreeManager: worktreeManager, diffService: diffService)
        let cloneRegistrar = GitCloneRegistrar(runner: ProcessCommandRunner(), gitPath: gitPath)

        return AppModel(store: store, client: client, diffLoader: diffLoader, worktreeProvider: worktreeProvider, cloneRegistrar: cloneRegistrar)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 72 tests, 0 failures. No test counts changed in this task; we only refactored.

- [ ] **Step 8: Commit**

```bash
git add Core
git commit -m "refactor: extract WorktreeProvider shared by diff and claude paths"
```

---

## Task 3: AppModel claude-session registry (TDD) (`AppCore`)

**Files:**
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (one new test + thread `claudePath:` through all 16 existing `AppModel(...)` calls)
- Modify: `Core/Sources/AppCore/AppModel.swift` (add `ClaudePaneState` enum, `claudeSessions` dict, `claudePaneState` dict, `claudePath` param, `ensureClaudeSession`, `terminateClaudeSession`, `terminateAllClaudeSessions`; modify `removeReview` to call `terminateClaudeSession`)
- Modify: `Core/Sources/AppCore/AppModelFactory.swift` (resolve `claudePath` and pass to `AppModel.init`)

- [ ] **Step 1: Add the failing test + thread `claudePath:` through existing calls**

In `Core/Tests/AppCoreTests/AppModelTests.swift`:

Add this import at the top, in the import block (after `@testable import AppCore`):

```swift
import ClaudeSessionKit
```

Add this new test at the end of the file (after `removeReviewBestEffortRemovesWorktreeDir`):

```swift
@Test @MainActor func ensureClaudeSessionFlagsWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true"
    )
    let review = sampleReview()

    await model.ensureClaudeSession(for: review)

    let state = model.claudePaneState[review.id]
    if case .worktreeFailed(let message) = state {
        #expect(message.contains("stub failure"))
    } else {
        Issue.record("expected .worktreeFailed, got \(String(describing: state))")
    }
    #expect(model.claudeSessions[review.id] == nil)
}
```

Then update EVERY existing `AppModel(...)` call site in the file (the 16 from Task 2 — now they have `worktreeProvider:`) by adding `claudePath: "/usr/bin/true"` as the last argument. Each existing call becomes:

```swift
AppModel(store: <store>, client: <client>, diffLoader: <diffLoader>, worktreeProvider: <wp>, cloneRegistrar: <registrar>, claudePath: "/usr/bin/true")
```

(`/usr/bin/true` is a real executable on macOS, so `FileManager.isExecutableFile` returns true — useful for any future test that exercises the success path without actually spawning claude.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `cannot find 'ClaudePaneState'`, `extra argument 'claudePath' in call`, and the new test references `model.claudePaneState` / `model.claudeSessions` which don't exist.

- [ ] **Step 3: Extend `AppModel.swift`**

Replace the ENTIRE contents of `Core/Sources/AppCore/AppModel.swift` with:

```swift
import Foundation
import Observation
import PRReviewModels
import ReviewStore
import GitHubKit
import ClaudeSessionKit

public enum ClaudePaneState: Sendable, Equatable {
    case idle
    case preparingWorktree
    case worktreeFailed(String)
    case sessionLive
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var reviews: [Review] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var diffState: DiffLoadState = .idle
    public private(set) var registeredRepos: [RegisteredRepo] = []
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let worktreeProvider: WorktreeProviding
    private let cloneRegistrar: CloneRegistering
    private let claudePath: String

    public init(
        store: ReviewStore,
        client: GitHubClient,
        diffLoader: DiffLoading,
        worktreeProvider: WorktreeProviding,
        cloneRegistrar: CloneRegistering,
        claudePath: String
    ) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
        self.claudePath = claudePath
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
        terminateClaudeSession(for: id)
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

    public func ensureClaudeSession(for review: Review) async {
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        claudePaneState[review.id] = .preparingWorktree
        do {
            let ready = try await worktreeProvider.ensureWorktree(
                for: review,
                registeredClonePath: registeredClonePath(for: review)
            )
            if review.worktreePath != ready.worktreePath {
                var updated = review
                updated.worktreePath = ready.worktreePath
                try await store.upsert(updated)
                reviews = await store.allReviews()
            }
            let spec = ClaudeLaunchBuilder.build(
                settings: .default,
                review: review,
                worktreePath: ready.worktreePath,
                resolvedClaudePath: claudePath
            )
            let session = ClaudeSession(spec: spec)
            claudeSessions[review.id] = session
            claudePaneState[review.id] = .sessionLive
            session.start()
        } catch {
            claudePaneState[review.id] = .worktreeFailed(String(describing: error))
        }
    }

    public func terminateClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePaneState.removeValue(forKey: id)
    }

    public func terminateAllClaudeSessions() {
        for session in claudeSessions.values { session.terminate() }
        claudeSessions.removeAll()
        claudePaneState.removeAll()
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

(Differences from current `AppModel.swift`: added `ClaudePaneState` enum at module scope; added `claudeSessions` and `claudePaneState` stored properties; added `worktreeProvider` and `claudePath` private stored properties; new `init(...)` signature with `worktreeProvider:` and `claudePath:`; added `ensureClaudeSession`, `terminateClaudeSession`, `terminateAllClaudeSessions`; `removeReview` now calls `terminateClaudeSession(for: id)` first. All other methods unchanged.)

- [ ] **Step 4: Update `AppModelFactory.swift`**

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
        let claudePath = settings.claudePath ?? ToolResolver.resolve("claude") ?? "/opt/homebrew/bin/claude"

        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        let worktreeManager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: settings.managedRoot)
        let worktreeProvider = WorktreeProvider(worktreeManager: worktreeManager)
        let diffService = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
        let diffLoader = WorktreeDiffLoader(worktreeProvider: worktreeProvider, worktreeManager: worktreeManager, diffService: diffService)
        let cloneRegistrar = GitCloneRegistrar(runner: ProcessCommandRunner(), gitPath: gitPath)

        return AppModel(
            store: store,
            client: client,
            diffLoader: diffLoader,
            worktreeProvider: worktreeProvider,
            cloneRegistrar: cloneRegistrar,
            claudePath: claudePath
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 73 tests (72 prior + 1 new `ensureClaudeSessionFlagsWorktreeFailure`), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "feat: add ensureClaudeSession registry on AppModel"
```

---

## Task 4: SwiftUI Claude pane + DetailView wiring + app-quit cleanup (`App`)

**Files:**
- Modify: `project.yml` (add `ClaudeSessionKit` product to the app)
- Create: `App/ClaudePaneView.swift`
- Modify: `App/DetailView.swift` (replace the `.claude` placeholder with `ClaudePaneView`)
- Create: `App/AppDelegate.swift`
- Modify: `App/PRReviewApp.swift` (install the `NSApplicationDelegateAdaptor`, expose the model to it)

- [ ] **Step 1: Update `project.yml`**

In `project.yml`, change the `PRReview` target `dependencies` list to exactly:

```yaml
    dependencies:
      - package: PRReviewCore
        product: PRReviewModels
      - package: PRReviewCore
        product: AppCore
      - package: PRReviewCore
        product: DiffKit
      - package: PRReviewCore
        product: ClaudeSessionKit
```

(Everything else in `project.yml` is unchanged.)

- [ ] **Step 2: Create the Claude pane view**

Create `App/ClaudePaneView.swift`:

```swift
import SwiftUI
import AppKit
import PRReviewModels
import AppCore
import ClaudeSessionKit
import SwiftTerm

struct ClaudePaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        Group {
            switch model.claudePaneState[review.id] ?? .idle {
            case .idle, .preparingWorktree:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing worktree…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .worktreeFailed(let message):
                worktreeFailureView(message: message)
            case .sessionLive:
                if let session = model.claudeSessions[review.id] {
                    ZStack(alignment: .top) {
                        TerminalHost(session: session)
                        exitOverlay(for: session)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: review.id) {
            await model.ensureClaudeSession(for: review)
        }
    }

    @ViewBuilder
    private func worktreeFailureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't prepare the worktree")
                .font(.headline)
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Retry") {
                Task { await model.ensureClaudeSession(for: review) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func exitOverlay(for session: ClaudeSession) -> some View {
        switch session.state {
        case .exited(let code):
            ExitBanner(
                title: "claude exited",
                subtitle: "code \(code)",
                isError: false,
                onRestart: { session.restart() }
            )
        case .failedToLaunch(let message):
            ExitBanner(
                title: message.contains("not found") ? "claude not found" : "claude failed to launch",
                subtitle: message,
                isError: true,
                onRestart: { session.restart() }
            )
        case .starting, .running:
            EmptyView()
        }
    }
}

private struct ExitBanner: View {
    let title: String
    let subtitle: String
    let isError: Bool
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button("Restart", action: onRestart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isError ? Color.red.opacity(0.6) : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: ClaudeSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

- [ ] **Step 3: Wire `DetailView.swift` to use it**

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
                ClaudePaneView(model: model, review: review)
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }
}
```

(Differences from current: removed the `placeholder` helper method; `.claude` case now uses `ClaudePaneView`.)

- [ ] **Step 4: Create the app delegate**

Create `App/AppDelegate.swift`:

```swift
import AppKit
import AppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateAllClaudeSessions()
    }
}
```

- [ ] **Step 5: Update `PRReviewApp.swift`**

Replace the ENTIRE contents of `App/PRReviewApp.swift` with:

```swift
import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                    appDelegate.model = created
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

(Differences from current: added `@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate`; added `appDelegate.model = created` inside the `.task` block right after `model = created`. Nothing else changed.)

- [ ] **Step 6: Generate the Xcode project + build + launch**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID. SwiftTerm is resolved transitively into the app via the `ClaudeSessionKit` package product. Do NOT attempt GUI interaction — the human runs the E2E checklist below.

- [ ] **Step 7 (manual, the human runs this — do NOT mark complete without explicit confirmation):**

Run through this E2E checklist and report PASS/FAIL for each step:

1. Select a PR whose worktree already exists (from earlier diff testing). Click **Claude Review**. Verify: terminal renders, prompt appears, `claude` is running in the worktree (visible via `ps -ef | grep claude` showing the process under `/bin/sh -c "cd /your/worktree && exec /path/to/claude --continue"`).
2. Tab to **Diff**, then back to **Claude Review**. Verify: same terminal, scrollback intact, no respawn (`ps` shows the same PID).
3. Type `/exit` inside `claude`. Verify: "claude exited · code 0" banner appears at the top of the pane; clicking Restart spawns a new session in the same `TerminalView` (scrollback from the previous run is still visible above the new prompt).
4. Pick a different PR in the sidebar, then back. Verify: each PR keeps its own session running independently; tab switch is instant.
5. Quit the app via Cmd-Q. After 1–2 seconds, run `pgrep -fl claude`. Verify: no `claude` (or `/bin/sh` claude-wrapper) processes remain from this app.
6. Temporarily make claude unreachable: `Settings.default.claudePath` is currently nil and `ToolResolver.resolve("claude")` walks PATH — easiest way to simulate "not found" is to launch the app with a clobbered PATH, e.g. `env PATH=/usr/bin open -n DerivedData/Build/Products/Debug/PRReview.app`. Open the Claude tab for any PR. Verify: "claude not found" banner appears with the resolved (and missing) path quoted; Restart is shown but will keep failing until PATH is fixed. Quit and relaunch normally.
7. Open one of the PRs from step 1 again (with normal PATH). Verify: terminal launches with `claude --continue` and prior context is rehydrated — visible as either a "Continuing previous session" line from claude itself, or the previous prompt being summarised at the top of the new session.

- [ ] **Step 8: Commit**

```bash
git add project.yml App
git commit -m "feat: wire SwiftTerm-backed claude pane into DetailView"
```

---

## Self-review

- **Spec coverage:**
  - Key decision #1 (always `--continue`) → Task 1 Step 4 (`ClaudeLaunchBuilder.build` appends `["--continue"]` last).
  - #2 (SwiftTerm in `ClaudeSessionKit`, owns `TerminalView`) → Task 1 Steps 1, 5.
  - #3 (extract `WorktreeProvider`) → Task 2.
  - #4 (exit overlay + Restart) → Task 4 Step 2 (`exitOverlay`/`ExitBanner`).
  - #5 (session lifecycle, kill on removeReview + quit) → Task 3 Step 3 (`removeReview` calls `terminateClaudeSession`; `terminateAllClaudeSessions`); Task 4 Steps 4–5 (`AppDelegate.applicationWillTerminate`).
  - #6 (view keep-alive via reparenting) → Task 4 Step 2 (`TerminalHost` reparents `session.terminalView`).
  - #7 (per-review `claudeFlags` honored) → Task 1 Step 4 (builder appends `review.claudeFlags`).
  - "claude not found" banner → Task 1 Step 5 (pre-spawn `FileManager.isExecutableFile` check sets `.failedToLaunch("claude not found at …")`); Task 4 Step 2 (banner branches on `message.contains("not found")`).
- **Placeholder scan:** none — every step has full file contents or full call-site edits. No "TBD" / "fill in" / "similar to" / "add appropriate error handling".
- **Type consistency:**
  - `ClaudeSessionState` enum cases (`starting`/`running`/`exited(code:)`/`failedToLaunch(_:)`) are referenced consistently from `ClaudeSession`, the exit-overlay switch, and the spec.
  - `WorktreeProviding.ensureWorktree(for:registeredClonePath:) async throws -> WorktreeReady` is the signature in the protocol, the concrete `WorktreeProvider`, the test stub, and the loader callsites.
  - `AppModel.init(store:client:diffLoader:worktreeProvider:cloneRegistrar:claudePath:)` is the signature used by every test call site (16 + 1 new), the factory, and the model definition.
  - `ClaudePaneState` cases (`idle`/`preparingWorktree`/`worktreeFailed(_:)`/`sessionLive`) match between the enum definition, the view switch, and the test assertion.
  - `LocalProcessTerminalView` API used: `init(frame:)`, `processDelegate`, `startProcess(executable:args:environment:execName:)`, `process.shellPid`, `process.running` — all stable since SwiftTerm 1.0.
- **Scope:** four tasks, one commit each, each a self-contained unit. Tests deferred for `ClaudeSessionKit` per the spec (manual E2E covers the spawn paths).

## Definition of done

- `swift test --package-path Core` → 73 tests, 0 failures.
- App builds; selecting a PR and clicking **Claude Review** prepares the worktree, spawns `claude --continue` in it, and renders the SwiftTerm terminal. Tab and PR switches don't restart the session. `/exit` shows the Restart banner; Restart respawns. Cmd-Q leaves no orphan `claude` processes.
- Four commits; working tree clean.
- Known follow-ups (out of scope): transcript tailing → status badges (Plan 12); Settings UI; force-push / worktree-vanished while session is live; suspend-on-pane-switch lifecycle policy.
