public enum DiffParser {
    public static func parse(_ unifiedDiff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var oldNumber = 0
        var newNumber = 0

        func flush() {
            if let file = current {
                files.append(file)
            }
            current = nil
        }

        let lines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                current = DiffFile(oldPath: nil, newPath: nil, changeKind: .modified, hunks: [], addedCount: 0, removedCount: 0)
                continue
            }
            guard var file = current else { continue }

            if line.hasPrefix("@@") {
                let (oldStart, newStart) = Self.hunkStarts(line)
                oldNumber = oldStart
                newNumber = newStart
                file.hunks.append(DiffHunk(header: line, lines: []))
            } else if file.hunks.isEmpty {
                if line.hasPrefix("new file mode") {
                    file.changeKind = .added
                } else if line.hasPrefix("deleted file mode") {
                    file.changeKind = .deleted
                } else if line.hasPrefix("rename from ") {
                    file.oldPath = String(line.dropFirst("rename from ".count))
                    file.changeKind = .renamed
                } else if line.hasPrefix("rename to ") {
                    file.newPath = String(line.dropFirst("rename to ".count))
                    file.changeKind = .renamed
                } else if line.hasPrefix("--- ") {
                    file.oldPath = Self.path(from: line, prefix: "--- ")
                } else if line.hasPrefix("+++ ") {
                    file.newPath = Self.path(from: line, prefix: "+++ ")
                }
            } else {
                let hunkIndex = file.hunks.count - 1
                if line.hasPrefix("+") {
                    file.hunks[hunkIndex].lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: String(line.dropFirst())))
                    newNumber += 1
                    file.addedCount += 1
                } else if line.hasPrefix("-") {
                    file.hunks[hunkIndex].lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: String(line.dropFirst())))
                    oldNumber += 1
                    file.removedCount += 1
                } else if line.hasPrefix(" ") {
                    file.hunks[hunkIndex].lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: String(line.dropFirst())))
                    oldNumber += 1
                    newNumber += 1
                }
            }
            current = file
        }
        flush()
        return files
    }

    private static func path(from line: String, prefix: String) -> String? {
        let value = String(line.dropFirst(prefix.count))
        if value == "/dev/null" {
            return nil
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            return String(value.dropFirst(2))
        }
        return value
    }

    private static func hunkStarts(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        let oldStart = parts[1].hasPrefix("-")
            ? Int(parts[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
            : 0
        let newStart = parts[2].hasPrefix("+")
            ? Int(parts[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
            : 0
        return (oldStart, newStart)
    }
}
