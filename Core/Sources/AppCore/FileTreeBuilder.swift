import Foundation
import DiffKit

public struct FileTreeNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let fileID: String?
    public var addedCount: Int
    public var removedCount: Int
    public var children: [FileTreeNode]

    public var isLeaf: Bool { fileID != nil }

    public init(id: String, name: String, fileID: String?, addedCount: Int, removedCount: Int, children: [FileTreeNode]) {
        self.id = id
        self.name = name
        self.fileID = fileID
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.children = children
    }
}

public enum FileTreeBuilder {
    public static func build(files: [DiffFile]) -> FileTreeNode {
        var root = MutableNode(name: "", path: "")
        for file in files {
            let path = file.newPath ?? file.oldPath ?? ""
            guard !path.isEmpty else { continue }
            let parts = path.split(separator: "/").map(String.init)
            insert(parts: parts, file: file, into: &root, pathSoFar: "")
        }
        aggregate(&root)
        sort(&root)
        return root.toNode()
    }

    private static func insert(parts: [String], file: DiffFile, into node: inout MutableNode, pathSoFar: String) {
        guard let head = parts.first else { return }
        let nextPath = pathSoFar.isEmpty ? head : pathSoFar + "/" + head
        let tail = Array(parts.dropFirst())
        if tail.isEmpty {
            node.children.append(MutableNode(
                name: head,
                path: nextPath,
                isLeaf: true,
                fileID: file.id,
                addedCount: file.addedCount,
                removedCount: file.removedCount
            ))
            return
        }
        if let existingIndex = node.children.firstIndex(where: { !$0.isLeaf && $0.name == head }) {
            insert(parts: tail, file: file, into: &node.children[existingIndex], pathSoFar: nextPath)
        } else {
            var child = MutableNode(name: head, path: nextPath)
            insert(parts: tail, file: file, into: &child, pathSoFar: nextPath)
            node.children.append(child)
        }
    }

    private static func aggregate(_ node: inout MutableNode) {
        if node.isLeaf { return }
        var added = 0
        var removed = 0
        for index in node.children.indices {
            aggregate(&node.children[index])
            added += node.children[index].addedCount
            removed += node.children[index].removedCount
        }
        node.addedCount = added
        node.removedCount = removed
    }

    private static func sort(_ node: inout MutableNode) {
        node.children.sort { lhs, rhs in
            if lhs.isLeaf != rhs.isLeaf {
                return !lhs.isLeaf
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        for index in node.children.indices {
            sort(&node.children[index])
        }
    }
}

private struct MutableNode {
    var name: String
    var path: String
    var isLeaf: Bool = false
    var fileID: String? = nil
    var addedCount: Int = 0
    var removedCount: Int = 0
    var children: [MutableNode] = []

    func toNode() -> FileTreeNode {
        FileTreeNode(
            id: "node:" + (path.isEmpty ? "/" : path),
            name: name,
            fileID: fileID,
            addedCount: addedCount,
            removedCount: removedCount,
            children: children.map { $0.toNode() }
        )
    }
}
