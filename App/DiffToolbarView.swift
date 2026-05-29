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
