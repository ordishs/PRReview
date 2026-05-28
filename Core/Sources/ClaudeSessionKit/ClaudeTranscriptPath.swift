import Foundation

public enum ClaudeTranscriptPath {
    public static func directoryURL(forWorktreePath path: String) -> URL {
        let encoded = path.replacingOccurrences(of: "/", with: "-")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".claude/projects/\(encoded)")
    }
}
