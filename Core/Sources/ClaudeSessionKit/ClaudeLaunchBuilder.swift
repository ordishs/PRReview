import Foundation
import PRReviewModels

public struct ClaudeLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]

    public init(executable: String, cwd: String, arguments: [String]) {
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
    }
}

public enum ClaudeLaunchBuilder {
    public static func build(
        settings: Settings,
        review: Review,
        worktreePath: String,
        resolvedClaudePath: String
    ) -> ClaudeLaunchSpec {
        let args = settings.claudeLaunchArgs
            + (review.claudeFlags ?? [])
            + ["--continue"]
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args
        )
    }
}
