import Testing
import Foundation
import PRReviewModels
import GitHubKit
import CommandSupport
import ReviewStore
import DiffKit
@testable import AppCore

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appcore-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private let prJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main"
}
"""

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

@Test @MainActor func addPRFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: prJSON, standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.selection == "bsv-blockchain/teranode#944")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader())

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func addPRSurfacesCommandFailureAndDismisses() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)

    model.dismissError()
    #expect(model.errorMessage == nil)
}

@Test @MainActor func loadReadsExistingReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    try await seedStore.upsert(Review(
        owner: "bsv-blockchain", repo: "teranode", number: 901,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/901")!,
        title: "prune", author: "jad", headBranch: "prune", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client, diffLoader: StubDiffLoader())

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}

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
