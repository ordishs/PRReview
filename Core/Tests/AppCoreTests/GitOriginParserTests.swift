import Testing
import AppCore

@Test func parsesHttpsURL() {
    let result = GitOriginParser.parse("https://github.com/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesHttpsURLWithDotGit() {
    let result = GitOriginParser.parse("https://github.com/bsv-blockchain/teranode.git")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesSshURL() {
    let result = GitOriginParser.parse("git@github.com:bsv-blockchain/teranode.git")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesUppercaseHost() {
    let result = GitOriginParser.parse("https://GitHub.COM/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func parsesWwwHost() {
    let result = GitOriginParser.parse("https://www.github.com/bsv-blockchain/teranode")
    #expect(result?.owner == "bsv-blockchain")
    #expect(result?.repo == "teranode")
}

@Test func rejectsNonGithubHost() {
    #expect(GitOriginParser.parse("https://gitlab.com/o/r") == nil)
}

@Test func rejectsMalformed() {
    #expect(GitOriginParser.parse("not a url") == nil)
}
