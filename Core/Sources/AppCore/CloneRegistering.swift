import Foundation
import CommandSupport

public enum RegistrationError: Error, Equatable {
    case notAGitRepository(message: String)
    case unrecognizedOrigin(url: String)
    case originMismatch(expected: String, actual: String)
}

public protocol CloneRegistering: Sendable {
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws
    func detectRepositories(at localPath: String) async throws -> [String]
}

public struct GitCloneRegistrar: CloneRegistering {
    private let runner: CommandRunner
    private let gitPath: String

    public init(runner: CommandRunner, gitPath: String) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        let entries = try await fetchRemoteEntries(localPath: localPath)
        let expected = "\(expectedOwner)/\(expectedRepo)".lowercased()
        var actualMatches: [String] = []
        for entry in entries {
            let actual = "\(entry.owner)/\(entry.repo)"
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

    public func detectRepositories(at localPath: String) async throws -> [String] {
        let entries = try await fetchRemoteEntries(localPath: localPath)
        var found: [String] = []
        for entry in entries {
            let identity = "\(entry.owner)/\(entry.repo)"
            if !found.contains(identity) {
                found.append(identity)
            }
        }
        return found
    }

    private func fetchRemoteEntries(localPath: String) async throws -> [(owner: String, repo: String)] {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", localPath, "remote", "-v"]
        )
        guard result.exitCode == 0 else {
            throw RegistrationError.notAGitRepository(message: result.standardError)
        }
        var entries: [(owner: String, repo: String)] = []
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let urlPart = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            if let (owner, repo) = GitOriginParser.parse(urlPart) {
                entries.append((owner: owner, repo: repo))
            }
        }
        return entries
    }
}
