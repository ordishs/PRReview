import Testing
import Foundation
@testable import ClaudeSessionKit

private let reader = ClaudeStatusReader(idleThresholdSeconds: 30)

@Test func startingWhenProcessNotYetRunning() {
    let status = reader.status(processState: .starting, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func startingWhenRunningButNoEventsYet() {
    let status = reader.status(processState: .running, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func workingWhenRecentEventWithinThreshold() {
    let now = Date()
    let status = reader.status(processState: .running, lastEventAt: now.addingTimeInterval(-10), lastVerdictSnippet: nil, now: now)
    #expect(status == .working)
}

@Test func idleAfterThresholdElapses() {
    let now = Date()
    let lastEvent = now.addingTimeInterval(-31)
    let status = reader.status(processState: .running, lastEventAt: lastEvent, lastVerdictSnippet: "hello", now: now)
    if case .idle(let since, let snippet) = status {
        #expect(since == lastEvent)
        #expect(snippet == "hello")
    } else {
        Issue.record("expected .idle, got \(status)")
    }
}

@Test func readyOnCleanExitZero() {
    let status = reader.status(processState: .exited(code: 0), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 0))
}

@Test func readyKeepsNonZeroExitCode() {
    let status = reader.status(processState: .exited(code: 1), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 1))
}

@Test func failedFromFailedToLaunch() {
    let status = reader.status(processState: .failedToLaunch("bad path"), lastEventAt: nil, lastVerdictSnippet: nil)
    if case .failed(let reason) = status {
        #expect(reason == "bad path")
    } else {
        Issue.record("expected .failed, got \(status)")
    }
}
