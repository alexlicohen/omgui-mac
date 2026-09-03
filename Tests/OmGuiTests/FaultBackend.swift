import Foundation
import OmApi

/// A `DeviceBackend` that forwards everything to a real `MockBackend` and fails exactly the calls a
/// test asks it to.
///
/// `MockBackend` alone cannot produce an `AX3-CONFIG-ERROR`, so every failure path in `RecordFlow`
/// — the seven per-device errors and the `SETTINGS.INI` step — was unreachable from the suite.
final class FaultBackend: DeviceBackend, @unchecked Sendable {

    /// The entry points a test can make fail.
    enum Operation: String, Sendable, CaseIterable {
        case info, version, batteryLevel, time, setTime, setLed, setDebug
        case delays, setDelays, sessionId, setSessionId, metadata, setMetadata
        case accelConfig, setAccelConfig, maxSamples, setMaxSamples
        case commit, erase, dataFileSize, beginDownload, cancelDownload
    }

    let wrapped: MockBackend
    var name: String { "fault(\(wrapped.name))" }

    private let lock = NSLock()
    private var failing: Set<Operation> = []
    private var _frozenClock = false
    private var _frozenTime: OmDateTime?
    private var _volumePath: String??

    init(wrapping wrapped: MockBackend) {
        self.wrapped = wrapped
    }

    // MARK: - Test knobs

    func fail(_ operations: Operation...) {
        lock.lock(); failing.formUnion(operations); lock.unlock()
    }

    /// A dead RTC crystal: the device latches `setTime` and reads the value back unchanged, but
    /// the clock never advances.
    var frozenClock: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _frozenClock }
        set { lock.lock(); _frozenClock = newValue; lock.unlock() }
    }

    /// Overrides the volume path every device reports (`nil` inside the optional = no drive).
    var volumePath: String?? {
        get { lock.lock(); defer { lock.unlock() }; return _volumePath }
        set { lock.lock(); _volumePath = newValue; lock.unlock() }
    }

    private func check(_ operation: Operation) throws {
        lock.lock(); let failing = self.failing.contains(operation); lock.unlock()
        if failing { throw OmError.fail }
    }

    // MARK: - Lifecycle

    func start(events: @escaping @Sendable (DeviceEvent) -> Void,
               log: @escaping @Sendable (String) -> Void) throws {
        try wrapped.start(events: events, log: log)
    }

    func shutdown() { wrapped.shutdown() }

    // MARK: - Enumeration

    func deviceIds() -> [UInt32] { wrapped.deviceIds() }

    func info(_ deviceId: UInt32) throws -> DeviceInfo {
        try check(.info)
        let info = try wrapped.info(deviceId)
        guard let override = volumePath else { return info }
        return DeviceInfo(deviceId: info.deviceId, serialId: info.serialId, port: info.port,
                          volumePath: override ?? "",
                          dataFilePath: override.map { ($0 as NSString).appendingPathComponent("CWA-DATA.CWA") } ?? "")
    }

    // MARK: - Status

    func version(_ deviceId: UInt32) throws -> (firmware: Int, hardware: Int) {
        try check(.version)
        return try wrapped.version(deviceId)
    }

    func batteryLevel(_ deviceId: UInt32) throws -> Int {
        try check(.batteryLevel)
        return try wrapped.batteryLevel(deviceId)
    }

    func time(_ deviceId: UInt32) throws -> OmDateTime {
        try check(.time)
        if frozenClock {
            lock.lock(); let frozen = _frozenTime; lock.unlock()
            if let frozen { return frozen }
        }
        return try wrapped.time(deviceId)
    }

    func setTime(_ deviceId: UInt32, _ value: OmDateTime) throws {
        try check(.setTime)
        if frozenClock {
            lock.lock(); _frozenTime = value; lock.unlock()
            return
        }
        try wrapped.setTime(deviceId, value)
    }

    func setLed(_ deviceId: UInt32, _ state: LedState) throws {
        try check(.setLed)
        try wrapped.setLed(deviceId, state)
    }

    func setDebug(_ deviceId: UInt32, _ code: Int) throws {
        try check(.setDebug)
        try wrapped.setDebug(deviceId, code)
    }

    // MARK: - Settings

    func delays(_ deviceId: UInt32) throws -> (start: OmDateTime, stop: OmDateTime) {
        try check(.delays)
        return try wrapped.delays(deviceId)
    }

    func setDelays(_ deviceId: UInt32, start: OmDateTime, stop: OmDateTime) throws {
        try check(.setDelays)
        try wrapped.setDelays(deviceId, start: start, stop: stop)
    }

    func sessionId(_ deviceId: UInt32) throws -> UInt32 {
        try check(.sessionId)
        return try wrapped.sessionId(deviceId)
    }

    func setSessionId(_ deviceId: UInt32, _ value: UInt32) throws {
        try check(.setSessionId)
        try wrapped.setSessionId(deviceId, value)
    }

    func metadata(_ deviceId: UInt32) throws -> String {
        try check(.metadata)
        return try wrapped.metadata(deviceId)
    }

    func setMetadata(_ deviceId: UInt32, _ value: String) throws {
        try check(.setMetadata)
        try wrapped.setMetadata(deviceId, value)
    }

    func accelConfig(_ deviceId: UInt32) throws -> (rate: Int32, range: Int32) {
        try check(.accelConfig)
        return try wrapped.accelConfig(deviceId)
    }

    func setAccelConfig(_ deviceId: UInt32, rate: Int32, range: Int32) throws {
        try check(.setAccelConfig)
        try wrapped.setAccelConfig(deviceId, rate: rate, range: range)
    }

    func maxSamples(_ deviceId: UInt32) throws -> Int {
        try check(.maxSamples)
        return try wrapped.maxSamples(deviceId)
    }

    func setMaxSamples(_ deviceId: UInt32, _ value: Int) throws {
        try check(.setMaxSamples)
        try wrapped.setMaxSamples(deviceId, value)
    }

    func eraseAndCommit(_ deviceId: UInt32, level: EraseLevel) throws {
        try check(level == .none ? .commit : .erase)
        try wrapped.eraseAndCommit(deviceId, level: level)
    }

    // MARK: - Data

    func dataFileSize(_ deviceId: UInt32) throws -> Int {
        try check(.dataFileSize)
        return try wrapped.dataFileSize(deviceId)
    }

    func beginDownload(_ deviceId: UInt32, to destination: String) throws {
        try check(.beginDownload)
        try wrapped.beginDownload(deviceId, to: destination)
    }

    func cancelDownload(_ deviceId: UInt32) throws {
        try check(.cancelDownload)
        try wrapped.cancelDownload(deviceId)
    }
}

/// A `GuiHarness` whose backend can be made to fail.
final class FaultHarness {
    let root: URL
    let workspace: URL
    let mock: MockBackend
    let backend: FaultBackend
    let api: OmApi

    init(specs: [MockBackend.Spec] = MockBackend.Spec.defaults) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-fault-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("mock", isDirectory: true)
        workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        mock = MockBackend(root: root, specs: specs, resetVolumes: true, persistState: false)
        mock.downloadStepCount = 5
        mock.downloadStepDelay = 0
        backend = FaultBackend(wrapping: mock)
        api = OmApi(backend: backend)
        try api.startup()
        for device in api.devices { device.syncTimeTiming = .fast }
    }

    func device(_ id: UInt32) throws -> OmDevice {
        guard let device = api.device(id) else {
            struct Missing: Error { let id: UInt32 }
            throw Missing(id: id)
        }
        return device
    }

    func tearDown() {
        api.shutdown()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
