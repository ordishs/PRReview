import Testing
import Foundation
import CommandSupport
import WorktreeKit

private let gitPath = "/opt/homebrew/bin/git"

private struct GitFixture {
    let root: String
    let remoteURL: String
    let managedRoot: String
    let baseSha: String
    let prHeadSha: String
}

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

private func makeFixture(prNumber: Int) async throws -> GitFixture {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    let bare = root + "/remote.git"
    let work = root + "/work"

    try await git(["init", "--bare", "-b", "main", bare])
    try await git(["clone", bare, work])
    try await git(["-C", work, "config", "user.email", "test@example.com"])
    try await git(["-C", work, "config", "user.name", "Test User"])
    try await git(["-C", work, "config", "commit.gpgsign", "false"])

    try "base\n".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "base"])
    try await git(["-C", work, "branch", "-M", "main"])
    try await git(["-C", work, "push", "origin", "main"])
    let baseSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    try await git(["-C", work, "checkout", "-b", "pr-branch"])
    try "feature\n".write(toFile: work + "/feature.txt", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "feature"])
    let prHeadSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try await git(["-C", work, "push", "origin", "pr-branch"])
    try await git(["-C", bare, "update-ref", "refs/pull/\(prNumber)/head", prHeadSha])

    return GitFixture(root: root, remoteURL: bare, managedRoot: root + "/managed", baseSha: baseSha, prHeadSha: prHeadSha)
}

@Test func resolveCloneUsesRegisteredPathWhenItExists() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let registered = fixture.root + "/work"
    let resolved = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: registered)
    #expect(resolved == registered)
}

@Test func resolveCloneAutoClonesIntoManagedDir() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let resolved = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    #expect(resolved == fixture.managedRoot + "/repos/bsv-blockchain/teranode")
    #expect(FileManager.default.fileExists(atPath: resolved + "/.git"))
}

@Test func resolveCloneFallsBackToManagedWhenRegisteredPathMissing() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let missing = fixture.root + "/does-not-exist"
    let resolved = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: missing)
    #expect(resolved == fixture.managedRoot + "/repos/bsv-blockchain/teranode")
    #expect(FileManager.default.fileExists(atPath: resolved + "/.git"))
}

@Test func createWorktreeChecksOutPRHead() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "bsv-blockchain", repo: "teranode", number: 944)

    #expect(worktree == fixture.managedRoot + "/worktrees/bsv-blockchain-teranode-pr944")
    #expect(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
    let head = try await git(["-C", worktree, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(head == fixture.prHeadSha)
}

@Test func mergeBaseReturnsBaseCommit() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    let base = try await manager.mergeBase(worktreePath: worktree, baseRef: "origin/main")
    #expect(base == fixture.baseSha)
}

@Test func removeWorktreeDeletesIt() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    #expect(FileManager.default.fileExists(atPath: worktree))
    try await manager.removeWorktree(clonePath: clone, worktreePath: worktree)
    #expect(!FileManager.default.fileExists(atPath: worktree))
}
