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
    public var disabled: Bool
    public var viewedFiles: [String]

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
        closingIssueNumber: Int? = nil,
        disabled: Bool = false,
        viewedFiles: [String] = []
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
        self.disabled = disabled
        self.viewedFiles = viewedFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.owner = try container.decode(String.self, forKey: .owner)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.number = try container.decode(Int.self, forKey: .number)
        self.url = try container.decode(URL.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.author = try container.decode(String.self, forKey: .author)
        self.headBranch = try container.decode(String.self, forKey: .headBranch)
        self.baseBranch = try container.decode(String.self, forKey: .baseBranch)
        self.origin = try container.decode(ReviewOrigin.self, forKey: .origin)
        self.prState = try container.decode(PRState.self, forKey: .prState)
        self.worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.claudeFlags = try container.decodeIfPresent([String].self, forKey: .claudeFlags)
        self.addedAt = try container.decode(Date.self, forKey: .addedAt)
        self.lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        self.closingIssueNumber = try container.decodeIfPresent(Int.self, forKey: .closingIssueNumber)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.viewedFiles = try container.decodeIfPresent([String].self, forKey: .viewedFiles) ?? []
    }

    public static func makeID(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }
}
