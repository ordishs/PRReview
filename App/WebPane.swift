import SwiftUI
import AppKit
import WebKit
import PRReviewModels

struct WebPane: View {
    let cache: WebViewCache
    let review: Review

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { cache.reload(for: review) }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh (\u{2318}R)")

                Spacer()

                Text(review.url.host ?? "github.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))

            Divider()

            WebViewHost(cache: cache, review: review)
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let cache: WebViewCache
    let review: Review

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = cache.ensure(for: review)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
