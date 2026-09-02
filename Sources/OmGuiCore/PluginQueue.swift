import Foundation

/// One row of the Plugin Queue tab (`PluginQueueItem.cs`).
public struct PluginQueueItem: Sendable, Identifiable, Equatable {
    public enum State: String, Sendable {
        case queued = "Queued"
        case running = "Running"
        case complete = "Complete"
        case cancelled = "Cancelled"
        case error = "Error"
    }

    public let id: UUID
    /// "Plugin" column.
    public var pluginName: String
    /// "Source" column — the input file.
    public var source: String
    /// "Progress (%)" column, 0…100.
    public var progress: Int
    public var state: State

    public init(id: UUID = UUID(), pluginName: String, source: String,
                progress: Int = 0, state: State = .queued) {
        self.id = id
        self.pluginName = pluginName
        self.source = source
        self.progress = progress
        self.state = state
    }

    /// What the "Progress (%)" cell shows: the number while running, the state otherwise.
    public var progressText: String {
        switch state {
        case .queued, .running: return String(progress)
        case .complete: return State.complete.rawValue
        case .cancelled: return State.cancelled.rawValue
        case .error: return State.error.rawValue
        }
    }

    public var isFinished: Bool {
        state == .complete || state == .cancelled || state == .error
    }
}

/// The in-app plugin queue. Phase 2 owns the model and the tab; phase 3's plugin host feeds it.
@MainActor
public final class PluginQueue: ObservableObject {

    @Published public private(set) var items: [PluginQueueItem] = []

    public init() {}

    @discardableResult
    public func enqueue(pluginName: String, source: String) -> UUID {
        let item = PluginQueueItem(pluginName: pluginName, source: source)
        items.append(item)
        return item.id
    }

    public func update(_ id: UUID, progress: Int? = nil, state: PluginQueueItem.State? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let progress { items[index].progress = max(0, min(100, progress)) }
        if let state { items[index].state = state }
    }

    /// The "Cancel" toolbar button — cancels the given rows (or every unfinished row).
    public func cancel(_ ids: Set<UUID>? = nil) {
        for index in items.indices {
            guard !items[index].isFinished else { continue }
            if let ids, !ids.contains(items[index].id) { continue }
            items[index].state = .cancelled
        }
    }

    /// The "Clear Completed" toolbar button.
    public func clearCompleted() {
        items.removeAll(where: \.isFinished)
    }

    public func removeAll() { items.removeAll() }
}
