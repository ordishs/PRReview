import Foundation

public struct Review: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var owner: String
    public var repo: String
    public var number: Int
    public var url: URL
    public var title: String
    public var author: String
    public var headBranch: String
    public var baseBranch: String
    public var origin: ReviewOrigin
    public var prState: PRState
    public var worktreePath: String?
    public var notes: String?
    public var claudeFlags: [String]?
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var closingIssueNumber: Int?

    public init(
        owner: String,
        repo: String,
        number: Int,
        url: URL,
        title: String,
        author: String,
        headBranch: String,
        baseBranch: String,
        origin: ReviewOrigin,
        prState: PRState,
        worktreePath: String? = nil,
        notes: String? = nil,
        claudeFlags: [String]? = nil,
        addedAt: Date,
        lastOpenedAt: Date? = nil,
        closingIssueNumber: Int? = nil
    ) {
        self.id = Review.makeID(owner: owner, repo: repo, number: number)
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.origin = origin
        self.prState = prState
        self.worktreePath = worktreePath
        self.notes = notes
        self.claudeFlags = claudeFlags
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.closingIssueNumber = closingIssueNumber
    }

    public static func makeID(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }
}
