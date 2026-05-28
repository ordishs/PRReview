import Testing
import Foundation
@testable import ClaudeSessionKit

@Test func encodesSlashesToHyphens() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/Users/me/dev/foo")
    #expect(url.lastPathComponent == "-Users-me-dev-foo")
}

@Test func preservesSpacesAndOtherChars() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/Users/me/Application Support/foo")
    #expect(url.lastPathComponent == "-Users-me-Application Support-foo")
}

@Test func sitsUnderClaudeProjectsDir() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/x")
    let path = url.path
    #expect(path.contains(".claude/projects/"))
    #expect(path.hasSuffix("/-x"))
}
