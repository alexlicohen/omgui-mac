import Foundation

/// What one helper run ended up doing.
public struct ToolRunResult: Sendable {
    public var exitCode: Int32 = -1
    public var cancelled = false
    /// The `<out>.part` → final rename `ProcessingForm` performs after a successful run.
    public var renamed = false
    /// `<<<ERROR: …>>>`, the missing-output message, or the `e`/`E:` line a plugin printed.
    public var errorMessage: String?

    /// `ProcessingForm` treats anything but "exit 0, not cancelled" as a failure.
    public var succeeded: Bool { !cancelled && exitCode == 0 && errorMessage == nil }
}

/// Runs one helper (or plugin) process, streaming its output and renaming `.part` on success.
///
/// This is `ProcessingForm.Execute` plus `pluginQueueWorker_DoWork`: stderr is the progress
/// transcript, stdout carries the plugin protocol (`p <n>` / `e <message>`), the process can be
/// killed from another thread, and a successful run moves `outputPath` onto `finalPath`.
///
/// `run` blocks; call it from a detached task.
public final class ToolProcess: @unchecked Sendable {

    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    public init() {}

    /// `backgroundWorker.CancellationPending` → `conversionProcess.Kill()`.
    public func cancel() {
        lock.lock()
        cancelRequested = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    @discardableResult
    public func run(_ invocation: ToolInvocation,
                    executable: URL,
                    onOutput: @escaping @Sendable (String) -> Void,
                    onProgress: @escaping @Sendable (Int) -> Void = { _ in }) -> ToolRunResult {
        var result = ToolRunResult()

        let task = Process()
        task.executableURL = executable
        task.arguments = invocation.arguments
        if let workingDirectory = invocation.workingDirectory {
            task.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        task.standardInput = FileHandle.nullDevice

        // `AppendText("<<<START: " + FileName + " " + Arguments + ">>>\n")`.
        onOutput("<<<START: \(executable.path) \(invocation.commandLine)>>>")

        // A refused invocation never reaches `Process`: the check that produced the refusal is the
        // one macOS would have made had the child been launched through LaunchServices.
        if let refusal = invocation.refusal {
            onOutput("<<<ERROR: \(refusal)>>>")
            onOutput("<<<FAILED>>>")
            result.errorMessage = refusal
            return result
        }

        lock.lock()
        if cancelRequested {
            lock.unlock()
            result.cancelled = true
            onOutput("<<<CANCELLED>>>")
            return result
        }
        process = task
        lock.unlock()

        let errorLine = Locked<String?>(nil)

        let stderrDone = DispatchSemaphore(value: 0)
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrBuffer = LineBuffer { line in onOutput(line) }
        let stdoutBuffer = LineBuffer { line in
            onOutput(line)
            let message = PluginOutput.parse(line)
            if let progress = message.progress { onProgress(progress) }
            if let error = message.error { errorLine.set(error) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrBuffer.flush()
                stderrDone.signal()
            } else {
                stderrBuffer.append(data)
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutBuffer.flush()
                stdoutDone.signal()
            } else {
                stdoutBuffer.append(data)
            }
        }

        do {
            try task.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); process = nil; lock.unlock()
            // `AppendText("<<<ERROR: " + ex.Message + ">>>\n")`.
            onOutput("<<<ERROR: \(error.localizedDescription)>>>")
            result.errorMessage = error.localizedDescription
            return result
        }

        task.waitUntilExit()
        onOutput("<<<WAIT>>>")
        _ = stderrDone.wait(timeout: .now() + 5)
        _ = stdoutDone.wait(timeout: .now() + 5)
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        process = nil
        result.cancelled = cancelRequested
        lock.unlock()

        result.exitCode = task.terminationStatus
        result.errorMessage = errorLine.get()
        onOutput("<<<END: \(result.exitCode)>>>")

        if result.cancelled { onOutput("<<<CANCELLED>>>"); return result }
        if result.exitCode != 0 || result.errorMessage != nil {
            onOutput("<<<FAILED>>>")
            return result
        }
        onOutput("<<<SUCCESS>>>")

        // The `.part` → final rename (`ProcessingForm_Load`'s completion block).
        guard let outputPath = invocation.outputPath else {
            result.renamed = true
            return result
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: outputPath) else {
            let message = "ERROR: Output file not found: \(outputPath)"
            onOutput(message)
            result.errorMessage = message
            return result
        }
        do {
            if fileManager.fileExists(atPath: invocation.finalPath) {
                onOutput("NOTE: Removing existing output file: \(invocation.finalPath)")
                try fileManager.removeItem(atPath: invocation.finalPath)
            }
            try fileManager.moveItem(atPath: outputPath, toPath: invocation.finalPath)
            result.renamed = true
        } catch {
            let message = "ERROR: Problem renaming output file: \(invocation.finalPath) -- \(error.localizedDescription)"
            onOutput(message)
            result.errorMessage = message
        }
        return result
    }
}

/// `MainForm.parseMessage` — the plugin's stdout protocol.
public enum PluginOutput {
    public struct Message: Sendable, Equatable {
        public var progress: Int?
        public var error: String?
    }

    /// `p <n>` / `P:<n>` is a percentage; `e <text>` / `E:<text>` is an error. Anything else, and
    /// any line shorter than three characters, is transcript only.
    public static func parse(_ line: String) -> Message {
        guard line.count > 2 else { return Message() }
        let characters = Array(line)
        let first = characters[0]
        let second = characters[1]
        guard second == " " || second == ":" else { return Message() }
        let rest = String(characters[2...])
        if first == "p" || first == "P" {
            return Message(progress: Int(rest.trimmingCharacters(in: .whitespaces)))
        }
        if first == "e" || first == "E" {
            return Message(error: rest)
        }
        return Message()
    }
}

/// Splits a byte stream into lines for a callback. Used from the pipe readability handlers, which
/// run on a private queue, so it carries its own lock.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        lock.lock()
        partial += text
        while let index = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(partial[partial.startIndex..<index])
            partial = String(partial[partial.index(after: index)...])
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        for line in lines { emit(line) }
    }

    func flush() {
        lock.lock()
        let line = partial
        partial = ""
        lock.unlock()
        if !line.isEmpty { emit(line) }
    }
}

/// A lock around one value, for the handful of places a pipe handler writes back.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }
}
