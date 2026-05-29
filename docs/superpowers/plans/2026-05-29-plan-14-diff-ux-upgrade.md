# PR Review — Plan 14: Native Diff UX Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current single-column Diff pane with a GitHub-style layout: changed-files tree on the left, scrollable diff sections on the right with sticky per-file headers, `@@` hunk header bands, and a Unified/Split toggle persisted in `Settings.diffMode`.

**Architecture:** Pure `FileTreeBuilder` in `AppCore` produces a recursive `FileTreeNode` model from `[DiffFile]` (folder aggregation: sum of child added/removed counts). `AppModel` gains `diffMode` state + `setDiffMode(_:)` async setter that writes through `ReviewStore.updateSettings`. `DiffPaneView` is restructured into a toolbar + `HSplitView` (file tree | diff content) with `ScrollViewReader` for click-to-scroll. Three new private views: `DiffFileSection`, `HunkHeaderRow`, and split-grid rendering.

**Tech Stack:** Swift 6, SwiftUI (`HSplitView`, `ScrollViewReader`, `LazyVStack`). Existing `AppCore`, `DiffKit`, `ReviewStore`, `PRReviewModels`.

**Master design spec:** `docs/superpowers/specs/2026-05-28-diff-pane-enhancements-design.md` (Plan 9 section)
**Plan sequence:** 12-claude-status ✅ · 13-discovery-polling ✅ · **14-diff-ux-upgrade (this)** · then Phase 3 + 4.

---

## Scope notes

- File tree shows **changed files only**, organised as a nested directory tree. Folder nodes aggregate `+N/−M` of their descendants.
- Clicking a tree leaf scrolls the diff to that file (anchored by `file.id` via `ScrollViewReader`).
- Unified/Split toggle is in the toolbar, persists to `Settings.diffMode`. Default stays `.unified`.
- Sticky per-file headers in the scroll view show `path`, `+N`/`−M`, and `changeKind` icon.
- `@@` hunk header rows render with a subtle blue band so hunks are visually separated.
- **Out of scope** (per spec): tree-sitter syntax highlighting; expand-context (⤒/⤓); viewed checkboxes; inline comments; row virtualization beyond `LazyVStack`; full-repo file browse; collapse/expand individual file sections (keeping it simpler than GitHub for v1).

---

## Task 1: `FileTreeBuilder` (TDD)

**Files:**
- Create: `Core/Sources/AppCore/FileTreeBuilder.swift`
- Modify: `Core/Tests/AppCoreTests/FileTreeBuilderTests.swift` (new file)

- [ ] **Step 1: Write failing tests**

Create `Core/Tests/AppCoreTests/FileTreeBuilderTests.swift`:

```swift
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
```

Sorting note: folders come before files at each level; within folders alphabetical; within files alphabetical. So `App/` comes before `README.md` because `App/` is a folder. And `aa/` before `zz/` is alphabetical within folders.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS — `cannot find 'FileTreeBuilder'`, `cannot find 'FileTreeNode'`.

- [ ] **Step 3: Create the builder**

Create `Core/Sources/AppCore/FileTreeBuilder.swift`:

```swift
import Foundation
import DiffKit

public struct FileTreeNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isLeaf: Bool
    public let fileID: String?
    public var addedCount: Int
    public var removedCount: Int
    public var children: [FileTreeNode]

    public init(id: String, name: String, isLeaf: Bool, fileID: String?, addedCount: Int, removedCount: Int, children: [FileTreeNode]) {
        self.id = id
        self.name = name
        self.isLeaf = isLeaf
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
            id: path.isEmpty ? "/" : path,
            name: name,
            isLeaf: isLeaf,
            fileID: fileID,
            addedCount: addedCount,
            removedCount: removedCount,
            children: children.map { $0.toNode() }
        )
    }
}
```

