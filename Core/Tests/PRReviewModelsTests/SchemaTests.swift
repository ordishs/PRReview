import Testing
@testable import PRReviewModels

@Test func schemaVersionIsOne() {
    #expect(PRReviewModels.schemaVersion == 1)
}
