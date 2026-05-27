# PR Review — Phase 1, Plan 5: DiffKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse a `git diff` into a structured model the UI can render — the headless core of the native Diff pane.

**Architecture:** `DiffKit` gains a value-type diff model (`DiffFile` → `DiffHunk` → `DiffLine`), a pure `DiffParser` that turns unified-diff text into that model (heavily fixture-tested), and a `DiffService` that runs `git -C <worktree> diff <base> HEAD` through `CommandSupport` and feeds the parser. The SwiftUI view that renders this model comes in the next plan (wiring).

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, `git` via `CommandSupport`.

**Companion spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md` (see "DiffKit").

**Plan sequence:** …4-worktreekit ✅ · 6-app (thin) ✅ · **5-diffkit (this)** · then 7-diff-pane (worktree checkout wiring + native diff view).

---

## Scope notes

- **Parser + model + git-diff runner only.** Syntax highlighting (tree-sitter), split view, and row virtualization stay deferred; the next plan renders a unified view from this model.
- **Diff base:** `DiffService` runs `git -C <worktree> diff <baseRef> HEAD` (2-dot). The caller passes the merge-base SHA (from `WorktreeManager.mergeBase`) as `baseRef`, which matches GitHub's "Files changed."
- **No `project.yml`/app changes.** Consumed in Plan 7.
- **Binary diffs** are out of scope: a binary file yields a `DiffFile` with no hunks (acceptable; the view can label it later).
- `DiffKit`'s dependency changes from `PRReviewModels` to `CommandSupport` (the diff model is self-contained; `DiffService` needs the runner).

---

## Task 1: Diff model + `DiffParser`

**Files:**
- Create: `Core/Tests/DiffKitTests/DiffParserTests.swift`
- Create: `Core/Sources/DiffKit/DiffModel.swift`
- Create: `Core/Sources/DiffKit/DiffParser.swift`
- Delete: `Core/Sources/DiffKit/DiffKit.swift` (placeholder)
- Modify: `Core/Package.swift` (DiffKit deps → CommandSupport; add DiffKitTests)

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/DiffKitTests/DiffParserTests.swift`:

```swift
import Testing
import DiffKit

private let modifiedDiff = """
diff --git a/foo.txt b/foo.txt
index 1111111..2222222 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
"""

private let addedDiff = """
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
"""

private let deletedDiff = """
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 4444444..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
"""

@Test func parsesModifiedFileWithLineNumbers() {
    let files = DiffParser.parse(modifiedDiff)
    #expect(files.count == 1)
    let file = files[0]
    #expect(file.oldPath == "foo.txt")
    #expect(file.newPath == "foo.txt")
    #expect(file.changeKind == .modified)
    #expect(file.addedCount == 1)
    #expect(file.removedCount == 1)
    #expect(file.hunks.count == 1)

    let lines = file.hunks[0].lines
    #expect(lines.count == 4)
    #expect(lines[0].kind == .context)
    #expect(lines[0].text == "alpha")
    #expect(lines[0].oldNumber == 1)
    #expect(lines[0].newNumber == 1)
    #expect(lines[1].kind == .removed)
    #expect(lines[1].text == "beta")
    #expect(lines[1].oldNumber == 2)
    #expect(lines[1].newNumber == nil)
    #expect(lines[2].kind == .added)
    #expect(lines[2].text == "BETA")
    #expect(lines[2].oldNumber == nil)
    #expect(lines[2].newNumber == 2)
    #expect(lines[3].kind == .context)
    #expect(lines[3].oldNumber == 3)
    #expect(lines[3].newNumber == 3)
}

@Test func parsesAddedFile() {
    let files = DiffParser.parse(addedDiff)
    #expect(files.count == 1)
    #expect(files[0].oldPath == nil)
    #expect(files[0].newPath == "new.txt")
    #expect(files[0].changeKind == .added)
    #expect(files[0].addedCount == 2)
    #expect(files[0].removedCount == 0)
    #expect(files[0].hunks[0].lines.map(\.text) == ["one", "two"])
}

@Test func parsesDeletedFile() {
    let files = DiffParser.parse(deletedDiff)
    #expect(files.count == 1)
    #expect(files[0].oldPath == "gone.txt")
    #expect(files[0].newPath == nil)
    #expect(files[0].changeKind == .deleted)
    #expect(files[0].removedCount == 1)
    #expect(files[0].hunks[0].lines[0].kind == .removed)
    #expect(files[0].hunks[0].lines[0].oldNumber == 1)
}

@Test func parsesMultipleFiles() {
    let files = DiffParser.parse(modifiedDiff + "\n" + addedDiff)
    #expect(files.count == 2)
    #expect(files[0].newPath == "foo.txt")
    #expect(files[1].newPath == "new.txt")
}

@Test func emptyDiffYieldsNoFiles() {
    #expect(DiffParser.parse("").isEmpty)
}
```

