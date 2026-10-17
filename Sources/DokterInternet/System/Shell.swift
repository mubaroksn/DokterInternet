import Foundation

final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Thread-safe flag for "resume this continuation exactly once".
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Returns true only for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum Shell {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    /// Runs a command off the main thread and returns its output. Kills it after `timeout` seconds.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Drain stderr concurrently so a chatty command cannot fill the pipe and stall.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                let errData = errBox.data
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Output(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Quotes a value for /bin/sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum AdminResult: Equatable {
        case ok
        case cancelled
        case failed(String)
    }

    /// Runs a shell command as root through the standard macOS password prompt.
    static func runAsAdmin(_ command: String, prompt: String) async -> AdminResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let promptEscaped = prompt.replacingOccurrences(of: "\"", with: "'")
        let script = "do shell script \"\(escaped)\" with prompt \"\(promptEscaped)\" with administrator privileges"
        let out = await run("/usr/bin/osascript", ["-e", script], timeout: 300)
        if out.ok { return .ok }
        if out.stderr.contains("-128") || out.stderr.localizedCaseInsensitiveContains("cancel") { return .cancelled }
        let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(msg.isEmpty ? "Perintah gagal (kode \(out.status))" : msg)
    }
}
