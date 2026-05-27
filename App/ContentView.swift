import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("No reviews yet")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Reviews")
            .frame(minWidth: 240)
        } detail: {
            Text("Select a review")
                .foregroundStyle(.secondary)
                .font(.title3)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
