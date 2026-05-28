import SwiftUI
import PRReviewModels
import AppCore

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        HStack {
            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .font(.callout)
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
