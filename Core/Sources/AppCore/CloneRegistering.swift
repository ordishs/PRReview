import Foundation
import CommandSupport

public enum RegistrationError: Error, Equatable {
    case notAGitRepository(message: String)
    case unrecognizedOrigin(url: String)
    case originMismatch(expected: String, actual: String)
}

public protocol CloneRegistering: Sendable {
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws
}

public struct GitCloneRegistrar: CloneRegistering {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", localPath, "remote", "-v"]
        )
        guard result.exitCode == 0 else {
            throw RegistrationError.notAGitRepository(message: result.standardError)
        }
        let expected = "\(expectedOwner)/\(expectedRepo)".lowercased()
        var actualMatches: [String] = []
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let urlPart = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            guard let (owner, repo) = GitOriginParser.parse(urlPart) else { continue }
            let actual = "\(owner)/\(repo)"
            if actual.lowercased() == expected {
                return
            }
            if !actualMatches.contains(actual) {
                actualMatches.append(actual)
            }
        }
        let actualList = actualMatches.isEmpty ? "no github remotes" : actualMatches.joined(separator: ", ")
        throw RegistrationError.originMismatch(expected: "\(expectedOwner)/\(expectedRepo)", actual: actualList)
    }
}
