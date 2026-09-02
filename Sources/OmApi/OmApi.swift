import Foundation

/// The Open Movement API façade, mirroring upstream `omapinet/Om.cs`.
///
/// Owns the device table, forwards the backend's device/download/log callbacks, and hands out
/// `OmDevice` objects. One instance owns one backend; `OmApi.shared` is the process-wide one the
/// GUI and the CLI use.
public final class OmApi: @unchecked Sendable {

    /// Environment variable that selects the mock backend (`1`, `true` or `yes`).
    public static let mockEnvironmentKey = "OMGUI_MOCK"
    /// Environment variable that overrides where the mock's fake volumes live.
    public static let mockRootEnvironmentKey = "OMGUI_MOCK_ROOT"

    public private(set) var backend: DeviceBackend
    public private(set) var isStarted = false

    private let lock = NSRecursiveLock()
    private var deviceTable: [UInt32: OmDevice] = [:]
    /// Last progress value per device, so repeated identical percentages are dropped (`Om.cs`).
    private var lastProgress: [UInt32: Int] = [:]

    // MARK: - Events

    /// A device was attached.
    public var onDeviceAttached: (@Sendable (OmDevice) -> Void)?
    /// A device was removed.
    public var onDeviceRemoved: (@Sendable (OmDevice) -> Void)?
    /// Anything about a device changed (settings written, download progress, ...).
    public var onDeviceChanged: (@Sendable (OmDevice, DownloadStatus) -> Void)?
    /// Log line from the backend.
    public var onLog: (@Sendable (String) -> Void)?

    // MARK: - Construction

    public init(backend: DeviceBackend) {
        self.backend = backend
    }

    /// `MockBackend` when `OMGUI_MOCK` is set, otherwise the real libomapi backend.
    public static func defaultBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> DeviceBackend {
        let flag = (environment[mockEnvironmentKey] ?? "").lowercased()
        if flag == "1" || flag == "true" || flag == "yes" {
            let root = environment[mockRootEnvironmentKey].map { URL(fileURLWithPath: $0) }
            return MockBackend(root: root)
        }
        return LibOmapiBackend()
    }

    /// Process-wide instance, backend chosen from the environment.
    public static let shared = OmApi(backend: OmApi.defaultBackend())

    // MARK: - Lifecycle

    /// `OmStartup`. Safe to call twice; the second call is a no-op.
    public func startup() throws {
        lock.lock()
        if isStarted { lock.unlock(); return }
        lock.unlock()

        try backend.start(events: { [weak self] event in
            self?.handle(event)
        }, log: { [weak self] message in
            self?.onLog?(message)
        })

        lock.lock(); isStarted = true; lock.unlock()

        // Backends that do not replay their initial device set through the callback still get
        // picked up here (libomapi does replay, so this is normally a no-op).
        for id in backend.deviceIds() where device(id) == nil {
            handle(.connected(id))
        }
    }

    /// `OmShutdown`.
    public func shutdown() {
        lock.lock()
        let started = isStarted
        isStarted = false
        lock.unlock()
        guard started else { return }
        backend.shutdown()
    }

    /// Replace the backend (only while stopped) — used by the CLI's `--mock` flag and by tests.
    public func replaceBackend(_ newBackend: DeviceBackend) throws {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            throw OmApiError("Cannot replace the backend while the API is started")
        }
        backend = newBackend
        deviceTable.removeAll()
        lastProgress.removeAll()
        lock.unlock()
    }

    // MARK: - Device table

    /// `Om.GetDevice` — returns the cached object, creating one on first sight.
    @discardableResult
    public func device(_ deviceId: UInt32, creating: Bool = false) -> OmDevice? {
        guard deviceId != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let existing = deviceTable[deviceId] { return existing }
        guard creating else { return nil }
        let created = OmDevice(api: self, backend: backend, deviceId: deviceId)
        deviceTable[deviceId] = created
        return created
    }

    /// Every device seen this session, connected or not, ordered by id.
    public var allDevices: [OmDevice] {
        lock.lock(); defer { lock.unlock() }
        return deviceTable.values.sorted { $0.deviceId < $1.deviceId }
    }

    /// Currently attached devices, ordered by id (what OMGUI's list shows).
    public var devices: [OmDevice] { allDevices.filter(\.connected) }

    // MARK: - Callback plumbing

    private func handle(_ event: DeviceEvent) {
        switch event {
        case .connected(let id):
            guard let device = device(id, creating: true) else { return }
            device.setConnected(true)
            onDeviceAttached?(device)

        case .removed(let id):
            guard let device = device(id, creating: true) else { return }
            device.setConnected(false)
            onDeviceRemoved?(device)

        case .download(let id, let status, let value):
            // `Om.DownloadCallback`: swallow repeated identical progress percentages.
            lock.lock()
            if status == .progress {
                if lastProgress[id] == value { lock.unlock(); return }
                lastProgress[id] = value
            } else {
                lastProgress.removeValue(forKey: id)
            }
            lock.unlock()

            guard let device = device(id, creating: true) else { return }
            device.updateDownloadStatus(status, value: value)
        }
    }

    /// Called by `OmDevice` when it mutates itself (`Om.OnChanged`).
    func deviceChanged(_ device: OmDevice, downloadStatus: DownloadStatus = .none) {
        onDeviceChanged?(device, downloadStatus)
    }
}
