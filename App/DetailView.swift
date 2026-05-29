import SwiftUI
import PRReviewModels
import AppCore

struct DetailView: View {
    let model: AppModel
    let webViewCache: WebViewCache
    let review: Review
    @State private var pane: Pane = .github

    enum Pane: String, CaseIterable, Identifiable {
        case claude = "Claude Review"
        case github = "GitHub"
        case diff = "Diff"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Button("Show Claude Review") { pane = .claude }
                .keyboardShortcut("1", modifiers: [.command])
                .hidden()
            Button("Show GitHub") { pane = .github }
                .keyboardShortcut("2", modifiers: [.command])
                .hidden()
            Button("Show Diff") { pane = .diff }
                .keyboardShortcut("3", modifiers: [.command])
                .hidden()
            Divider()
            switch pane {
            case .github:
                WebPane(cache: webViewCache, review: review)
                    .id(review.id)
            case .diff:
                DiffPaneView(model: model, review: review)
                    .id(review.id)
            case .claude:
                ClaudePaneView(model: model, review: review)
                    .id(review.id)
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }
}
