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
