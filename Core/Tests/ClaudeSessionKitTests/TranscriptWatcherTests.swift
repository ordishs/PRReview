import Testing
import Foundation
@testable import ClaudeSessionKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("p12-tw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let sampleAssistantLine = """
{"type":"assistant","timestamp":"2026-05-28T14:00:22.582Z","sessionId":"x","message":{"content":[{"type":"text","text":"Looks good to me"}]}}
"""

private let sampleAssistantLine2 = """
{"type":"assistant","timestamp":"2026-05-28T14:05:00.000Z","sessionId":"x","message":{"content":[{"type":"text","text":"Done"}]}}
"""

@Test @MainActor func watcherDetectsExistingTranscript() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }

    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(!received.isEmpty)
    #expect(received.last?.1 == "Looks good to me")
    watcher.stop()
}

@Test @MainActor func watcherDetectsAppendedEvent() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let initialCount = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count > initialCount)
    #expect(received.last?.1 == "Done")
    watcher.stop()
}

@Test @MainActor func watcherStopsFiringAfterStop() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)
    watcher.stop()
    let countAfterStop = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count == countAfterStop)
}

@Test @MainActor func watcherIgnoresMalformedLines() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let mixed = "{not json}\n" + sampleAssistantLine + "\n{\"type\":\"unknown\"}\n"
    try mixed.write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(received.count == 1)
    #expect(received.last?.1 == "Looks good to me")
    watcher.stop()
}
