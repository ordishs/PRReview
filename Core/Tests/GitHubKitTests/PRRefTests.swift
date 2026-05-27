import Testing
import GitHubKit

@Test func parsesStandardPullURL() throws {
    let ref = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944")
    #expect(ref == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))
}

@Test func parsesPullURLWithTrailingPathAndQuery() throws {
    let filesRef = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944/files")
    #expect(filesRef == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))

    let queryRef = try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/944?diff=split")
    #expect(queryRef == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))
}

@Test func rejectsNonPullURL() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://github.com/bsv-blockchain/teranode/issues/944")
    }
}

@Test func rejectsWrongHost() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://example.com/bsv-blockchain/teranode/pull/944")
    }
}

@Test func rejectsMalformedURL() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("not a url")
    }
}

@Test func parsesUppercaseHost() throws {
    let ref = try PRRef.parse("https://GitHub.com/bsv-blockchain/teranode/pull/944")
    #expect(ref == PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944))
}

@Test func rejectsInvalidPRNumber() {
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/abc")
    }
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/0")
    }
    #expect(throws: GitHubError.self) {
        try PRRef.parse("https://github.com/bsv-blockchain/teranode/pull/-1")
    }
}
