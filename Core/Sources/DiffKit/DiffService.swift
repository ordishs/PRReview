import CommandSupport

public struct DiffService: Sendable {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func diff(worktreePath: String, baseRef: String) async throws -> [DiffFile] {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "diff", baseRef, "HEAD"]
        )
        guard result.exitCode == 0 else {
            throw DiffError.gitFailed(exitCode: result.exitCode, message: result.standardError)
        }
        return DiffParser.parse(result.standardOutput)
    }
}
