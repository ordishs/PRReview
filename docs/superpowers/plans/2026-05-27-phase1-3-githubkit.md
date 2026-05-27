# PR Review — Phase 1, Plan 3: GitHubKit (add-by-URL)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a pasted GitHub PR URL into a fully-populated `Review` by shelling out to the `gh` CLI — the data half of the "Add" feature.

**Architecture:** `GitHubKit` gains three pieces: a `CommandRunner` protocol (with a real `Process`-based implementation and a test stub) so external-process calls are injectable and unit-testable; a `PRRef.parse(_:)` that extracts `(owner, repo, number)` from a PR URL; and a `GitHubClient` that runs `gh pr view … --json …`, decodes the result, and maps it to a `Review`. All logic is exercised through `swift test` — the real `gh` is replaced by a stub in tests.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation (`Process`, `URLComponents`, `JSONDecoder`).

**Companion spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md` (see "GitHubKit").

**Plan sequence (Phase 1):** 1-scaffold ✅ · 2-reviewstore ✅ · **3-githubkit (this)** · 4-worktreekit · 5-diffkit · 6-app-integration.

---

## Scope notes

- **Add-by-URL slice only.** The spec's `GitHubKit` also does discovery polling, merge/dedup, and comment-posting — those are Phase 2 and Phase 4. This plan implements only URL→`Review` via `gh`.
- **No `project.yml` / app changes.** Tested in isolation via `swift test`; consumed by the app in Plan 6.
- **`gh` is never called in tests.** Unit tests inject a stub `CommandRunner`. The one exception is `ProcessCommandRunner`'s own tests, which run trivial always-present system binaries (`/bin/echo`, `/usr/bin/false`) — deterministic and offline.
- **`ghPath` is passed in, not discovered here.** Resolving the `gh` binary path (from `Settings`/`PATH`) is a Plan 6 concern; `GitHubClient` takes it as a parameter.

---

## Task 1: `CommandRunner` abstraction

**Files:**
- Create: `Core/Tests/GitHubKitTests/CommandRunnerTests.swift`
- Modify: `Core/Package.swift` (add the `GitHubKitTests` test target)
- Create: `Core/Sources/GitHubKit/CommandRunner.swift`
- Delete: `Core/Sources/GitHubKit/GitHubKit.swift` (the placeholder `enum GitHubKit {}`)

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/GitHubKitTests/CommandRunnerTests.swift`:

```swift
import Testing
import Foundation
import GitHubKit

@Test func processRunnerCapturesStdoutAndZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/bin/echo", arguments: ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "hello\n")
}

@Test func processRunnerReportsNonZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/usr/bin/false", arguments: [])
    #expect(result.exitCode == 1)
}
```

- [ ] **Step 2: Register the test target**

Replace the ENTIRE contents of `Core/Package.swift` with (adds `GitHubKitTests`; everything else unchanged from Plan 2):

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
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels"]),
    ]
)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'ProcessCommandRunner' in scope` (only the placeholder `enum GitHubKit {}` exists in the target).

- [ ] **Step 4: Implement the runner and remove the placeholder**

Create `Core/Sources/GitHubKit/CommandRunner.swift`:

```swift
import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
```

Then delete the placeholder file:

```bash
rm Core/Sources/GitHubKit/GitHubKit.swift
```

> The reads-then-waits pattern is safe here because `gh pr view` for a single PR emits a few KB — well under the OS pipe buffer. If GitHubKit ever drives a command with large output, switch to concurrent pipe reads. `ProcessCommandRunner` itself is verified by the two tests above (against `/bin/echo` and `/usr/bin/false`); higher layers use a stub.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 14 tests total (12 from Plans 1–2 + the 2 new `CommandRunner` tests), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "feat: add CommandRunner abstraction to GitHubKit"
```

---

## Task 2: PR URL parsing (`PRRef` + `GitHubError`)

**Files:**
- Create: `Core/Tests/GitHubKitTests/PRRefTests.swift`
- Create: `Core/Sources/GitHubKit/GitHubError.swift`
- Create: `Core/Sources/GitHubKit/PRRef.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/GitHubKitTests/PRRefTests.swift`:

