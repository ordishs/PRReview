# PR Review — Phase 1, Plan 4: WorktreeKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a PR into local code — resolve a source clone (hybrid: registered checkout or auto-cloned managed copy), create a detached worktree at the PR head, compute the diff base, and clean up.

**Architecture:** First extract the `CommandRunner` abstraction out of `GitHubKit` into a shared `CommandSupport` module (so both `GitHubKit` and `WorktreeKit` can use it without depending on each other). Then add `WorktreeManager` to `WorktreeKit`, driving `git` through `CommandSupport`. Git plumbing is verified by **real-git integration tests** that build a throwaway bare "remote" (with a synthetic `refs/pull/N/head`) in a temp dir — fully offline and deterministic.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, real `git` via `CommandSupport`.

**Companion spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md` (see "WorktreeKit").

**Plan sequence (Phase 1):** 1-scaffold ✅ · 2-reviewstore ✅ · 3-githubkit ✅ · **4-worktreekit (this)** · 5-diffkit · 6-app-integration.

---

## Scope notes

- **Hybrid clone resolution, worktree create/remove, merge-base only.** Branch-advance refresh, dirty-worktree guarding, and transactional temp-build are spec features deferred to a later hardening pass; this plan delivers the core happy path with clean error propagation.
- **`WorktreeManager` is decoupled from `ReviewStore`.** Callers pass the registered clone path (if any) as a parameter; the manager does not read the store. The app wires them together in Plan 6.
- **No `project.yml` / app changes.** Consumed by the app in Plan 6.
- **Tests use real `git`** against local temp repos (no network). `gitPath` in tests is `/opt/homebrew/bin/git` (confirmed present on this machine); the app resolves git from `Settings`/`PATH` later.

---

## Task 1: Extract `CommandSupport` module

The `CommandRunner` abstraction currently lives in `GitHubKit`. `WorktreeKit` needs it too, but must not depend on `GitHubKit`. Move it to a new dependency-free `CommandSupport` module. This is a behavior-preserving refactor — the existing 25 tests must stay green (no new tests).

**Files:**
- Move: `Core/Sources/GitHubKit/CommandRunner.swift` → `Core/Sources/CommandSupport/CommandRunner.swift`
- Move: `Core/Tests/GitHubKitTests/CommandRunnerTests.swift` → `Core/Tests/CommandSupportTests/CommandRunnerTests.swift`
- Modify: `Core/Sources/GitHubKit/GitHubClient.swift` (add `import CommandSupport`)
- Modify: `Core/Tests/GitHubKitTests/GitHubClientTests.swift` (add `import CommandSupport`)
- Modify: `Core/Package.swift`

- [ ] **Step 1: Move the source file**

```bash
mkdir -p Core/Sources/CommandSupport
git mv Core/Sources/GitHubKit/CommandRunner.swift Core/Sources/CommandSupport/CommandRunner.swift
```

(Contents unchanged — `CommandResult`, `CommandRunner`, `ProcessCommandRunner` keep their exact code.)

- [ ] **Step 2: Move the runner's test file and fix its import**

```bash
mkdir -p Core/Tests/CommandSupportTests
git mv Core/Tests/GitHubKitTests/CommandRunnerTests.swift Core/Tests/CommandSupportTests/CommandRunnerTests.swift
```

Then in `Core/Tests/CommandSupportTests/CommandRunnerTests.swift`, change the import line `import GitHubKit` to:

```swift
import CommandSupport
```

- [ ] **Step 3: Add `import CommandSupport` to the two GitHubKit files that use the runner**

In `Core/Sources/GitHubKit/GitHubClient.swift`, the import block becomes exactly:

```swift
import Foundation
import PRReviewModels
import CommandSupport
```

In `Core/Tests/GitHubKitTests/GitHubClientTests.swift`, the import block becomes exactly:

```swift
import Testing
import Foundation
import PRReviewModels
import CommandSupport
@testable import GitHubKit
```

(`PRRefTests.swift` is unchanged — it does not use the runner.)

- [ ] **Step 4: Update the manifest**

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
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["PRReviewModels"]),
        .target(name: "DiffKit", dependencies: ["PRReviewModels"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
    ]
)
```

- [ ] **Step 5: Run the full suite to verify the refactor preserved behavior**

