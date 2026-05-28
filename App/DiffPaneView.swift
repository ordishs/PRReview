import SwiftUI
import PRReviewModels
import DiffKit
import AppCore

struct DiffPaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        VStack(spacing: 0) {
            DiffToolbarView(model: model, review: review)
            Divider()
            Group {
                switch model.diffState {
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
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(files) { file in
                                    DiffFileView(file: file)
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
        }
        .task(id: review.id) {
            await model.loadDiff(for: review)
        }
    }
}

private struct DiffFileView: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.newPath ?? file.oldPath ?? "?")
                    .font(.system(.body, design: .monospaced))
                    .bold()
                Spacer()
                Text("+\(file.addedCount)").foregroundStyle(.green)
                Text("−\(file.removedCount)").foregroundStyle(.red)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))

            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(symbol + line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.system(.caption, design: .monospaced))
        .background(background)
    }

    private var symbol: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }
}