```swift
import Testing
import GitHubKit

@Test func parsesStandardPullURL() throws {
    let ref = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944")
    #expect(ref == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))
}

@Test func parsesPullURLWithTrailingPathAndQuery() throws {
    let filesRef = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944/files")
    #expect(filesRef == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))

    let queryRef = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944?diff=split")
    #expect(queryRef == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))
}

@Test func rejectsNonPullURL() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://github.com/bsv-blockchain/teranode/issues/944")
    }
}

@Test func rejectsWrongHost() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://example.com/bsv-blockchain/teranode/pull/944")
    }
}

@Test func rejectsMalformedURL() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("not a url")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'PRRef' in scope` / `cannot find 'GitHubError' in scope`.

- [ ] **Step 3: Create the error type**

Create `Core/Sources/GitHubKit/GitHubError.swift`:

```swift
public enum GitHubError: Error, Equatable {
    case invalidURL(String)
    case commandFailed(exitCode: Int32, message: String)
    case decodingFailed(String)
}
```

- [ ] **Step 4: Create `PRRef`**

Create `Core/Sources/GitHubKit/PRRef.swift`:

```swift
import Foundation

public struct PRRef: Sendable, Equatable {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public static func parse(_ urlString: String) throws -> PRRef {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host,
              host == "github.com" || host == "www.github.com" else {
            throw GitHubError.invalidURL(urlString)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else {
            throw GitHubError.invalidURL(urlString)
        }
        return PRRef(owner: parts[0], repo: parts[1], number: number)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 19 tests total (14 + 5 new `PRRef` tests), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "feat: add PR URL parsing to GitHubKit"
```

---

## Task 3: `GitHubClient` — fetch PR metadata via `gh`

**Files:**
- Create: `Core/Tests/GitHubKitTests/GitHubClientTests.swift`
- Create: `Core/Sources/GitHubKit/GitHubClient.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/GitHubKitTests/GitHubClientTests.swift`:

```swift
import Testing
import Foundation
import PRReviewModels
@testable import GitHubKit

private actor RecordingRunner: CommandRunner {
    let result: CommandResult
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String]?

    init(result: CommandResult) {
        self.result = result
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        lastExecutable = executable
        lastArguments = arguments
        return result
    }
}

private let samplePRJSON = """
{
  "number": 944,
  "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge-bidirectional",
  "baseRefName": "main"
}
"""

@Test func fetchReviewMapsJSONToReview() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: samplePRJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    let review = try await client.fetchReview(for: ref, origin: .added, now: fixedDate)

    #expect(review.id == "bsv-blockchain/teranode#944")
    #expect(review.owner == "bsv-blockchain")
    #expect(review.repo == "teranode")
    #expect(review.number == 944)
    #expect(review.title == "fix(asset/centrifuge): speak bidirectional Centrifuge protocol")
    #expect(review.author == "icellan")
    #expect(review.headBranch == "fix/centrifuge-bidirectional")
    #expect(review.baseBranch == "main")
    #expect(review.url.absoluteString == "https://github.com/bsv-blockchain/teranode/pull/944")
    #expect(review.prState == .open)
    #expect(review.origin == .added)
    #expect(review.addedAt == fixedDate)

    let args = await runner.lastArguments
    #expect(args == ["pr", "view", "944", "--repo", "bsv-blockchain/teranode", "--json", "number,title,url,state,isDraft,author,headRefName,baseRefName"])
    let executable = await runner.lastExecutable
    #expect(executable == "/opt/homebrew/bin/gh")
}

@Test func fetchReviewThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 999)

    await #expect(throws: GitHubError.self) {
        try await client.fetchReview(for: ref)
    }
}

@Test func mapStateCoversAllCases() {
    #expect(GitHubClient.mapState(state: "OPEN", isDraft: false) == .open)
    #expect(GitHubClient.mapState(state: "OPEN", isDraft: true) == .draft)
    #expect(GitHubClient.mapState(state: "MERGED", isDraft: false) == .merged)
    #expect(GitHubClient.mapState(state: "MERGED", isDraft: true) == .merged)
    #expect(GitHubClient.mapState(state: "CLOSED", isDraft: false) == .closed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'GitHubClient' in scope`.

