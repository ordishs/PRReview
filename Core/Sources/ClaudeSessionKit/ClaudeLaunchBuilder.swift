import Foundation
import PRReviewModels

public struct ClaudeLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]
    public let environment: String

    public init(executable: String, cwd: String, arguments: [String], environment: String = "") {
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
        self.environment = environment
    }
}

public enum ClaudeLaunchBuilder {
    public static func build(
        settings: Settings,
        review: Review,
        worktreePath: String,
        resolvedClaudePath: String,
        sessionID: String,
        resume: Bool
    ) -> ClaudeLaunchSpec {
        var args: [String] = []
        args.append(contentsOf: settings.claudeLaunchArgs)
        args.append(contentsOf: review.claudeFlags ?? [])
        if resume {
            args.append("--resume")
            args.append(sessionID)
        } else {
            args.append("--session-id")
            args.append(sessionID)
            args.append("/review \(review.url.absoluteString)")
        }
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args,
            environment: settings.claudeEnv
        )
    }
}
