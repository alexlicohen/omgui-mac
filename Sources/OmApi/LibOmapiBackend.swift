import Foundation
import COmApi

/// `DeviceBackend` implemented on the vendored libomapi C library.
public final class LibOmapiBackend: DeviceBackend, @unchecked Sendable {

    public let name = "libomapi"

    private let lock = NSLock()
    private var eventSink: (@Sendable (DeviceEvent) -> Void)?
    private var logSink: (@Sendable (String) -> Void)?
    private var started = false

    /// libomapi keeps a single set of global callbacks, so only one backend can be live at a time.
    nonisolated(unsafe) private static var current: LibOmapiBackend?
    private static let currentLock = NSLock()

    public init() {}

    // MARK: - Lifecycle

    public func start(events: @escaping @Sendable (DeviceEvent) -> Void,
                      log: @escaping @Sendable (String) -> Void) throws {
        LibOmapiBackend.currentLock.lock()
        if LibOmapiBackend.current != nil, LibOmapiBackend.current !== self {
            LibOmapiBackend.currentLock.unlock()
            throw OmApiError("libomapi is already started by another LibOmapiBackend instance")
        }
        LibOmapiBackend.current = self
        LibOmapiBackend.currentLock.unlock()

        lock.lock()
        eventSink = events
        logSink = log
        lock.unlock()

        let reference = Unmanaged.passUnretained(self).toOpaque()

        // Silence libomapi's own stderr stream: OmLog() writes to both the stream and the
        // callback, and everything the callback receives is surfaced through `log` instead.
        _ = OmSetLogStream(-1)

        // Register callbacks before OmStartup so the devices already attached are reported.
        _ = OmSetLogCallback({ ref, message in
            guard let ref, let message else { return }
            Unmanaged<LibOmapiBackend>.fromOpaque(ref).takeUnretainedValue()
                .emitLog(String(cString: message).trimmingCharacters(in: .newlines))
        }, reference)

        _ = OmSetDeviceCallback({ ref, deviceId, status in
            guard let ref else { return }
            let backend = Unmanaged<LibOmapiBackend>.fromOpaque(ref).takeUnretainedValue()
            let id = UInt32(bitPattern: deviceId)
            backend.emit(status == OM_DEVICE_CONNECTED ? .connected(id) : .removed(id))
        }, reference)

        _ = OmSetDownloadCallback({ ref, deviceId, status, value in
            guard let ref else { return }
            let backend = Unmanaged<LibOmapiBackend>.fromOpaque(ref).takeUnretainedValue()
            backend.emit(.download(deviceId: UInt32(bitPattern: deviceId),
                                   status: DownloadStatus(rawValue: status.rawValue) ?? .none,
                                   value: Int(value)))
        }, reference)

        try omCheck(OmStartup(OM_VERSION), "OmStartup")
        lock.lock(); started = true; lock.unlock()
    }

    public func shutdown() {
        lock.lock()
        let wasStarted = started
        started = false
        eventSink = nil
        logSink = nil
        lock.unlock()

        if wasStarted { _ = OmShutdown() }

        _ = OmSetDeviceCallback(nil, nil)
        _ = OmSetDownloadCallback(nil, nil)
        _ = OmSetLogCallback(nil, nil)

        LibOmapiBackend.currentLock.lock()
        if LibOmapiBackend.current === self { LibOmapiBackend.current = nil }
        LibOmapiBackend.currentLock.unlock()
    }

    private func emit(_ event: DeviceEvent) {
        lock.lock(); let sink = eventSink; lock.unlock()
        sink?(event)
    }

    private func emitLog(_ message: String) {
        guard !message.isEmpty else { return }
        lock.lock(); let sink = logSink; lock.unlock()
        sink?(message)
    }

    // MARK: - Enumeration

