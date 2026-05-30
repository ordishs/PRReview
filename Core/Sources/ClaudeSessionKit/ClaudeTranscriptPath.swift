import Foundation

public enum ClaudeTranscriptPath {
    public static func directoryURL(forWorktreePath path: String) -> URL {
        let encoded = path.replacingOccurrences(of: "/", with: "-")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".claude/projects/\(encoded)")
    }

    public static func latestSessionID(forWorktreePath path: String) -> String? {
        latestSessionID(in: directoryURL(forWorktreePath: path))
    }

    public static func transcriptURL(sessionID: String, worktreePath: String) -> URL {
        directoryURL(forWorktreePath: worktreePath).appendingPathComponent("\(sessionID).jsonl")
    }

    public static func transcriptExists(sessionID: String, worktreePath: String) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(sessionID: sessionID, worktreePath: worktreePath).path)
    }

    public static func latestSessionID(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let jsonl = entries.filter { $0.pathExtension == "jsonl" }
        guard !jsonl.isEmpty else { return nil }
        let withDates: [(URL, Date)] = jsonl.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }
        guard let newest = withDates.max(by: { $0.1 < $1.1 }) else { return nil }
        return newest.0.deletingPathExtension().lastPathComponent
    }
}
