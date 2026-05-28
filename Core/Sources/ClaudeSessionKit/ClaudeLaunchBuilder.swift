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
        let sessionName = "\(review.number) - \(review.author)"
        var args: [String] = []
        args.append(contentsOf: settings.claudeLaunchArgs)
        args.append("--name")
        args.append(sessionName)
        args.append("--effort")
        args.append("max")
        args.append("--dangerously-skip-permissions")
        args.append(contentsOf: review.claudeFlags ?? [])
        args.append("/review \(review.url.absoluteString)")
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args
        )
    }
}
