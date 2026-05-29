import Testing
import Foundation
import DiffKit
@testable import AppCore

private func file(_ path: String, added: Int = 0, removed: Int = 0) -> DiffFile {
    DiffFile(
        oldPath: path,
        newPath: path,
        changeKind: .modified,
        hunks: [],
        addedCount: added,
        removedCount: removed
    )
}

@Test func fileTreeBuilderEmptyInput() {
    let root = FileTreeBuilder.build(files: [])
    #expect(root.children.isEmpty)
    #expect(root.addedCount == 0)
    #expect(root.removedCount == 0)
}

@Test func fileTreeBuilderSingleFileAtRoot() {
    let root = FileTreeBuilder.build(files: [file("README.md", added: 3, removed: 1)])
    #expect(root.children.count == 1)
    let leaf = root.children[0]
    #expect(leaf.name == "README.md")
    #expect(leaf.isLeaf == true)
    #expect(leaf.addedCount == 3)
    #expect(leaf.removedCount == 1)
    #expect(leaf.fileID == "README.md")
}

@Test func fileTreeBuilderGroupsByDirectory() {
    let root = FileTreeBuilder.build(files: [
        file("App/View.swift", added: 5, removed: 2),
        file("App/Model.swift", added: 1, removed: 0),
        file("Core/Foo.swift", added: 10, removed: 0)
    ])
    #expect(root.children.count == 2)
    let appNode = root.children.first { $0.name == "App" }!
    #expect(appNode.isLeaf == false)
    #expect(appNode.children.count == 2)
    #expect(appNode.children.allSatisfy { $0.isLeaf })
    let coreNode = root.children.first { $0.name == "Core" }!
    #expect(coreNode.children.count == 1)
}

@Test func fileTreeBuilderAggregatesStatsAtFolders() {
    let root = FileTreeBuilder.build(files: [
        file("App/View.swift", added: 5, removed: 2),
        file("App/Model.swift", added: 1, removed: 4)
    ])
    let appNode = root.children.first { $0.name == "App" }!
    #expect(appNode.addedCount == 6)
    #expect(appNode.removedCount == 6)
    #expect(root.addedCount == 6)
    #expect(root.removedCount == 6)
}

@Test func fileTreeBuilderSortsChildren() {
    let root = FileTreeBuilder.build(files: [
        file("zz/last.swift"),
        file("aa/first.swift"),
        file("README.md")
    ])
    let names = root.children.map(\.name)
    #expect(names == ["aa", "zz", "README.md"])
}

@Test func fileTreeBuilderHandlesDeepNesting() {
    let root = FileTreeBuilder.build(files: [
        file("a/b/c/d/leaf.txt", added: 2, removed: 1)
    ])
    var node = root
    for component in ["a", "b", "c", "d"] {
        #expect(node.children.count == 1)
        node = node.children[0]
        #expect(node.name == component)
    }
    #expect(node.children.count == 1)
    #expect(node.children[0].name == "leaf.txt")
    #expect(node.children[0].isLeaf)
    #expect(root.addedCount == 2)
}
