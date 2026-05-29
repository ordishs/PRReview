import SwiftUI
import PRReviewModels
import AppCore
import ClaudeSessionKit

struct ContentView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(model.reviews, selection: $model.selection) { review in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(review.number) · \(review.title)")
                            .lineLimit(1)
                        Text("\(review.owner)/\(review.repo) · \(review.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(relativeDateLabel(for: review.addedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StatusDot(status: model.claudeStatuses[review.id])
                        .help(statusTooltip(model.claudeStatuses[review.id]))
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await model.removeReview(id: review.id) }
                    } label: {
                        Label("Remove from List", systemImage: "trash")
                    }
                }
            }
            .onDeleteCommand {
                if let id = model.selection {
                    Task { await model.removeReview(id: id) }
                }
            }
            .navigationTitle("Reviews")
            .frame(minWidth: 260)
            .toolbar {
                ToolbarItem {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPRSheet(model: model, isPresented: $showingAdd)
            }
        } detail: {
            if let review = model.selectedReview() {
                DetailView(model: model, webViewCache: webViewCache, review: review)
            } else {
                Text("Select a review")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Couldn't add PR", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.selection) { _, newSelection in
            guard let id = newSelection,
                  let review = model.reviews.first(where: { $0.id == id }) else { return }
            model.prefetch(for: review)
            _ = webViewCache.ensure(for: review)
        }
    }
}

private struct StatusDot: View {
    let status: ClaudeStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .working:
            return .blue
        case .idle:
            return .gray
        case .ready(let code):
            return code == 0 ? .green : .orange
        case .failed:
            return .red
        case .starting, nil:
            return .clear
        }
    }
}

private func statusTooltip(_ status: ClaudeStatus?) -> String {
    switch status {
    case .working:
        return "Working"
    case .idle(let since, let snippet):
        let elapsed = Int(Date().timeIntervalSince(since))
        let mins = max(elapsed / 60, 0)
        let base = mins > 0 ? "Idle \(mins)m" : "Idle"
        if let snippet, !snippet.isEmpty {
            return "\(base) · \(snippet)"
        }
        return base
    case .ready(let code):
        return code == 0 ? "Review ready" : "Exited · code \(code)"
    case .failed(let reason):
        return reason
    case .starting:
        return "Starting…"
    case nil:
        return ""
    }
}

private func relativeDateLabel(for date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if daysAgo < 7 { return "This Week" }
    if daysAgo < 14 { return "Last Week" }
    return "Older"
}