- [ ] **Step 3: Implement `GitHubClient`**

Create `Core/Sources/GitHubKit/GitHubClient.swift`:

```swift
import Foundation
import PRReviewModels

public struct GitHubClient: Sendable {
    private let runner: CommandRunner
    private let ghPath: String

    public init(runner: CommandRunner, ghPath: String) {
        self.runner = runner
        self.ghPath = ghPath
    }

    public func fetchReview(for ref: PRRef, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> Review {
        let fields = "number,title,url,state,isDraft,author,headRefName,baseRefName"
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["pr", "view", String(ref.number), "--repo", "\(ref.owner)/\(ref.repo)", "--json", fields]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let pullRequest: GHPullRequest
        do {
            pullRequest = try JSONDecoder().decode(GHPullRequest.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        guard let url = URL(string: pullRequest.url) else {
            throw GitHubError.decodingFailed("invalid url: \(pullRequest.url)")
        }
        return Review(
            owner: ref.owner,
            repo: ref.repo,
            number: pullRequest.number,
            url: url,
            title: pullRequest.title,
            author: pullRequest.author.login,
            headBranch: pullRequest.headRefName,
            baseBranch: pullRequest.baseRefName,
            origin: origin,
            prState: GitHubClient.mapState(state: pullRequest.state, isDraft: pullRequest.isDraft),
            addedAt: now
        )
    }

    static func mapState(state: String, isDraft: Bool) -> PRState {
        if state == "MERGED" {
            return .merged
        }
        if state == "CLOSED" {
            return .closed
        }
        if isDraft {
            return .draft
        }
        return .open
    }
}

struct GHPullRequest: Decodable {
    struct Author: Decodable {
        let login: String
    }

    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: Author
    let headRefName: String
    let baseRefName: String
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 22 tests total (19 + 3 new `GitHubClient` tests), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "feat: add GitHubClient to fetch PR metadata via gh"
```

---

## Self-review (this plan vs. its slice of the spec)

- **Spec coverage:** the spec's `GitHubKit` "Add-by-URL: parses owner/repo/number from a pasted link, fetches via `gh pr view --json`" is fully realized — `PRRef.parse` does the parsing; `GitHubClient.fetchReview` runs `gh pr view <n> --repo o/r --json …`, decodes, and maps to a `Review` with `origin = .added`. The injectable-runner requirement ("wraps `gh` behind an injectable runner so tests feed canned JSON, no network") is met by `CommandRunner`/`ProcessCommandRunner` + the test `RecordingRunner`. Discovery, dedup, and comments are correctly out of scope (later phases).
- **Placeholder scan:** none — full file contents and expected command output for every step. The empty namespace `enum GitHubKit {}` is explicitly deleted once real types exist. Tests assert real behavior: URL parse correctness and rejection, JSON→`Review` field mapping, exact `gh` argument construction, all four `PRState` mappings, and error-on-nonzero-exit.
- **Type consistency:** test call sites match implementation — `ProcessCommandRunner()` / `run(executable:arguments:)` returning `CommandResult(exitCode:standardOutput:standardError:)`; `PRRef(owner:repo:number:)` and `PRRef.parse(_:)`; `GitHubClient(runner:ghPath:)`, `fetchReview(for:origin:now:)`, and the internal `static mapState(state:isDraft:)` (accessed via `@testable`). `GHPullRequest`'s coding keys match the `--json` field list passed to `gh`. The `Review.init` call uses the signature defined in Plan 2 (no `id:` argument).

## Definition of done

- `swift test --package-path Core` → 22 tests passing, 0 failures.
- `PRRef.parse` accepts canonical PR URLs (incl. trailing path/query) and rejects issues/wrong-host/malformed.
- `GitHubClient.fetchReview` builds the correct `gh` invocation, maps JSON to a `Review`, and throws `GitHubError` on non-zero exit.
- The placeholder `enum GitHubKit {}` is gone; three commits made; working tree clean; no `project.yml`/app changes.
