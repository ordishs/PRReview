import Foundation

public protocol NotificationPosting: Sendable {
    func postReviewReady(reviewID: String, title: String, body: String) async
}
