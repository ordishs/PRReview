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
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        if shouldThrow {
            throw DiffError.gitFailed(exitCode: 1, message: "stub failure")
        }
        return DiffResult(worktreePath: "/tmp/wt", files: files)
    }
}

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
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.selection == "bsv-blockchain/teranode#944")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func addPRSurfacesCommandFailureAndDismisses() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())

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
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client, diffLoader: StubDiffLoader(), cloneRegistrar: StubRegistrar())

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}

@Test @MainActor func loadDiffSetsLoadedState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let file = DiffFile(oldPath: "foo.txt", newPath: "foo.txt", changeKind: .modified, hunks: [], addedCount: 1, removedCount: 0)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: [file]), cloneRegistrar: StubRegistrar())

    await model.loadDiff(for: sampleReview())

    #expect(model.diffState == .loaded([file]))
}

@Test @MainActor func loadDiffSetsFailedStateOnError() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(shouldThrow: true), cloneRegistrar: StubRegistrar())

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
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: []), cloneRegistrar: StubRegistrar())
    await model.load()

    await model.loadDiff(for: review)

    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allReviews().first?.worktreePath == "/tmp/wt")
}

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
