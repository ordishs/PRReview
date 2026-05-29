import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var showingManage = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
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
                    created.startDiscoveryPolling()
                    model = created
                    appDelegate.model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
        .commands {
            CommandMenu("Repositories") {
                Button("Manage Local Clones…") {
                    showingManage = true
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(model == nil)
            }
        }
    }
}
