import Testing
import Foundation
import CommandSupport
import DiffKit

private let gitPath = "/opt/homebrew/bin/git"

@discardableResult
private func git(_ arguments: [String]) async throws -> String {
    let result = try await ProcessCommandRunner().run(executable: gitPath, arguments: arguments)
    guard result.exitCode == 0 else {
        throw NSError(domain: "git-fixture", code: Int(result.exitCode), userInfo: [
            NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.standardError)"
        ])
    }
    return result.standardOutput
}

@Test func diffServiceParsesGitDiffBetweenCommits() async throws {
    let fileManager = FileManager.default
    let repo = fileManager.temporaryDirectory.appendingPathComponent("diff-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: repo, withIntermediateDirectories: true)

    try await git(["init", "-b", "main", repo])
    try await git(["-C", repo, "config", "user.email", "test@example.com"])
    try await git(["-C", repo, "config", "user.name", "Test User"])
    try await git(["-C", repo, "config", "commit.gpgsign", "false"])
    try "alpha\nbeta\ngamma\n".write(toFile: repo + "/foo.txt", atomically: true, encoding: .utf8)
    try await git(["-C", repo, "add", "."])
    try await git(["-C", repo, "commit", "-m", "base"])
    let baseSha = try await git(["-C", repo, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    try "alpha\nBETA\ngamma\n".write(toFile: repo + "/foo.txt", atomically: true, encoding: .utf8)
    try await git(["-C", repo, "add", "."])
    try await git(["-C", repo, "commit", "-m", "change"])

    let service = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
    let files = try await service.diff(worktreePath: repo, baseRef: baseSha)

    #expect(files.count == 1)
    #expect(files[0].newPath == "foo.txt")
    #expect(files[0].changeKind == .modified)
    #expect(files[0].addedCount == 1)
    #expect(files[0].removedCount == 1)
}

@Test func diffServiceThrowsOnGitFailure() async {
    let service = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
    await #expect(throws: DiffError.self) {
        _ = try await service.diff(worktreePath: "/nonexistent/repo/path", baseRef: "HEAD")
    }
}