- [ ] **Step 2: Update the manifest**

Replace the ENTIRE contents of `Core/Package.swift` with (changes: `DiffKit` now depends on `CommandSupport`; add `DiffKitTests`):

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
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["CommandSupport"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .target(name: "AppCore", dependencies: ["PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit"]),
    ]
)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'DiffParser' in scope` (only the placeholder `enum DiffKit` exists).

- [ ] **Step 4: Create the model**

Create `Core/Sources/DiffKit/DiffModel.swift`:

```swift
public enum DiffLineKind: String, Sendable, Equatable {
    case context
    case added
    case removed
}

public struct DiffLine: Sendable, Equatable {
    public var kind: DiffLineKind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffHunk: Sendable, Equatable {
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

public enum FileChangeKind: String, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
}

public struct DiffFile: Sendable, Equatable, Identifiable {
    public var oldPath: String?
    public var newPath: String?
    public var changeKind: FileChangeKind
    public var hunks: [DiffHunk]
    public var addedCount: Int
    public var removedCount: Int

    public var id: String { newPath ?? oldPath ?? "" }

    public init(oldPath: String?, newPath: String?, changeKind: FileChangeKind, hunks: [DiffHunk], addedCount: Int, removedCount: Int) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.changeKind = changeKind
        self.hunks = hunks
        self.addedCount = addedCount
        self.removedCount = removedCount
    }
}
```

- [ ] **Step 5: Create the parser and remove the placeholder**

Create `Core/Sources/DiffKit/DiffParser.swift`:

```swift
public enum DiffParser {
    public static func parse(_ unifiedDiff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var oldNumber = 0
        var newNumber = 0

        func flush() {
            if let file = current {
                files.append(file)
            }
            current = nil
        }

        let lines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                current = DiffFile(oldPath: nil, newPath: nil, changeKind: .modified, hunks: [], addedCount: 0, removedCount: 0)
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("@@") {
                let (oldStart, newStart) = Self.hunkStarts(line)
                oldNumber = oldStart
                newNumber = newStart
                current!.hunks.append(DiffHunk(header: line, lines: []))
            } else if current!.hunks.isEmpty {
                if line.hasPrefix("new file mode") {
                    current!.changeKind = .added
                } else if line.hasPrefix("deleted file mode") {
                    current!.changeKind = .deleted
                } else if line.hasPrefix("rename from ") {
                    current!.oldPath = String(line.dropFirst("rename from ".count))
                    current!.changeKind = .renamed
                } else if line.hasPrefix("rename to ") {
                    current!.newPath = String(line.dropFirst("rename to ".count))
                    current!.changeKind = .renamed
                } else if line.hasPrefix("--- ") {
                    current!.oldPath = Self.path(from: line, prefix: "--- ")
                } else if line.hasPrefix("+++ ") {
                    current!.newPath = Self.path(from: line, prefix: "+++ ")
                }
            } else {
                let hunkIndex = current!.hunks.count - 1
                if line.hasPrefix("+") {
                    current!.hunks[hunkIndex].lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: String(line.dropFirst())))
                    newNumber += 1
                    current!.addedCount += 1
                } else if line.hasPrefix("-") {
                    current!.hunks[hunkIndex].lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: String(line.dropFirst())))
                    oldNumber += 1
                    current!.removedCount += 1
                } else if line.hasPrefix(" ") {
                    current!.hunks[hunkIndex].lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: String(line.dropFirst())))
                    oldNumber += 1
                    newNumber += 1
                }
            }
        }
        flush()
        return files
    }

    private static func path(from line: String, prefix: String) -> String? {
        let value = String(line.dropFirst(prefix.count))
        if value == "/dev/null" {
            return nil
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            return String(value.dropFirst(2))
        }
        return value
    }

    private static func hunkStarts(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        var oldStart = 0
        var newStart = 0
        for part in parts {
            if part.hasPrefix("-") {
                let numbers = part.dropFirst().split(separator: ",")
                oldStart = Int(numbers.first ?? "0") ?? 0
            } else if part.hasPrefix("+") {
                let numbers = part.dropFirst().split(separator: ",")
                newStart = Int(numbers.first ?? "0") ?? 0
            }
        }
        return (oldStart, newStart)
    }
}
```

Then delete the placeholder: `rm Core/Sources/DiffKit/DiffKit.swift`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 42 tests total (37 prior + 5 new parser tests), 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "feat: add diff model and unified-diff parser to DiffKit"
```

---

## Task 2: `DiffService` — run `git diff` and parse

**Files:**
- Create: `Core/Tests/DiffKitTests/DiffServiceTests.swift`
- Create: `Core/Sources/DiffKit/DiffError.swift`
- Create: `Core/Sources/DiffKit/DiffService.swift`
- Modify: `Core/Package.swift` (DiffKitTests now also depends on `CommandSupport`)

