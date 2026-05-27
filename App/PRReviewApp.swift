import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let startupError {
                    Text(startupError)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ProgressView().frame(minWidth: 900, minHeight: 600)
                }
            }
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    await created.load()
                    model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
    }
}
