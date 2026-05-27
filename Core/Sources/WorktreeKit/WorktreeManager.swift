import Foundation
import CommandSupport

public struct WorktreeManager: Sendable {
    private let runner: CommandRunner
    private let gitPath: String
    private let managedRoot: String

    public init(runner: CommandRunner, gitPath: String, managedRoot: String) {
        self.runner = runner
        self.gitPath = gitPath
        self.managedRoot = managedRoot
    }

    public func resolveClone(owner: String, repo: String, remoteURL: String, registeredClonePath: String?) async throws -> String {
        let fileManager = FileManager.default
        if let registeredClonePath, fileManager.fileExists(atPath: registeredClonePath) {
            return registeredClonePath
        }
        let reposDir = managedRoot + "/repos/" + owner
        let clonePath = reposDir + "/" + repo
        if fileManager.fileExists(atPath: clonePath) {
            return clonePath
        }
        try fileManager.createDirectory(atPath: reposDir, withIntermediateDirectories: true)
        try await runGit(["clone", remoteURL, clonePath])
        return clonePath
    }

    public func createWorktree(clonePath: String, owner: String, repo: String, number: Int) async throws -> String {
        try await runGit(["-C", clonePath, "fetch", "origin", "refs/pull/\(number)/head"])
        let sha = try await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreesDir = managedRoot + "/worktrees"
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-pr" + String(number)
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        try await runGit(["-C", clonePath, "worktree", "add", "--detach", worktreePath, sha])
        return worktreePath
    }

    public func mergeBase(worktreePath: String, baseRef: String) async throws -> String {
        try await runGit(["-C", worktreePath, "merge-base", "HEAD", baseRef]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func removeWorktree(clonePath: String, worktreePath: String) async throws {
        try await runGit(["-C", clonePath, "worktree", "remove", worktreePath])
    }

    @discardableResult
    private func runGit(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(executable: gitPath, arguments: arguments)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardError)
        }
        return result.standardOutput
    }
}
