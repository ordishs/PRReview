import SwiftUI
import PRReviewModels
import AppCore

struct DetailView: View {
    let model: AppModel
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
            Divider()
            switch pane {
            case .github:
                WebPane(url: review.url)
            case .diff:
                DiffPaneView(model: model, review: review)
            case .claude:
                ClaudePaneView(model: model, review: review)
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }
}
