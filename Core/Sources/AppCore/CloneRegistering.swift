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
            arguments: ["-C", localPath, "remote", "get-url", "origin"]
        )
        guard result.exitCode == 0 else {
            throw RegistrationError.notAGitRepository(message: result.standardError)
        }
        let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (actualOwner, actualRepo) = GitOriginParser.parse(url) else {
            throw RegistrationError.unrecognizedOrigin(url: url)
        }
        let actual = "\(actualOwner)/\(actualRepo)".lowercased()
        let expected = "\(expectedOwner)/\(expectedRepo)".lowercased()
        guard actual == expected else {
            throw RegistrationError.originMismatch(expected: "\(expectedOwner)/\(expectedRepo)", actual: "\(actualOwner)/\(actualRepo)")
        }
    }
}
