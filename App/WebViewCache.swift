import AppKit
import SwiftUI
import WebKit
import PRReviewModels

@MainActor
@Observable
final class WebViewCache {
    private var webViews: [String: WKWebView] = [:]
    private let configuration: WKWebViewConfiguration

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.configuration = config
    }

    func ensure(for review: Review) -> WKWebView {
        if let existing = webViews[review.id] {
            return existing
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: review.url))
        webViews[review.id] = webView
        return webView
    }

    func reload(for review: Review) {
        webViews[review.id]?.reload()
    }

    func remove(reviewID: String) {
        if let webView = webViews.removeValue(forKey: reviewID) {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
    }

    func removeAll() {
        for webView in webViews.values {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()
    }
}
