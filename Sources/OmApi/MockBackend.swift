import Foundation

/// An in-process fake of a set of AX3/AX6 devices, for development and tests without hardware.
///
/// Each fake device gets a real directory standing in for its mounted volume, containing a real
/// `CWA-DATA.CWA` written by `CwaWriter`, so `OmReader` (and `omconvert`) exercise exactly the
/// same code paths they would with hardware. Selected with `OMGUI_MOCK=1` or by constructing
/// `OmApi(backend: MockBackend())` directly.
public final class MockBackend: DeviceBackend, @unchecked Sendable {

    public let name = "mock"

    /// How one fake device starts out.
    public struct Spec: Sendable {
        public var deviceId: UInt32
        public var serialId: String
        public var volumeLabel: String
        public var port: String
        public var battery: Int
        /// When true, `batteryLevel` climbs on each poll, so the device moves Charging → Standby.
        public var charging: Bool
        public var sessionId: UInt32
        public var firmware: Int
        public var hardware: Int
        public var config: AccelConfig
        public var metadata: String
        public var start: OmDateTime
        public var stop: OmDateTime
        /// Data blocks to synthesise; 0 writes a header-only (empty) data file.
        public var dataBlocks: Int
        public var hardwareType: CwaWriter.HardwareType

        public init(deviceId: UInt32, serialId: String, volumeLabel: String, port: String,
                    battery: Int, charging: Bool = false, sessionId: UInt32 = 0,
                    firmware: Int = 48, hardware: Int = 65,
                    config: AccelConfig = .deviceDefault, metadata: String = "",
                    start: OmDateTime = .infinite, stop: OmDateTime = .infinite,
                    dataBlocks: Int = 0, hardwareType: CwaWriter.HardwareType = .ax3) {
            self.deviceId = deviceId
            self.serialId = serialId
            self.volumeLabel = volumeLabel
            self.port = port
            self.battery = battery
            self.charging = charging
            self.sessionId = sessionId
            self.firmware = firmware
            self.hardware = hardware
            self.config = config
            self.metadata = metadata
            self.start = start
            self.stop = stop
            self.dataBlocks = dataBlocks
            self.hardwareType = hardwareType
        }

        /// Three devices covering the categories a UI needs to render: an AX3 holding data, a
        /// charged AX6 with a gyro, and an AX3 still charging.
        public static let defaults: [Spec] = [
            Spec(deviceId: 1234, serialId: "CWA17_01234", volumeLabel: "AX317_01234",
                 port: "/dev/cu.usbmodem-mock1234", battery: 87, sessionId: 1,
                 config: AccelConfig(rate: .hz100, range: .g8),
                 metadata: MetadataTools.create([
                    .init("_c", "Boston Children's"),
                    .init("_s", "ARIA-IMPACT"),
                    .init("_sc", "P001"),
                    .init("_p", "left wrist"),
                 ]),
                 start: OmDateTime(date: Date().addingTimeInterval(-7 * 86_400)),
                 stop: OmDateTime(date: Date().addingTimeInterval(-3_600)),
                 dataBlocks: 24, hardwareType: .ax3),

            Spec(deviceId: 5678, serialId: "AX617_05678", volumeLabel: "AX617_05678",
                 port: "/dev/cu.usbmodem-mock5678", battery: 100, sessionId: 0,
                 firmware: 53, hardware: 100,
                 config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000),
                 dataBlocks: 0, hardwareType: .ax6),

