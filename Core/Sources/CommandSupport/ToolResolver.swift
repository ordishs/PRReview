import Foundation

public enum ToolResolver {
    public static func resolve(_ name: String, candidates: [String]? = nil, fileManager: FileManager = .default) -> String? {
        let paths = candidates ?? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
