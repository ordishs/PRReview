import Testing
import Foundation
import CommandSupport
import AppCore

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

private func remoteListing(_ entries: [(name: String, url: String)]) -> String {
    var lines: [String] = []
    for entry in entries {
        lines.append("\(entry.name)\t\(entry.url) (fetch)")
        lines.append("\(entry.name)\t\(entry.url) (push)")
    }
    return lines.joined(separator: "\n") + "\n"
}

@Test func validateSucceedsWhenOriginMatches() async throws {
    let stdout = remoteListing([(name: "origin", url: "https://github.com/bsv-blockchain/teranode.git")])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
}

@Test func validateSucceedsWhenForkOriginAndUpstreamMatches() async throws {
    let stdout = remoteListing([
        (name: "origin", url: "git@github.com:ordishs/teranode.git"),
        (name: "upstream", url: "https://github.com/bsv-blockchain/teranode.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
}

@Test func validateThrowsWhenNoRemoteMatches() async {
    let stdout = remoteListing([
        (name: "origin", url: "https://github.com/other-org/other-repo.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
    }
}

@Test func validateThrowsWhenNotAGitRepository() async {
    let runner = StubRunner(result: CommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: not a git repository"))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
    }
}

@Test func detectRepositoriesReturnsAllGitHubRemotes() async throws {
    let stdout = remoteListing([
        (name: "origin", url: "git@github.com:ordishs/teranode.git"),
        (name: "upstream", url: "https://github.com/bsv-blockchain/teranode.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    let identities = try await registrar.detectRepositories(at: "/some/path")
    #expect(identities.sorted() == ["bsv-blockchain/teranode", "ordishs/teranode"])
}

@Test func detectRepositoriesReturnsEmptyWhenNoGitHubRemotes() async throws {
    let stdout = remoteListing([
        (name: "origin", url: "git@gitlab.com:internal/repo.git"),
    ])
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: stdout, standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    let identities = try await registrar.detectRepositories(at: "/some/path")
    #expect(identities.isEmpty)
}

@Test func detectRepositoriesThrowsWhenNotAGitRepository() async {
    let runner = StubRunner(result: CommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: not a git repository"))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    await #expect(throws: RegistrationError.self) {
        _ = try await registrar.detectRepositories(at: "/some/path")
    }
}
