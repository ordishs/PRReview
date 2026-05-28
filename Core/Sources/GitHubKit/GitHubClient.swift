import Foundation
import PRReviewModels
import CommandSupport

public struct GitHubClient: Sendable {
    private let runner: CommandRunner
    private let ghPath: String

    public init(runner: CommandRunner, ghPath: String) {
        self.runner = runner
        self.ghPath = ghPath
    }

    public func fetchReview(for ref: PRRef, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> Review {
        let fields = "number,title,url,state,isDraft,author,headRefName,baseRefName,closingIssuesReferences"
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
        let closingIssueNumber = pullRequest.closingIssuesReferences.first?.number
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
            addedAt: now,
            closingIssueNumber: closingIssueNumber
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

    struct ClosingIssueRef: Decodable {
        let number: Int
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, state, isDraft, author, headRefName, baseRefName, closingIssuesReferences
    }

    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: Author
    let headRefName: String
    let baseRefName: String
    let closingIssuesReferences: [ClosingIssueRef]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        state = try container.decode(String.self, forKey: .state)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        author = try container.decode(Author.self, forKey: .author)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        closingIssuesReferences = try container.decodeIfPresent([ClosingIssueRef].self, forKey: .closingIssuesReferences) ?? []
    }
}
