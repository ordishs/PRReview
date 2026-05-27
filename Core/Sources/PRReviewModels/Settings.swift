import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var managedRoot: String
    public var discoveryQueries: [String]
    public var pollIntervalSeconds: Int
    public var ghPath: String?
    public var gitPath: String?
    public var claudePath: String?
    public var claudeLaunchArgs: [String]
    public var notificationsEnabled: Bool
    public var diffMode: DiffMode
    public var diffIgnoreWhitespace: Bool

    public init(
        managedRoot: String,
        discoveryQueries: [String],
        pollIntervalSeconds: Int,
        ghPath: String? = nil,
        gitPath: String? = nil,
        claudePath: String? = nil,
        claudeLaunchArgs: [String],
        notificationsEnabled: Bool,
        diffMode: DiffMode,
        diffIgnoreWhitespace: Bool
    ) {
        self.managedRoot = managedRoot
        self.discoveryQueries = discoveryQueries
        self.pollIntervalSeconds = pollIntervalSeconds
        self.ghPath = ghPath
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.claudeLaunchArgs = claudeLaunchArgs
        self.notificationsEnabled = notificationsEnabled
        self.diffMode = diffMode
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
    }

    public static let `default` = Settings(
        managedRoot: Settings.defaultManagedRoot(),
        discoveryQueries: ["review-requested:@me", "assignee:@me"],
        pollIntervalSeconds: 120,
        claudeLaunchArgs: [],
        notificationsEnabled: true,
        diffMode: .unified,
        diffIgnoreWhitespace: false
    )

    public static func defaultManagedRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PRReview", isDirectory: true).path
    }
}
