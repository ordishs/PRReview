import Testing
import Foundation
import CommandSupport
import AppCore

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

@Test func validateSucceedsWhenOriginMatches() async throws {
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "https://github.com/bsv-blockchain/teranode.git\n", standardError: ""))
    let registrar = GitCloneRegistrar(runner: runner, gitPath: "git")
    try await registrar.validate(localPath: "/some/path", expectedOwner: "bsv-blockchain", expectedRepo: "teranode")
}

@Test func validateThrowsOnOriginMismatch() async {
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "https://github.com/other-org/other-repo.git\n", standardError: ""))
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