Run: `swift test --package-path Core`
Expected: PASS — 25 tests total, 0 failures (same count as before; the 2 `CommandRunner` tests now run under `CommandSupportTests`). A compile error here means an import was missed.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "refactor: extract CommandSupport module from GitHubKit"
```

---

## Task 2: `WorktreeManager` with real-git integration tests

**Files:**
- Create: `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`
- Create: `Core/Sources/WorktreeKit/WorktreeError.swift`
- Create: `Core/Sources/WorktreeKit/WorktreeManager.swift`
- Delete: `Core/Sources/WorktreeKit/WorktreeKit.swift` (the placeholder `enum WorktreeKit {}`)
- Modify: `Core/Package.swift` (point `WorktreeKit` at `CommandSupport`, add `WorktreeKitTests`)

- [ ] **Step 1: Write the failing integration tests**

Create `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`:

```swift
import Testing
import Foundation
import CommandSupport
import WorktreeKit

private let gitPath = "/opt/homebrew/bin/git"

private struct GitFixture {
    let root: String
    let remoteURL: String
    let managedRoot: String
    let baseSha: String
    let prHeadSha: String
}

@discardableResult
private func git(_ arguments: [String]) async throws -> String {
    let result = try await ProcessCommandRunner().run(executable: gitPath, arguments: arguments)
    guard result.exitCode == 0 else {
        throw NSError(domain: "git-fixture", code: Int(result.exitCode), userInfo: [
            NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.standardError)"
        ])
    }
    return result.standardOutput
}

private func makeFixture(prNumber: Int) async throws -> GitFixture {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    let bare = root + "/remote.git"
    let work = root + "/work"

    try await git(["init", "--bare", "-b", "main", bare])
    try await git(["clone", bare, work])
    try await git(["-C", work, "config", "user.email", "test@example.com"])
    try await git(["-C", work, "config", "user.name", "Test User"])
    try await git(["-C", work, "config", "commit.gpgsign", "false"])

    try "base\n".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "base"])
    try await git(["-C", work, "branch", "-M", "main"])
    try await git(["-C", work, "push", "origin", "main"])
    let baseSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    try await git(["-C", work, "checkout", "-b", "pr-branch"])
    try "feature\n".write(toFile: work + "/feature.txt", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "feature"])
    let prHeadSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try await git(["-C", work, "push", "origin", "pr-branch"])
    try await git(["-C", bare, "update-ref", "refs/pull/\(prNumber)/head", prHeadSha])

    return GitFixture(root: root, remoteURL: bare, managedRoot: root + "/managed", baseSha: baseSha, prHeadSha: prHeadSha)
}

@Test func resolveCloneUsesRegisteredPathWhenItExists() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let registered = fixture.root + "/work"
    let resolved = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: registered)
    #expect(resolved == registered)
}

@Test func resolveCloneAutoClonesIntoManagedDir() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let resolved = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    #expect(resolved == fixture.managedRoot + "/repos/bsv-blockchain/teranode")
    #expect(FileManager.default.fileExists(atPath: resolved + "/.git"))
}

@Test func createWorktreeChecksOutPRHead() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "bsv-blockchain", repo: "teranode", number: 944)

    #expect(worktree == fixture.managedRoot + "/worktrees/bsv-blockchain-teranode-pr944")
    #expect(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
    let head = try await git(["-C", worktree, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(head == fixture.prHeadSha)
}

@Test func mergeBaseReturnsBaseCommit() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    let base = try await manager.mergeBase(worktreePath: worktree, baseRef: "origin/main")
    #expect(base == fixture.baseSha)
}

@Test func removeWorktreeDeletesIt() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    #expect(FileManager.default.fileExists(atPath: worktree))
    try await manager.removeWorktree(clonePath: clone, worktreePath: worktree)
    #expect(!FileManager.default.fileExists(atPath: worktree))
}
```

- [ ] **Step 2: Register the test target and re-point `WorktreeKit`**

Replace the ENTIRE contents of `Core/Package.swift` with (changes vs. Task 1: `WorktreeKit` now depends on `CommandSupport` instead of `PRReviewModels`, and a `WorktreeKitTests` target is added):

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
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["PRReviewModels"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
    ]
)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'WorktreeManager' in scope` (the target still has only the placeholder `enum WorktreeKit`).

- [ ] **Step 4: Implement the error type**

Create `Core/Sources/WorktreeKit/WorktreeError.swift`:

```swift
public enum WorktreeError: Error, Equatable {
    case gitFailed(arguments: [String], exitCode: Int32, message: String)
}
```

- [ ] **Step 5: Implement `WorktreeManager` and remove the placeholder**

