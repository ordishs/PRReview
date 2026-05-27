import SwiftUI
import PRReviewModels
import AppCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(model.reviews, selection: $model.selection) { review in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(review.number) · \(review.title)")
                        .lineLimit(1)
                    Text("\(review.owner)/\(review.repo) · \(review.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                DetailView(review: review)
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
    }
}
