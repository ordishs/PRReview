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

@Test func latestSessionIDReturnsNilWhenDirectoryMissing() {
    let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
    #expect(ClaudeTranscriptPath.latestSessionID(in: url) == nil)
}

@Test func latestSessionIDReturnsNilWhenDirectoryEmpty() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ClaudeTranscriptPath.latestSessionID(in: url) == nil)
}

@Test func latestSessionIDPicksNewestJSONLByModificationTime() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let older = url.appendingPathComponent("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl")
    let newer = url.appendingPathComponent("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl")
    let unrelated = url.appendingPathComponent("notes.txt")

    try "{}".write(to: older, atomically: true, encoding: .utf8)
    try "irrelevant".write(to: unrelated, atomically: true, encoding: .utf8)
    try "{}".write(to: newer, atomically: true, encoding: .utf8)

    let past = Date().addingTimeInterval(-3600)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: older.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)

    let id = ClaudeTranscriptPath.latestSessionID(in: url)
    #expect(id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
}