Create `Core/Sources/WorktreeKit/WorktreeManager.swift`:

```swift
import Foundation
import CommandSupport

public struct WorktreeManager: Sendable {
    private let runner: CommandRunner
    private let gitPath: String
    private let managedRoot: String

    public init(runner: CommandRunner, gitPath: String, managedRoot: String) {
        self.runner = runner
        self.gitPath = gitPath
        self.managedRoot = managedRoot
    }

    public func resolveClone(owner: String, repo: String, remoteURL: String, registeredClonePath: String?) async throws -> String {
        let fileManager = FileManager.default
        if let registeredClonePath, fileManager.fileExists(atPath: registeredClonePath) {
            return registeredClonePath
        }
        let reposDir = managedRoot + "/repos/" + owner
        let clonePath = reposDir + "/" + repo
        if fileManager.fileExists(atPath: clonePath) {
            return clonePath
        }
        try fileManager.createDirectory(atPath: reposDir, withIntermediateDirectories: true)
        try await runGit(["clone", remoteURL, clonePath])
        return clonePath
    }

    public func createWorktree(clonePath: String, owner: String, repo: String, number: Int) async throws -> String {
        try await runGit(["-C", clonePath, "fetch", "origin", "refs/pull/\(number)/head"])
        let sha = try await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreesDir = managedRoot + "/worktrees"
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-pr" + String(number)
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        try await runGit(["-C", clonePath, "worktree", "add", "--detach", worktreePath, sha])
        return worktreePath
    }

    public func mergeBase(worktreePath: String, baseRef: String) async throws -> String {
        try await runGit(["-C", worktreePath, "merge-base", "HEAD", baseRef]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func removeWorktree(clonePath: String, worktreePath: String) async throws {
        try await runGit(["-C", clonePath, "worktree", "remove", worktreePath])
    }

    @discardableResult
    private func runGit(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(executable: gitPath, arguments: arguments)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardError)
        }
        return result.standardOutput
    }
}
```

Then delete the placeholder: `rm Core/Sources/WorktreeKit/WorktreeKit.swift`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 30 tests total (25 + 5 new `WorktreeManager` integration tests), 0 failures. (The integration tests invoke real `git`; allow a couple of seconds.)

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "feat: add WorktreeManager for hybrid clone resolution and worktrees"
```

---

## Self-review (this plan vs. its slice of the spec)

- **Spec coverage:** the spec's `WorktreeKit` core is realized — "registered local clone → use it; otherwise auto-clone into `managedRoot/repos/<owner>/<repo>`" (`resolveClone`); "fetch `refs/pull/N/head` (fork-safe), then `git worktree add` at `managedRoot/worktrees/<owner>-<repo>-prN`" (`createWorktree`, detached at the fetched SHA); "diff base = merge-base(head, target)" (`mergeBase`); and `git worktree remove` (`removeWorktree`). Deferred spec items (branch-advance refresh, dirty-guard, transactional build) are noted as out of scope. The `CommandSupport` extraction supports the spec's intent that `git` and `gh` are both run through an injectable, testable runner.
- **Placeholder scan:** none — full file contents, exact commands, expected outputs. Tests verify real behavior against real git: registered-path passthrough, managed auto-clone existence, worktree checked out at the exact PR-head SHA with the PR's file present, merge-base equal to the base commit, and removal deleting the worktree directory.
- **Type consistency:** test call sites match `WorktreeManager(runner:gitPath:managedRoot:)`, `resolveClone(owner:repo:remoteURL:registeredClonePath:)`, `createWorktree(clonePath:owner:repo:number:)`, `mergeBase(worktreePath:baseRef:)`, `removeWorktree(clonePath:worktreePath:)`. `WorktreeManager` depends only on `CommandSupport` (`CommandRunner`, `ProcessCommandRunner`), matching the manifest's `WorktreeKit → CommandSupport` edge. Task 1's import additions (`GitHubClient.swift`, `GitHubClientTests.swift`) match the moved `CommandRunner`'s new module.

## Definition of done

- `swift test --package-path Core` → 30 tests passing, 0 failures.
- `CommandSupport` exists as its own module; `GitHubKit` and `WorktreeKit` both depend on it; neither depends on the other.
- `WorktreeManager` resolves clones (hybrid), creates a detached worktree at the PR head via `refs/pull/N/head`, computes the merge-base, and removes worktrees — all verified against real git.
- Placeholders gone; two commits (refactor + feature); working tree clean; no `project.yml`/app changes.
