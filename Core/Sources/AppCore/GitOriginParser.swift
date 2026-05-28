import Foundation

public enum GitOriginParser {
    public static func parse(_ url: String) -> (owner: String, repo: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        if let range = withoutGit.range(of: "^https?://(www\\.)?github\\.com/", options: [.regularExpression, .caseInsensitive]) {
            return extract(from: String(withoutGit[range.upperBound...]))
        }
        if let range = withoutGit.range(of: "^git@github\\.com:", options: [.regularExpression, .caseInsensitive]) {
            return extract(from: String(withoutGit[range.upperBound...]))
        }
        return nil
    }

    private static func extract(from path: String) -> (owner: String, repo: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
