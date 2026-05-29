import Testing
import Foundation
@testable import CommandSupport

@Test func parsePicksAbsolutePathIgnoringBannerNoise() {
    let output = "✓ Git worktree helpers loaded. Type 'ghelp' for usage.\n/Users/me/.local/bin/claude\n"
    #expect(LoginShellResolver.parse(output) == "/Users/me/.local/bin/claude")
}

@Test func parseHandlesPlainPathOnly() {
    #expect(LoginShellResolver.parse("/opt/homebrew/bin/claude\n") == "/opt/homebrew/bin/claude")
}

@Test func parseTrimsWhitespaceAndTakesLastAbsolutePath() {
    let output = "  /first/path  \nnoise line\n  /usr/local/bin/claude \n"
    #expect(LoginShellResolver.parse(output) == "/usr/local/bin/claude")
}

@Test func parseReturnsNilWhenNoAbsolutePathPresent() {
    #expect(LoginShellResolver.parse("✓ banner only\nclaude not found\n") == nil)
}

@Test func parseReturnsNilForEmptyOutput() {
    #expect(LoginShellResolver.parse("") == nil)
}

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(_ result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

@Test func resolveReturnsExecutablePathFromOutput() async {
    let runner = StubRunner(CommandResult(exitCode: 0, standardOutput: "banner\n/usr/bin/true\n", standardError: ""))
    #expect(await LoginShellResolver.resolve("claude", runner: runner) == "/usr/bin/true")
}

@Test func resolveReturnsNilOnNonZeroExit() async {
    let runner = StubRunner(CommandResult(exitCode: 1, standardOutput: "", standardError: "not found"))
    #expect(await LoginShellResolver.resolve("claude", runner: runner) == nil)
}

@Test func resolveReturnsNilWhenResolvedPathIsNotExecutable() async {
    let runner = StubRunner(CommandResult(exitCode: 0, standardOutput: "/nonexistent/claude\n", standardError: ""))
    #expect(await LoginShellResolver.resolve("claude", runner: runner) == nil)
}