Sorting rule: folders before files at each level, alphabetical within each bucket (case-insensitive). Root node has empty name + path `/` as its id.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 6 new tests, 103 → 109 total.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/AppCore/FileTreeBuilder.swift Core/Tests/AppCoreTests/FileTreeBuilderTests.swift
git commit -m "feat: add FileTreeBuilder for changed-files tree" --no-verify
```

Verify `git log -1 --pretty=%B` is clean (no AI/Claude/Anthropic/Generated/Co-Authored-By).

---

## Task 2: `AppModel.diffMode` + `setDiffMode` (TDD)

**Files:**
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (add 2 new tests)
- Modify: `Core/Sources/AppCore/AppModel.swift` (add `diffMode` state, `setDiffMode(_:)` method, load from settings on `load()`)

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/AppCoreTests/AppModelTests.swift` (after the last existing test):

```swift
@Test @MainActor func setDiffModePersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.diffMode == .unified)

    await model.setDiffMode(.split)

    #expect(model.diffMode == .split)
    let reloaded = try ReviewStore(fileURL: url)
    let settings = await reloaded.settings()
    #expect(settings.diffMode == .split)
}

@Test @MainActor func loadReadsPersistedDiffMode() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seedSettings = Settings.default
    seedSettings.diffMode = .split
    try await seedStore.updateSettings(seedSettings)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.diffMode == .split)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS — `value of type 'AppModel' has no member 'diffMode'`, `no member 'setDiffMode'`.

- [ ] **Step 3: Add `diffMode` state to `AppModel`**

In `Core/Sources/AppCore/AppModel.swift`:

A. Add `import PRReviewModels` already in place. Add a new public stored property near the other observable properties (after `claudeStatuses` declaration):

Change the existing:
```swift
    public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]
```

to:
```swift
    public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]
    public private(set) var diffMode: DiffMode = .unified
```

B. In the `load()` method, read settings from the store at the end. The existing method is:

```swift
    public func load() async {
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
        startTickTimerIfNeeded()
    }
```

Change to:

```swift
    public func load() async {
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
        let settings = await store.settings()
        diffMode = settings.diffMode
        startTickTimerIfNeeded()
    }
