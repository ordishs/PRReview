import SwiftUI
import PRReviewModels
import AppCore

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review
    @State private var showingFolderPicker = false

    var body: some View {
        HStack {
            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Use local clone…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(8)
        .font(.callout)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                await model.registerClone(for: review, localPath: url.path)
                if model.errorMessage == nil {
                    await model.loadDiff(for: review)
                }
            }
        }
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
