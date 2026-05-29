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
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

private let samplePRJSONWithClosingIssue = """
{
  "number": 944,
  "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge-bidirectional",
  "baseRefName": "main",
  "closingIssuesReferences": [{ "number": 123 }, { "number": 456 }]
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
    #expect(review.closingIssueNumber == nil)

    let args = await runner.lastArguments
    #expect(args == ["pr", "view", "944", "--repo", "bsv-blockchain/teranode", "--json", "number,title,url,state,isDraft,author,headRefName,baseRefName,closingIssuesReferences"])
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

@Test func fetchReviewPopulatesClosingIssueNumber() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: samplePRJSONWithClosingIssue, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944)

    let review = try await client.fetchReview(for: ref)

    #expect(review.closingIssueNumber == 123)
}

private let sampleSearchJSON = """
[
  {
    "number": 944,
    "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 17,
    "title": "WIP",
    "url": "https://github.com/foo/bar/pull/17",
    "state": "open",
    "isDraft": true,
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "foo/bar" }
  }
]
"""

private let sampleSearchJSONWithMalformedRepo = """
[
  {
    "number": 944,
    "title": "ok",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 99,
    "title": "broken",
    "url": "https://example.com/x",
    "state": "open",
    "isDraft": false,
    "author": { "login": "x" },
    "repository": { "nameWithOwner": "no-slash-here" }
  }
]
"""

@Test func searchPRsParsesResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")

    let hits = try await client.searchPRs(query: "review-requested:@me")

    #expect(hits.count == 2)
    #expect(hits[0].owner == "bsv-blockchain")
    #expect(hits[0].repo == "teranode")
    #expect(hits[0].number == 944)
    #expect(hits[0].title == "fix(asset/centrifuge): speak bidirectional Centrifuge protocol")
    #expect(hits[0].authorLogin == "icellan")
    #expect(hits[0].state == "open")
    #expect(hits[0].isDraft == false)
    #expect(hits[0].id == "bsv-blockchain/teranode#944")

    #expect(hits[1].owner == "foo")
    #expect(hits[1].repo == "bar")
    #expect(hits[1].isDraft == true)
    #expect(hits[1].authorLogin == "alice")

    let args = await runner.lastArguments
    #expect(args == ["search", "prs", "review-requested:@me", "--json", "number,title,url,state,isDraft,author,repository", "--limit", "100"])
}

@Test func searchPRsHandlesEmptyResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "assignee:@me")

    #expect(hits.isEmpty)
}

@Test func searchPRsThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "auth required"))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    await #expect(throws: GitHubError.self) {
        try await client.searchPRs(query: "review-requested:@me")
    }
}

@Test func searchPRsSkipsMalformedRepository() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSONWithMalformedRepo, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "x")

    #expect(hits.count == 1)
    #expect(hits.first?.owner == "bsv-blockchain")
    #expect(hits.first?.repo == "teranode")
}

@Test func searchPRsSplitsMultiQualifierQueryIntoSeparateArgs() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    _ = try await client.searchPRs(query: "review-requested:@me is:open")

    let args = await runner.lastArguments
    #expect(args == ["search", "prs", "review-requested:@me", "is:open", "--json", "number,title,url,state,isDraft,author,repository", "--limit", "100"])
}

@Test func mapDiscoveryStateNormalizesCasing() {
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: false) == .open)
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: true) == .draft)
    #expect(GitHubClient.mapDiscoveryState(state: "merged", isDraft: false) == .merged)
    #expect(GitHubClient.mapDiscoveryState(state: "closed", isDraft: false) == .closed)
    #expect(GitHubClient.mapDiscoveryState(state: "MERGED", isDraft: false) == .merged)
}