    public func deviceIds() -> [UInt32] {
        let total = OmGetDeviceIds(nil, 0)
        guard total > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: Int(total))
        let count = OmGetDeviceIds(&buffer, total)
        guard count > 0 else { return [] }
        return buffer.prefix(Int(min(count, total))).map { UInt32(bitPattern: $0) }
    }

    public func info(_ deviceId: UInt32) throws -> DeviceInfo {
        let id = Int32(bitPattern: deviceId)
        return DeviceInfo(deviceId: deviceId,
                          serialId: try string(capacity: 256) { OmGetDeviceSerial(id, $0) },
                          port: try string(capacity: 256) { OmGetDevicePort(id, $0) },
                          volumePath: try string(capacity: 256) { OmGetDevicePath(id, $0) },
                          dataFilePath: try string(capacity: 512) { OmGetDataFilename(id, $0) })
    }

    // MARK: - Status

    public func version(_ deviceId: UInt32) throws -> (firmware: Int, hardware: Int) {
        var firmware: Int32 = 0, hardware: Int32 = 0
        try omCheck(OmGetVersion(Int32(bitPattern: deviceId), &firmware, &hardware), "OmGetVersion")
        return (Int(firmware), Int(hardware))
    }

    public func batteryLevel(_ deviceId: UInt32) throws -> Int {
        Int(try omCheck(OmGetBatteryLevel(Int32(bitPattern: deviceId)), "OmGetBatteryLevel"))
    }

    public func time(_ deviceId: UInt32) throws -> OmDateTime {
        var value: OM_DATETIME = 0
        try omCheck(OmGetTime(Int32(bitPattern: deviceId), &value), "OmGetTime")
        return OmDateTime(raw: value)
    }

    public func setTime(_ deviceId: UInt32, _ value: OmDateTime) throws {
        try omCheck(OmSetTime(Int32(bitPattern: deviceId), value.raw), "OmSetTime")
    }

    public func setLed(_ deviceId: UInt32, _ state: LedState) throws {
        try omCheck(OmSetLed(Int32(bitPattern: deviceId), OM_LED_STATE(rawValue: state.rawValue)), "OmSetLed")
    }

    public func setDebug(_ deviceId: UInt32, _ code: Int) throws {
        var response = [CChar](repeating: 0, count: 256)
        let status = "\r\nDEBUG \(code)\r\n".withCString { command in
            "DEBUG=".withCString { expected in
                OmCommand(Int32(bitPattern: deviceId), command, &response, response.count,
                          expected, 2000, nil, 0)
            }
        }
        try omCheck(status, "OmCommand(DEBUG)")
    }

    // MARK: - Settings

    public func delays(_ deviceId: UInt32) throws -> (start: OmDateTime, stop: OmDateTime) {
        var start: OM_DATETIME = 0, stop: OM_DATETIME = 0
        try omCheck(OmGetDelays(Int32(bitPattern: deviceId), &start, &stop), "OmGetDelays")
        return (OmDateTime(raw: start), OmDateTime(raw: stop))
    }

    public func setDelays(_ deviceId: UInt32, start: OmDateTime, stop: OmDateTime) throws {
        try omCheck(OmSetDelays(Int32(bitPattern: deviceId), start.raw, stop.raw), "OmSetDelays")
    }

    public func sessionId(_ deviceId: UInt32) throws -> UInt32 {
        var value: UInt32 = 0
        try omCheck(OmGetSessionId(Int32(bitPattern: deviceId), &value), "OmGetSessionId")
        return value
    }

    public func setSessionId(_ deviceId: UInt32, _ value: UInt32) throws {
        try omCheck(OmSetSessionId(Int32(bitPattern: deviceId), value), "OmSetSessionId")
    }

    public func metadata(_ deviceId: UInt32) throws -> String {
        try string(capacity: Int(OM_METADATA_SIZE) + 1) { OmGetMetadata(Int32(bitPattern: deviceId), $0) }
    }

    public func setMetadata(_ deviceId: UInt32, _ value: String) throws {
        // OmSetMetadata takes an explicit length: 0 means "clear all 14 annotation segments".
        let bytes = value.utf8CString.dropLast().map { $0 }   // no trailing NUL in the length
        let status = bytes.withUnsafeBufferPointer { buffer in
            OmSetMetadata(Int32(bitPattern: deviceId), buffer.baseAddress, Int32(bytes.count))
        }
        try omCheck(status, "OmSetMetadata")
    }

    public func accelConfig(_ deviceId: UInt32) throws -> (rate: Int32, range: Int32) {
        var rate: Int32 = 0, range: Int32 = 0
        try omCheck(OmGetAccelConfig(Int32(bitPattern: deviceId), &rate, &range), "OmGetAccelConfig")
        return (rate, range)
    }

    public func setAccelConfig(_ deviceId: UInt32, rate: Int32, range: Int32) throws {
        try omCheck(OmSetAccelConfig(Int32(bitPattern: deviceId), rate, range), "OmSetAccelConfig")
    }

    public func maxSamples(_ deviceId: UInt32) throws -> Int {
        var value: Int32 = 0
        try omCheck(OmGetMaxSamples(Int32(bitPattern: deviceId), &value), "OmGetMaxSamples")
        return Int(value)
    }

    public func setMaxSamples(_ deviceId: UInt32, _ value: Int) throws {
        try omCheck(OmSetMaxSamples(Int32(bitPattern: deviceId), Int32(value)), "OmSetMaxSamples")
    }

    public func eraseAndCommit(_ deviceId: UInt32, level: EraseLevel) throws {
        try omCheck(OmEraseDataAndCommit(Int32(bitPattern: deviceId),
                                        OM_ERASE_LEVEL(rawValue: level.rawValue)),
                    "OmEraseDataAndCommit")
    }

    // MARK: - Data

    public func dataFileSize(_ deviceId: UInt32) throws -> Int {
        Int(try omCheck(OmGetDataFileSize(Int32(bitPattern: deviceId)), "OmGetDataFileSize"))
    }

    public func beginDownload(_ deviceId: UInt32, to destination: String) throws {
        try omCheck(OmBeginDownloading(Int32(bitPattern: deviceId), 0, -1, destination), "OmBeginDownloading")
    }

    public func cancelDownload(_ deviceId: UInt32) throws {
        try omCheck(OmCancelDownload(Int32(bitPattern: deviceId)), "OmCancelDownload")
    }

    // MARK: - Helpers

    private func string(capacity: Int, _ body: (UnsafeMutablePointer<CChar>) -> Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: capacity)
        let status = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        try omCheck(status, "OmGet<string>")
        let terminated = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: terminated, as: UTF8.self)
    }
}
