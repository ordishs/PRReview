import AppKit
import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
public final class ClaudeSession {
    public private(set) var state: ClaudeSessionState = .starting
    public let spec: ClaudeLaunchSpec
    public let terminalView: LocalProcessTerminalView

    private let delegateBridge: DelegateBridge
    private let scrollMonitorBox: ScrollMonitorBox

    public init(spec: ClaudeLaunchSpec) {
        self.spec = spec
        let view = LocalProcessTerminalView(frame: .zero)
        self.terminalView = view
        let bridge = DelegateBridge()
        self.delegateBridge = bridge
        let box = ScrollMonitorBox()
        self.scrollMonitorBox = box
        view.processDelegate = bridge
        bridge.onExit = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.state = .exited(code: code)
            }
        }
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak view] event in
            guard let view, event.deltaY != 0 else { return event }
            guard view.window?.firstResponder === view else { return event }
            guard view.terminal.isCurrentBufferAlternate else { return event }
            let delta = Int(abs(event.deltaY))
            let velocity: Int
            if delta > 9 { velocity = 3 }
            else if delta > 5 { velocity = 2 }
            else { velocity = 1 }
            let arrowSeq = event.deltaY > 0
                ? (view.terminal.applicationCursor ? EscapeSequences.moveUpApp   : EscapeSequences.moveUpNormal)
                : (view.terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0 ..< velocity {
                view.send(arrowSeq)
            }
            return nil
        }
    }

    public func start() {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            state = .failedToLaunch("claude not found at \(spec.executable)")
            return
        }
        state = .starting
        let shellCommand = makeShellCommand()
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", shellCommand],
            environment: nil,
            execName: nil
        )
        state = .running
    }

    public func restart() {
        terminate()
        start()
    }

    public func terminate() {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let process = terminalView.process
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process?.running == true {
                kill(pid, SIGKILL)
            }
        }
    }

    private func makeShellCommand() -> String {
        let escapedCwd = shellEscape(spec.cwd)
        let escapedExec = shellEscape(spec.executable)
        let escapedArgs = spec.arguments.map(shellEscape).joined(separator: " ")
        let argsSuffix = escapedArgs.isEmpty ? "" : " " + escapedArgs
        return "cd \(escapedCwd) && exec \(escapedExec)\(argsSuffix)"
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class DelegateBridge: NSObject, LocalProcessTerminalViewDelegate {
    nonisolated(unsafe) var onExit: (@Sendable (Int32) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(exitCode ?? -1)
    }
}

private final class ScrollMonitorBox {
    var monitor: Any?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
