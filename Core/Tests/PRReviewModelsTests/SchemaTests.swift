import Testing
import Foundation
@testable import PRReviewModels

@Test func schemaVersionIsOne() {
    #expect(PRReviewModels.schemaVersion == 1)
}

@Test func reviewDefaultsDisabledToFalse() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.disabled == false)
}

@Test func reviewDecodesPersistedDisabledTrue() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0,
      "disabled": true
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.disabled == true)
}