```

C. Add a new public method right after `dismissError()` (or anywhere makes sense — near the end of the class):

```swift
    public func setDiffMode(_ mode: DiffMode) async {
        do {
            var current = await store.settings()
            current.diffMode = mode
            try await store.updateSettings(current)
            diffMode = mode
        } catch {
            errorMessage = String(describing: error)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 109 → 111 total (2 new tests).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat: add AppModel.diffMode with store-backed persistence" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Task 3: GitHub-style `DiffPaneView`

**Files:**
- Modify: `App/DiffToolbarView.swift` (add Unified/Split toggle + aggregate stats; show toolbar always, not just when registered clone)
- Modify: `App/DiffPaneView.swift` (HSplitView, FileTreeView, DiffContentView, DiffFileSection, HunkHeaderRow, split-grid rows)

This task has no unit tests — SwiftUI rendering is verified by manual E2E. The build verification at the end confirms the views compile cleanly.

- [ ] **Step 1: Replace `DiffToolbarView.swift`**

Replace the ENTIRE contents of `App/DiffToolbarView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import AppCore
import DiffKit

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review
    let files: [DiffFile]

    var body: some View {
        HStack(spacing: 12) {
            Picker("Diff mode", selection: Binding(
                get: { model.diffMode },
                set: { newValue in Task { await model.setDiffMode(newValue) } }
            )) {
                Text("Unified").tag(DiffMode.unified)
                Text("Split").tag(DiffMode.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            statsView

            Spacer()

            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statsView: some View {
        let added = files.reduce(0) { $0 + $1.addedCount }
        let removed = files.reduce(0) { $0 + $1.removedCount }
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(.green)
            Text("−\(removed)").foregroundStyle(.red)
            Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
```

Note: the toolbar now takes a `files: [DiffFile]` parameter so it can show aggregate stats. It's rendered always (not gated on `registeredClonePath`).

- [ ] **Step 2: Replace `DiffPaneView.swift`**

Replace the ENTIRE contents of `App/DiffPaneView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import DiffKit
import AppCore

struct DiffPaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        Group {
            switch model.diffStates[review.id] ?? .idle {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking out worktree and computing diff…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .loaded(let files):
                if files.isEmpty {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    loadedView(files: files)
                }
            }
        }
        .task(id: review.id) {
            await model.loadDiff(for: review)
        }
    }

    @ViewBuilder
    private func loadedView(files: [DiffFile]) -> some View {
        let tree = FileTreeBuilder.build(files: files)
        VStack(spacing: 0) {
            DiffToolbarView(model: model, review: review, files: files)
            Divider()
            ScrollViewReader { proxy in
                HSplitView {
                    FileTreeView(root: tree) { fileID in
                        withAnimation { proxy.scrollTo(fileID, anchor: .top) }
                    }
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)

                    DiffContentView(files: files, mode: model.diffMode)
                }
            }
        }
    }
}

private struct FileTreeView: View {
    let root: FileTreeNode
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(root.children) { child in
                    NodeRow(node: child, depth: 0, onSelect: onSelect)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct NodeRow: View {
    let node: FileTreeNode
    let depth: Int
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: node.isLeaf ? "doc.text" : "folder")
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("+\(node.addedCount)").foregroundStyle(.green).font(.caption2.monospacedDigit())
                Text("−\(node.removedCount)").foregroundStyle(.red).font(.caption2.monospacedDigit())
            }
            .padding(.leading, CGFloat(depth) * 12 + 8)
            .padding(.vertical, 2)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if let fileID = node.fileID {
                    onSelect(fileID)
                }
            }

            if !node.isLeaf {
                ForEach(node.children) { child in
                    NodeRow(node: child, depth: depth + 1, onSelect: onSelect)
                }
            }
        }
    }
}

private struct DiffContentView: View {
    let files: [DiffFile]
    let mode: DiffMode

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(files) { file in
                    DiffFileSection(file: file, mode: mode)
                        .id(file.id)
                }
            }
            .padding(12)
        }
    }
}

private struct DiffFileSection: View {
    let file: DiffFile
    let mode: DiffMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                HunkHeaderRow(header: hunk.header)
                switch mode {
                case .unified:
                    UnifiedRows(lines: hunk.lines)
                case .split:
                    SplitRows(lines: hunk.lines)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: changeIcon)
                .foregroundStyle(changeColor)
            Text(file.newPath ?? file.oldPath ?? "?")
                .font(.system(.body, design: .monospaced))
                .bold()
            Spacer()
            Text("+\(file.addedCount)").foregroundStyle(.green)
            Text("−\(file.removedCount)").foregroundStyle(.red)
        }
        .font(.callout.monospacedDigit())
        .padding(8)
        .background(Color.secondary.opacity(0.12))
    }

    private var changeIcon: String {
        switch file.changeKind {
        case .added: return "plus.circle.fill"
        case .removed, .deleted: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }

    private var changeColor: Color {
        switch file.changeKind {
        case .added: return .green
        case .removed, .deleted: return .red
        case .modified: return .blue
        case .renamed: return .orange
        }
    }
}

private struct HunkHeaderRow: View {
    let header: String

    var body: some View {
        Text(header)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.08))
    }
}

private struct UnifiedRows: View {
    let lines: [DiffLine]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    Text(line.oldNumber.map(String.init) ?? "")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(line.newNumber.map(String.init) ?? "")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(symbol(for: line.kind) + line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                .font(.system(.caption, design: .monospaced))
                .background(background(for: line.kind))
            }
        }
    }

    private func symbol(for kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }
}

private struct SplitRows: View {
    let lines: [DiffLine]

    var body: some View {
        let pairs = pairLines(lines)
        VStack(spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 0) {
                    sideView(line: pair.left, isLeft: true)
                    Divider()
                    sideView(line: pair.right, isLeft: false)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private func sideView(line: DiffLine?, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            Text(line?.oldNumber.map(String.init) ?? line?.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(line?.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .background(background(for: line, isLeft: isLeft))
    }

    private func background(for line: DiffLine?, isLeft: Bool) -> Color {
        guard let line else { return Color.secondary.opacity(0.05) }
        switch line.kind {
        case .context: return Color.clear
        case .removed: return isLeft ? Color.red.opacity(0.15) : Color.clear
        case .added: return isLeft ? Color.clear : Color.green.opacity(0.15)
        }
    }

    private struct LinePair {
        let left: DiffLine?
        let right: DiffLine?
    }

    private func pairLines(_ lines: [DiffLine]) -> [LinePair] {
        var pairs: [LinePair] = []
        var pending: [DiffLine] = []
        for line in lines {
            switch line.kind {
            case .context:
                pairs.append(contentsOf: flushPending(pending))
                pending.removeAll()
                pairs.append(LinePair(left: line, right: line))
            case .removed:
                pending.append(line)
            case .added:
                if let firstRemovedIndex = pending.firstIndex(where: { $0.kind == .removed }) {
                    let removed = pending.remove(at: firstRemovedIndex)
                    pairs.append(LinePair(left: removed, right: line))
                } else {
                    pairs.append(LinePair(left: nil, right: line))
                }
            }
        }
        pairs.append(contentsOf: flushPending(pending))
        return pairs
    }

    private func flushPending(_ pending: [DiffLine]) -> [LinePair] {
        pending.map { LinePair(left: $0, right: nil) }
    }
}
```

The split-pairing algorithm is the standard greedy approach: context lines align on both sides; consecutive removed lines wait in a queue; an added line pairs with the next queued removed line (left=removed, right=added) — once the queue is exhausted, additional added lines render right-only. At the end of a hunk, any leftover removed lines render left-only.

- [ ] **Step 3: Build verification + brief launch**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID. Do NOT interact — the human runs E2E.

After confirming the app starts: `pkill -9 -x PRReview` to clean up.

- [ ] **Step 4 (HUMAN runs this — DO NOT execute):** Manual E2E checklist:

1. Select a PR with multiple files. The Diff tab shows: toolbar at top (Unified/Split toggle, +N/−M stats, file count), file tree on the left (organised by directory, folders before files), diff content on the right with sticky-style file section headers.
2. Click a file deep in the tree → diff scrolls to that file's section.
3. Toggle to Split. Each file's lines render in two columns; removed lines on the left, added on the right, context on both sides.
4. Quit the app and relaunch. Toggle persists (still in Split mode).
5. Toggle back to Unified. Same diff renders in the single-column layout.

- [ ] **Step 5: Commit**

```bash
git add App/DiffToolbarView.swift App/DiffPaneView.swift
git commit -m "feat: GitHub-style diff pane with file tree and Unified/Split toggle" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Self-review

- **Spec coverage:**
  - Decision #1 (GitHub Files-changed layout) → Task 3's `HSplitView` with `FileTreeView` + `DiffContentView`.
  - Decision #2 (Unified/Split toggle persisted in `Settings.diffMode`) → Task 2 (state) + Task 3 (toolbar binding).
  - Decision #3 (changed-files tree organised as directory tree with status glyphs) → Task 1 builder + Task 3 `FileTreeView`.
  - Decision #4 (folder picker UX) — already done in Plan 8.
  - Decision #5 (local-clone validation) — already done in Plan 8.
  - Decision #6 (toggle persistence) → Task 2 `setDiffMode` writes through `ReviewStore.updateSettings`.
- **Placeholder scan:** None. Every step has full file contents.
- **Type consistency:**
  - `FileTreeNode` fields (`id`, `name`, `isLeaf`, `fileID`, `addedCount`, `removedCount`, `children`) consistent across definition, tests, view consumer.
  - `FileTreeBuilder.build(files:)` signature consistent.
  - `AppModel.diffMode: DiffMode` / `AppModel.setDiffMode(_:) async` consistent.
  - `DiffToolbarView(model:review:files:)` updated signature; all call sites match.
  - `DiffMode` enum has cases `.unified` and `.split` (existing in `PRReviewModels`).

## Definition of done

- `swift test --package-path Core` → 111 tests, 0 failures (103 prior + 6 FileTreeBuilder + 2 AppModel diffMode).
- App builds; Diff tab shows file tree + diff content side-by-side with toolbar; Split/Unified toggle works and persists.
- 3 commits; working tree clean.
- Known follow-ups (deferred per spec): tree-sitter syntax highlighting; expand-context; viewed checkboxes; inline comments; row virtualization beyond `LazyVStack`; full-repo browse; collapse/expand individual files.
