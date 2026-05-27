public enum DiffLineKind: String, Sendable, Equatable {
    case context
    case added
    case removed
}

public struct DiffLine: Sendable, Equatable {
    public var kind: DiffLineKind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffHunk: Sendable, Equatable {
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

public enum FileChangeKind: String, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
}

public struct DiffFile: Sendable, Equatable, Identifiable {
    public var oldPath: String?
    public var newPath: String?
    public var changeKind: FileChangeKind
    public var hunks: [DiffHunk]
    public var addedCount: Int
    public var removedCount: Int

    public var id: String { newPath ?? oldPath ?? "" }

    public init(oldPath: String?, newPath: String?, changeKind: FileChangeKind, hunks: [DiffHunk], addedCount: Int, removedCount: Int) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.changeKind = changeKind
        self.hunks = hunks
        self.addedCount = addedCount
        self.removedCount = removedCount
    }
}