            Spec(deviceId: 9999, serialId: "CWA17_09999", volumeLabel: "AX317_09999",
                 port: "/dev/cu.usbmodem-mock9999", battery: 42, charging: true, sessionId: 0,
                 dataBlocks: 0, hardwareType: .ax3),
        ]
    }

    // MARK: - Mutable per-device state

    private final class Device: @unchecked Sendable {
        var spec: Spec
        var battery: Int
        var sessionId: UInt32
        var metadata: String
        var config: AccelConfig
        var start: OmDateTime
        var stop: OmDateTime
        var maxSamples = 0
        var led: LedState = .auto
        var debug = 0
        /// Device clock minus host clock.
        var clockOffset: TimeInterval = 0
        var downloadCancelled = false
        var downloading = false
        var volumeURL: URL
        var dataFileURL: URL

        init(spec: Spec, volumeURL: URL) {
            self.spec = spec
            self.battery = spec.battery
            self.sessionId = spec.sessionId
            self.metadata = spec.metadata
            self.config = spec.config
            self.start = spec.start
            self.stop = spec.stop
            self.volumeURL = volumeURL
            self.dataFileURL = volumeURL.appendingPathComponent("CWA-DATA.CWA")
        }

        var info: DeviceInfo {
            DeviceInfo(deviceId: spec.deviceId, serialId: spec.serialId,
                       port: spec.port, volumePath: volumeURL.path,
                       dataFilePath: dataFileURL.path)
        }
    }

    // MARK: - Storage

    /// Directory holding one subdirectory per fake volume.
    public let root: URL
    private let specs: [Spec]
    private let lock = NSRecursiveLock()
    private var devices: [UInt32: Device] = [:]
    private var eventSink: (@Sendable (DeviceEvent) -> Void)?
    private var logSink: (@Sendable (String) -> Void)?
    private let downloadQueue = DispatchQueue(label: "omgui.mock.download", attributes: .concurrent)

    private let persistState: Bool

    /// Simulated download throughput, in progress steps. Lower is faster; tests use the default.
    public var downloadStepCount = 20
    /// Delay between download progress steps.
    public var downloadStepDelay: TimeInterval = 0.01

    // MARK: - Call recording (tests only)

    /// One recorded call to a device-mutating entry point.
    ///
    /// The mock cannot make a quick format behave differently from a wipe — both leave a bare
    /// header behind — so the *level* has to be observable, or nothing distinguishes the two
    /// destructive paths and inverting the ternary in `OmDevice.clear` is a silent change.
    public struct Call: Sendable, Equatable, CustomStringConvertible {
        public var deviceId: UInt32
        public var name: String
        public var arguments: String

        public init(deviceId: UInt32, name: String, arguments: String = "") {
            self.deviceId = deviceId
            self.name = name
            self.arguments = arguments
        }

        public var description: String {
            arguments.isEmpty ? "\(name)(\(deviceId))" : "\(name)(\(deviceId), \(arguments))"
        }
    }

    private var _calls: [Call] = []

    /// Every mutating call this backend has received, in order.
    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// `calls`, rendered as `"setSessionId(1234, 0)"` strings.
    public var callDescriptions: [String] { calls.map(\.description) }

    /// The erase levels `eraseAndCommit` was asked for, in order.
    public func eraseLevels(for deviceId: UInt32? = nil) -> [EraseLevel] {
        calls.filter { $0.name == "eraseAndCommit" && (deviceId == nil || $0.deviceId == deviceId!) }
            .compactMap { call in EraseLevel.allCases.first { String(describing: $0) == call.arguments } }
    }

    public func clearCalls() {
        lock.lock(); _calls.removeAll(); lock.unlock()
    }

    private func record(_ deviceId: UInt32, _ name: String, _ arguments: String = "") {
        lock.lock(); _calls.append(Call(deviceId: deviceId, name: name, arguments: arguments)); lock.unlock()
    }

    /// - Parameters:
    ///   - persistState: keep the mutable device state in `state.json` under `root`, so a
    ///     `record` in one CLI invocation is still visible to the next `status`. Tests turn this
    ///     off (or use their own `root`) to stay isolated.
    public init(root: URL? = nil,
                specs: [Spec] = Spec.defaults,
                resetVolumes: Bool = false,
                persistState: Bool = true) {
        self.root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-mac-mock", isDirectory: true)
        self.specs = specs
        self.persistState = persistState
        if resetVolumes { try? FileManager.default.removeItem(at: self.root) }
    }

    // MARK: - Persistence

    private struct PersistedDevice: Codable {
        var battery: Int
        var sessionId: UInt32
        var metadata: String
        var apiRate: Int32
        var apiRange: Int32
        var start: UInt32
        var stop: UInt32
        var maxSamples: Int
        var led: Int32
        var debug: Int
        var clockOffset: TimeInterval
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    private func loadPersistedState() {
        guard persistState, let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode([String: PersistedDevice].self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }
        for (key, value) in stored {
            guard let id = UInt32(key), let device = devices[id] else { continue }
            device.battery = value.battery
            device.sessionId = value.sessionId
            device.metadata = value.metadata
            if let config = AccelConfig(apiRate: value.apiRate, apiRange: value.apiRange) { device.config = config }
            device.start = OmDateTime(raw: value.start)
            device.stop = OmDateTime(raw: value.stop)
            device.maxSamples = value.maxSamples
            device.led = LedState(rawValue: value.led) ?? .auto
            device.debug = value.debug
            device.clockOffset = value.clockOffset
        }
    }

    private func savePersistedState() {
        guard persistState else { return }
        lock.lock()
        let stored = devices.reduce(into: [String: PersistedDevice]()) { result, entry in
            let d = entry.value
            result[String(entry.key)] = PersistedDevice(
                battery: d.battery, sessionId: d.sessionId, metadata: d.metadata,
                apiRate: d.config.apiRate, apiRange: d.config.apiRange,
                start: d.start.raw, stop: d.stop.raw, maxSamples: d.maxSamples,
                led: d.led.rawValue, debug: d.debug, clockOffset: d.clockOffset)
        }
        lock.unlock()
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Lifecycle

    public func start(events: @escaping @Sendable (DeviceEvent) -> Void,
                      log: @escaping @Sendable (String) -> Void) throws {
        lock.lock()
        eventSink = events
        logSink = log
        devices.removeAll()
        lock.unlock()

        log("MOCK: using fake volumes under \(root.path)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for spec in specs {
            let volume = root.appendingPathComponent(spec.volumeLabel, isDirectory: true)
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            let device = Device(spec: spec, volumeURL: volume)
            lock.lock(); devices[spec.deviceId] = device; lock.unlock()
        }
        loadPersistedState()

        for spec in specs {
            guard let device = try? device(spec.deviceId) else { continue }
            // Only (re)write the data file when it is missing, so a download or a clear from an
            // earlier invocation survives.
            if !FileManager.default.fileExists(atPath: device.dataFileURL.path) {
                try writeDataFile(device, blocks: spec.dataBlocks)
            }
            log("MOCK: attached \(spec.serialId) at \(spec.port) -> \(device.volumeURL.path)")
            events(.connected(spec.deviceId))
        }
    }

    public func shutdown() {
        lock.lock()
        for device in devices.values { device.downloadCancelled = true }
        eventSink = nil
        logSink = nil
        lock.unlock()
    }

    // MARK: - Enumeration

    public func deviceIds() -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return devices.keys.sorted()
    }

    public func info(_ deviceId: UInt32) throws -> DeviceInfo { try device(deviceId).info }

    // MARK: - Status

    public func version(_ deviceId: UInt32) throws -> (firmware: Int, hardware: Int) {
        let d = try device(deviceId)
        return (d.spec.firmware, d.spec.hardware)
    }

    public func batteryLevel(_ deviceId: UInt32) throws -> Int {
        let d = try device(deviceId)
        lock.lock(); defer { lock.unlock() }
        if d.spec.charging, d.battery < 100 { d.battery = min(100, d.battery + 5) }
        return d.battery
    }

    public func time(_ deviceId: UInt32) throws -> OmDateTime {
        let d = try device(deviceId)
        return OmDateTime(date: Date().addingTimeInterval(d.clockOffset))
    }

    public func setTime(_ deviceId: UInt32, _ value: OmDateTime) throws {
        let d = try device(deviceId)
        guard let target = value.date() else { throw OmError.invalidArg }
        record(deviceId, "setTime", String(value.raw))
        lock.lock(); d.clockOffset = target.timeIntervalSince(Date()); lock.unlock()
        savePersistedState()
    }

    public func setLed(_ deviceId: UInt32, _ state: LedState) throws {
        let d = try device(deviceId)
        record(deviceId, "setLed", String(describing: state))
        lock.lock(); d.led = state; lock.unlock()
        savePersistedState()
        log("MOCK: \(d.spec.serialId) LED -> \(state)")
    }

    public func setDebug(_ deviceId: UInt32, _ code: Int) throws {
        let d = try device(deviceId)
        record(deviceId, "setDebug", String(code))
        lock.lock(); d.debug = code; lock.unlock()
        savePersistedState()
    }

    // MARK: - Settings

    public func delays(_ deviceId: UInt32) throws -> (start: OmDateTime, stop: OmDateTime) {
        let d = try device(deviceId)
        return (d.start, d.stop)
    }

    public func setDelays(_ deviceId: UInt32, start: OmDateTime, stop: OmDateTime) throws {
        let d = try device(deviceId)
        record(deviceId, "setDelays", "\(start.raw), \(stop.raw)")
        lock.lock(); d.start = start; d.stop = stop; lock.unlock()
        savePersistedState()
    }

    public func sessionId(_ deviceId: UInt32) throws -> UInt32 { try device(deviceId).sessionId }

    public func setSessionId(_ deviceId: UInt32, _ value: UInt32) throws {
        let d = try device(deviceId)
        record(deviceId, "setSessionId", String(value))
        lock.lock(); d.sessionId = value; lock.unlock()
        savePersistedState()
    }

    public func metadata(_ deviceId: UInt32) throws -> String { try device(deviceId).metadata }

    public func setMetadata(_ deviceId: UInt32, _ value: String) throws {
        guard value.utf8.count <= MetadataTools.annotationTotalLength else { throw OmError.invalidArg }
        let d = try device(deviceId)
        record(deviceId, "setMetadata", "\"\(value)\"")
        lock.lock(); d.metadata = value; lock.unlock()
        savePersistedState()
    }

    public func accelConfig(_ deviceId: UInt32) throws -> (rate: Int32, range: Int32) {
        let config = try device(deviceId).config
        return (config.apiRate, config.apiRange)
    }

    public func setAccelConfig(_ deviceId: UInt32, rate: Int32, range: Int32) throws {
        let d = try device(deviceId)
        guard let config = AccelConfig(apiRate: rate, apiRange: range), config.isValidRateCode else {
            throw OmError.invalidArg
        }
        if config.axisCount == 6 && !d.info.hasSyncGyro { throw OmError.invalidArg }
        record(deviceId, "setAccelConfig", "rate: \(rate), range: \(range)")
        lock.lock(); d.config = config; lock.unlock()
        savePersistedState()
    }

    public func maxSamples(_ deviceId: UInt32) throws -> Int { try device(deviceId).maxSamples }

    public func setMaxSamples(_ deviceId: UInt32, _ value: Int) throws {
        let d = try device(deviceId)
        record(deviceId, "setMaxSamples", String(value))
        lock.lock(); d.maxSamples = value; lock.unlock()
        savePersistedState()
    }

    public func eraseAndCommit(_ deviceId: UInt32, level: EraseLevel) throws {
        let d = try device(deviceId)
        record(deviceId, "eraseAndCommit", String(describing: level))
        switch level {
        case .none:
            // Commit: rewrite the header in place, keep the recorded data.
            try rewriteHeader(d)
        case .delete, .quickFormat, .wipe:
            try writeDataFile(d, blocks: 0)
        }
        savePersistedState()
        log("MOCK: \(d.spec.serialId) commit (\(level))")
    }

    // MARK: - Data

    public func dataFileSize(_ deviceId: UInt32) throws -> Int {
        let d = try device(deviceId)
        let attributes = try FileManager.default.attributesOfItem(atPath: d.dataFileURL.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    public func beginDownload(_ deviceId: UInt32, to destination: String) throws {
        let d = try device(deviceId)
        record(deviceId, "beginDownload", destination)
        lock.lock()
        if d.downloading { lock.unlock(); throw OmError.notValidState }
        d.downloading = true
        d.downloadCancelled = false
        lock.unlock()

        let source = d.dataFileURL
        let steps = max(1, downloadStepCount)
        let delay = downloadStepDelay

        downloadQueue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); d.downloading = false; self.lock.unlock() }

            guard let data = try? Data(contentsOf: source) else {
                self.emit(.download(deviceId: deviceId, status: .error, value: Int(OmError.accessDenied.code)))
                return
            }
            FileManager.default.createFile(atPath: destination, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: destination) else {
                self.emit(.download(deviceId: deviceId, status: .error, value: Int(OmError.accessDenied.code)))
                return
            }
            defer { try? handle.close() }

            self.emit(.download(deviceId: deviceId, status: .progress, value: 0))
            let chunk = max(1, (data.count + steps - 1) / steps)
            var written = 0
            while written < data.count {
                self.lock.lock(); let cancelled = d.downloadCancelled; self.lock.unlock()
                if cancelled {
                    try? FileManager.default.removeItem(atPath: destination)
                    self.emit(.download(deviceId: deviceId, status: .cancelled, value: 0))
                    return
                }
                let end = min(written + chunk, data.count)
                handle.write(data[written..<end])
                written = end
                self.emit(.download(deviceId: deviceId, status: .progress,
                                    value: Int(100 * Double(written) / Double(max(1, data.count)))))
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
            self.emit(.download(deviceId: deviceId, status: .progress, value: 100))
            self.emit(.download(deviceId: deviceId, status: .complete, value: 100))
        }
    }

    public func cancelDownload(_ deviceId: UInt32) throws {
        let d = try device(deviceId)
        record(deviceId, "cancelDownload")
        lock.lock(); d.downloadCancelled = true; lock.unlock()
    }

    // MARK: - Helpers

    private func device(_ deviceId: UInt32) throws -> Device {
        lock.lock(); defer { lock.unlock() }
        guard let d = devices[deviceId] else { throw OmError.invalidDevice }
        return d
    }

    private func writer(for d: Device) -> CwaWriter {
        CwaWriter(hardware: d.spec.hardwareType,
                  deviceId: d.spec.deviceId,
                  sessionId: d.sessionId,
                  config: d.config,
                  metadata: d.metadata,
                  loggingStart: d.start,
                  loggingEnd: d.stop,
                  lastChange: OmDateTime(date: Date()),
                  firmwareRevision: UInt8(clamping: d.spec.firmware),
                  flashLed: d.debug == 3,
                  battery: UInt8(clamping: batteryAdc(d.battery)))
    }

    /// Exact inverse of `AdcBattToPercentReader` (omapi-reader.c) by search, so the synthetic
    /// file's battery byte reads back as the percentage the device reports.
    private func batteryAdc(_ percent: Int) -> Int {
        func percentFor(_ vbat: Int) -> Int {
            if vbat > 708 { return 100 }
            if vbat < 614 { return 0 }
            if vbat > 666 { return (150 * (vbat - 538)) >> 8 }
            return (375 * (vbat - 614)) >> 8
        }
        let target = max(0, min(100, percent))
        var best = 614
        var bestError = Int.max
        for vbat in 614...708 {
            let error = abs(percentFor(vbat) - target)
            if error < bestError { bestError = error; best = vbat }
            if error == 0 { break }
        }
        return max(0, min(255, best - 512))
    }

    private func writeDataFile(_ d: Device, blocks: Int) throws {
        let cwa = writer(for: d)
        let start = OmDateTime(date: Date().addingTimeInterval(-Double(blocks) * 1.0))
        let data = blocks > 0 ? cwa.fileData(startTime: start, blockCount: blocks) : cwa.emptyFileData()
        try data.write(to: d.dataFileURL, options: .atomic)
    }

    private func rewriteHeader(_ d: Device) throws {
        let header = Data(writer(for: d).headerBlock())
        if var existing = try? Data(contentsOf: d.dataFileURL), existing.count >= header.count {
            existing.replaceSubrange(0..<header.count, with: header)
            try existing.write(to: d.dataFileURL, options: .atomic)
        } else {
            try header.write(to: d.dataFileURL, options: .atomic)
        }
    }

    private func emit(_ event: DeviceEvent) {
        lock.lock(); let sink = eventSink; lock.unlock()
        sink?(event)
    }

    private func log(_ message: String) {
        lock.lock(); let sink = logSink; lock.unlock()
        sink?(message)
    }
}
