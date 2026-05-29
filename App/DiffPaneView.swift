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
        case .deleted: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }

    private var changeColor: Color {
        switch file.changeKind {
        case .added: return .green
        case .deleted: return .red
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
            Text(numberFor(line, isLeft: isLeft))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(line?.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .background(background(for: line, isLeft: isLeft))
    }

    private func numberFor(_ line: DiffLine?, isLeft: Bool) -> String {
        guard let line else { return "" }
        if isLeft {
            return line.oldNumber.map(String.init) ?? ""
        } else {
            return line.newNumber.map(String.init) ?? ""
        }
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
