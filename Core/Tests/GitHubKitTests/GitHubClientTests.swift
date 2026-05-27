import Testing
import Foundation
import PRReviewModels
import CommandSupport
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
    #expect(GitHubClient.mapState(state: "CLOSED", isDraft: true) == .closed)
}

@Test func fetchReviewThrowsOnBadJSON() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "{}", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)

    await #expect(throws: GitHubError.self) {
        try await client.fetchReview(for: ref)
    }
}
