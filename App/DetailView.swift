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
                placeholder(title: "Claude review", subtitle: "The embedded terminal lands with the Claude pane.")
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
