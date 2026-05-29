import Foundation

public enum LoginShellResolver {
    public static func resolve(
        _ name: String,
        runner: CommandRunner,
        fileManager: FileManager = .default
    ) async -> String? {
        let result = try? await runner.run(
            executable: "/bin/zsh",
            arguments: ["-i", "-l", "-c", "command -v \(name)"]
        )

        guard let result, result.exitCode == 0, let path = parse(result.standardOutput) else {
            return nil
        }

        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    static func parse(_ output: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix("/") }
    }
}