- [ ] **Step 1: Write the failing integration test**

Create `Core/Tests/DiffKitTests/DiffServiceTests.swift`:

```swift
import Testing
import Foundation
import CommandSupport
import DiffKit

private let gitPath = "/opt/homebrew/bin/git"

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

@Test func diffServiceParsesGitDiffBetweenCommits() async throws {
    let fileManager = FileManager.default
    let repo = fileManager.temporaryDirectory.appendingPathComponent("diff-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: repo, withIntermediateDirectories: true)

    try await git(["init", "-b", "main", repo])
    try await git(["-C", repo, "config", "user.email", "test@example.com"])
    try await git(["-C", repo, "config", "user.name", "Test User"])
    try await git(["-C", repo, "config", "commit.gpgsign", "false"])
    try "alpha\nbeta\ngamma\n".write(toFile: repo + "/foo.txt", atomically: true, encoding: .utf8)
    try await git(["-C", repo, "add", "."])
    try await git(["-C", repo, "commit", "-m", "base"])
    let baseSha = try await git(["-C", repo, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    try "alpha\nBETA\ngamma\n".write(toFile: repo + "/foo.txt", atomically: true, encoding: .utf8)
    try await git(["-C", repo, "add", "."])
    try await git(["-C", repo, "commit", "-m", "change"])

    let service = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
    let files = try await service.diff(worktreePath: repo, baseRef: baseSha)

    #expect(files.count == 1)
    #expect(files[0].newPath == "foo.txt")
    #expect(files[0].changeKind == .modified)
    #expect(files[0].addedCount == 1)
    #expect(files[0].removedCount == 1)
}

@Test func diffServiceThrowsOnGitFailure() async {
    let service = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
    await #expect(throws: DiffError.self) {
        _ = try await service.diff(worktreePath: "/nonexistent/repo/path", baseRef: "HEAD")
    }
}
```

- [ ] **Step 2: Let `DiffKitTests` use `CommandSupport`**

In `Core/Package.swift`, change the `DiffKitTests` test target line to:

```swift
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit", "CommandSupport"]),
```

(Everything else in the manifest stays as it is after Task 1.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'DiffService' in scope`.

- [ ] **Step 4: Create the error type**

Create `Core/Sources/DiffKit/DiffError.swift`:

```swift
public enum DiffError: Error, Equatable {
    case gitFailed(exitCode: Int32, message: String)
}
```

- [ ] **Step 5: Create `DiffService`**

Create `Core/Sources/DiffKit/DiffService.swift`:

```swift
import CommandSupport

public struct DiffService: Sendable {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func diff(worktreePath: String, baseRef: String) async throws -> [DiffFile] {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "diff", baseRef, "HEAD"]
        )
        guard result.exitCode == 0 else {
            throw DiffError.gitFailed(exitCode: result.exitCode, message: result.standardError)
        }
        return DiffParser.parse(result.standardOutput)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 44 tests total (42 + 2 new `DiffService` tests), 0 failures. The integration test runs real git; allow a couple seconds.

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "feat: add DiffService to run git diff and parse it"
```

---

## Self-review (this plan vs. its slice of the spec)

- **Spec coverage:** the spec's `DiffKit` "parse `git diff` → model (files → hunks → lines with old/new line numbers and origin)" is realized by `DiffModel` + `DiffParser`; the "`git diff <merge-base>...<head>`" production is `DiffService.diff(worktreePath:baseRef:)` (2-dot against the merge-base SHA the caller supplies). tree-sitter highlighting, split view, and virtualization are explicitly deferred to the rendering plan.
- **Placeholder scan:** none — full file contents and expected outputs. Parser tests assert real structure (line kinds, old/new numbers, counts, change kinds across modified/added/deleted/multi-file/empty); the service test parses a real `git diff` between two real commits and asserts the model, plus an error-path test.
- **Type consistency:** tests use `DiffParser.parse(_:) -> [DiffFile]`; `DiffFile` fields (`oldPath`, `newPath`, `changeKind`, `hunks`, `addedCount`, `removedCount`) and nested `DiffHunk.lines` / `DiffLine` (`kind`, `oldNumber`, `newNumber`, `text`); `DiffService(runner:gitPath:)` + `diff(worktreePath:baseRef:)`; `DiffError`. `DiffKit` depends on `CommandSupport` per the manifest; the model/parser are dependency-free Swift.

## Definition of done

- `swift test --package-path Core` → 44 tests passing, 0 failures.
- `DiffParser` correctly models modified/added/deleted files with accurate old/new line numbers and add/remove counts.
- `DiffService` runs real `git diff` and returns the parsed model; throws `DiffError` on git failure.
- Placeholder gone; two commits; working tree clean; no `project.yml`/app changes.
- Next: Plan 7 wires lazy worktree checkout + a native SwiftUI diff view that renders `[DiffFile]` into the Diff pane.
