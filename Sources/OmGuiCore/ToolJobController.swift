import Foundation

/// One queued piece of work: the rows OMGUI puts in the Plugin Queue tab, generalised so the
/// Tools menu can use it too.
///
/// `steps` runs in order and stops at the first failure — that is `CheckWavConversion` followed by
/// the analysis itself, which upstream runs as two `ProcessingForm`s back to back.
public struct ToolJob: Sendable {
    /// The "Plugin" column.
    public var name: String
    /// The "Source" column — upstream joins multiple inputs with `"  |  "`.
    public var source: String
    public var steps: [ToolInvocation]

    public init(name: String, source: String, steps: [ToolInvocation]) {
        self.name = name
        self.source = source
        self.steps = steps
    }

    /// The file the last step produces, which is what shows up in Output Files.
    public var finalPath: String? { steps.last?.finalPath }
}

/// Runs `ToolJob`s one at a time and reports them into the Plugin Queue.
///
/// OMGUI runs exports and Tools-menu analyses in a modal `ProcessingForm` and plugins in the
/// queue. The port puts both in the queue (the Mac window stays usable), which is the one
/// behavioural change the tools needed — see `refs/07-phase3b-notes.md`.
@MainActor
public final class ToolJobController {

    public typealias HelperResolver = @Sendable (HelperTool) throws -> URL

    private let queue: PluginQueue
    private let resolve: HelperResolver
    private var pending: [(id: UUID, job: ToolJob)] = []
    private var completions: [UUID: (ToolRunResult) -> Void] = [:]
    private var running: [UUID: ToolProcess] = [:]
    private var active = false

    /// Where the helper transcript goes (`textBoxProgress` upstream; the Log pane here).
    public var log: ((String) -> Void)?
    /// Called after every job, successful or not, so the workspace listing can refresh.
    public var onJobFinished: ((ToolJob, ToolRunResult) -> Void)?

    public init(queue: PluginQueue, resolve: @escaping HelperResolver = { try HelperTools.url(for: $0) }) {
        self.queue = queue
        self.resolve = resolve
        queue.onCancel = { [weak self] id in self?.running[id]?.cancel() }
    }

    public var isBusy: Bool { active || !pending.isEmpty }

    @discardableResult
    public func enqueue(_ job: ToolJob, completion: ((ToolRunResult) -> Void)? = nil) -> UUID {
        let id = queue.enqueue(pluginName: job.name, source: job.source)
        pending.append((id, job))
        if let completion { completions[id] = completion }
        pump()
        return id
    }

    private func pump() {
        guard !active, !pending.isEmpty else { return }
        let next = pending.removeFirst()

        // A row cancelled while it waited never starts (`PluginQueue.cancel` already marked it).
        if queue.items.first(where: { $0.id == next.id })?.state == .cancelled {
            completions.removeValue(forKey: next.id)?(ToolRunResult(exitCode: 0, cancelled: true))
            pump()
            return
        }

        active = true
        let id = next.id
        let job = next.job
        let process = ToolProcess()
        running[id] = process
        queue.update(id, state: .running)

        let steps = job.steps
        let resolve = self.resolve
        Task.detached { [weak self] in
            var result = ToolRunResult()
            for (index, step) in steps.enumerated() {
                let executable: URL
                do {
                    switch step.executable {
                    case .helper(let tool): executable = try resolve(tool)
                    case .path(let path): executable = URL(fileURLWithPath: path)
                    }
                } catch {
                    let message = "\(error)"
                    await MainActor.run { self?.log?(message) }
                    result = ToolRunResult(exitCode: -1, cancelled: false, renamed: false,
                                           errorMessage: message)
                    break
                }
                result = process.run(step, executable: executable, onOutput: { line in
                    Task { @MainActor in self?.log?(line) }
                }, onProgress: { percent in
                    Task { @MainActor in self?.queue.update(id, progress: percent) }
                })
                guard result.succeeded else { break }
                // No helper reports a percentage, so completed steps are the honest signal.
                let percent = (index + 1) * 100 / steps.count
                await MainActor.run { self?.queue.update(id, progress: percent) }
            }
            let outcome = result
            await MainActor.run { self?.finish(id: id, job: job, result: outcome) }
        }
    }

    private func finish(id: UUID, job: ToolJob, result: ToolRunResult) {
        running.removeValue(forKey: id)
        let completion = completions.removeValue(forKey: id)
        let wasCancelled = queue.items.first(where: { $0.id == id })?.state == .cancelled
        if result.cancelled || wasCancelled {
            queue.update(id, state: .cancelled)
        } else if result.succeeded {
            queue.update(id, progress: 100, state: .complete)
        } else {
            queue.update(id, state: .error)
        }
        active = false
        onJobFinished?(job, result)
        completion?(result)
        pump()
    }
}
