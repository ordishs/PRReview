import Testing
import Foundation
import CommandSupport

@Test func processRunnerCapturesStdoutAndZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/bin/echo", arguments: ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "hello\n")
}

@Test func processRunnerReportsNonZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/usr/bin/false", arguments: [])
    #expect(result.exitCode == 1)
}
