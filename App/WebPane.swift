import SwiftUI
import AppKit
import WebKit
import PRReviewModels

struct WebPane: NSViewRepresentable {
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
