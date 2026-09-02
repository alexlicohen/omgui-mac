import Foundation

/// The set of device operations `OmApi`/`OmDevice` are built on.
///
/// One-to-one with the `omapi.h` calls that upstream `omapinet` uses, so `LibOmapiBackend` is a
/// thin translation and `MockBackend` can stand in without the rest of the stack knowing.
///
/// Implementations must be safe to call from any thread; events may arrive on any thread.
public protocol DeviceBackend: AnyObject, Sendable {

    /// Human name for logs/`--mock` reporting.
    var name: String { get }

    // MARK: Lifecycle

    /// `OmStartup`. Callbacks are registered before startup so the initial device set is seen.
    func start(events: @escaping @Sendable (DeviceEvent) -> Void,
               log: @escaping @Sendable (String) -> Void) throws
    /// `OmShutdown`.
    func shutdown()

    // MARK: Enumeration

    /// `OmGetDeviceIds`, connected devices only.
    func deviceIds() -> [UInt32]
    /// `OmGetDeviceSerial` + `OmGetDevicePort` + `OmGetDevicePath` + `OmGetDataFilename`.
    func info(_ deviceId: UInt32) throws -> DeviceInfo

    // MARK: Status

    /// `OmGetVersion`.
    func version(_ deviceId: UInt32) throws -> (firmware: Int, hardware: Int)
    /// `OmGetBatteryLevel`, 0–100.
    func batteryLevel(_ deviceId: UInt32) throws -> Int
    /// `OmGetTime`.
    func time(_ deviceId: UInt32) throws -> OmDateTime
    /// `OmSetTime`.
    func setTime(_ deviceId: UInt32, _ value: OmDateTime) throws
    /// `OmSetLed`.
    func setLed(_ deviceId: UInt32, _ state: LedState) throws
    /// `DEBUG <n>` via `OmCommand` — OMGUI's "Flash during recording" (3 on, 0 off).
    func setDebug(_ deviceId: UInt32, _ code: Int) throws

    // MARK: Settings

    /// `OmGetDelays`.
    func delays(_ deviceId: UInt32) throws -> (start: OmDateTime, stop: OmDateTime)
    /// `OmSetDelays` (does not commit).
    func setDelays(_ deviceId: UInt32, start: OmDateTime, stop: OmDateTime) throws
    /// `OmGetSessionId`.
    func sessionId(_ deviceId: UInt32) throws -> UInt32
    /// `OmSetSessionId` (does not commit).
    func setSessionId(_ deviceId: UInt32, _ value: UInt32) throws
    /// `OmGetMetadata`.
    func metadata(_ deviceId: UInt32) throws -> String
    /// `OmSetMetadata`.
    func setMetadata(_ deviceId: UInt32, _ value: String) throws
    /// `OmGetAccelConfig`, in the overloaded (rate, range) integer form.
    func accelConfig(_ deviceId: UInt32) throws -> (rate: Int32, range: Int32)
    /// `OmSetAccelConfig`, in the overloaded (rate, range) integer form.
    func setAccelConfig(_ deviceId: UInt32, rate: Int32, range: Int32) throws
    /// `OmGetMaxSamples`.
    func maxSamples(_ deviceId: UInt32) throws -> Int
    /// `OmSetMaxSamples`.
    func setMaxSamples(_ deviceId: UInt32, _ value: Int) throws
    /// `OmEraseDataAndCommit`. `.none` is `OmCommit`.
    func eraseAndCommit(_ deviceId: UInt32, level: EraseLevel) throws

    // MARK: Data

    /// `OmGetDataFileSize`.
    func dataFileSize(_ deviceId: UInt32) throws -> Int
    /// `OmBeginDownloading(deviceId, 0, -1, destination)`.
    func beginDownload(_ deviceId: UInt32, to destination: String) throws
    /// `OmCancelDownload`.
    func cancelDownload(_ deviceId: UInt32) throws
}

public extension DeviceBackend {
    /// `OmCommit` — commit settings without erasing.
    func commit(_ deviceId: UInt32) throws { try eraseAndCommit(deviceId, level: .none) }
}
