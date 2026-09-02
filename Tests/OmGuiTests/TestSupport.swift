import Foundation
import OmApi
import OmGuiCore
import XCTest

/// A private mock backend + started `OmApi` + a scratch workspace, torn down with the test.
final class GuiHarness {
    let root: URL
    let workspace: URL
    let backend: MockBackend
    let api: OmApi

    init(specs: [MockBackend.Spec] = MockBackend.Spec.defaults,
         downloadSteps: Int = 5,
         downloadDelay: TimeInterval = 0) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-gui-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("mock", isDirectory: true)
        workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        backend = MockBackend(root: root, specs: specs, resetVolumes: true, persistState: false)
        backend.downloadStepCount = downloadSteps
        backend.downloadStepDelay = downloadDelay
        api = OmApi(backend: backend)
        try api.startup()
    }

    func device(_ id: UInt32) throws -> OmDevice {
        try XCTUnwrap(api.device(id), "mock device \(id) is missing")
    }

    func tearDown() {
        api.shutdown()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// A `UserPrompting` that answers from a script and records what it was asked.
@MainActor
final class RecordingPrompter: UserPrompting {
    var confirmAnswers: [Bool] = []
    var defaultConfirm = true
    var abortRetryIgnoreAnswer: AbortRetryIgnore = .ignore
    private(set) var warnings: [(title: String, message: String)] = []
    private(set) var confirms: [(title: String, message: String)] = []

    func warn(title: String, message: String) {
        warnings.append((title, message))
    }

    func confirm(title: String, message: String) -> Bool {
        confirms.append((title, message))
        if confirmAnswers.isEmpty { return defaultConfirm }
        return confirmAnswers.removeFirst()
    }

    func abortRetryIgnore(title: String, message: String) -> AbortRetryIgnore {
        abortRetryIgnoreAnswer
    }
}

/// Blocks until every started download reaches a terminal status.
final class DownloadWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var outstanding: Set<UInt32> = []
    private var results: [UInt32: DownloadStatus] = [:]

    func expect(_ ids: [UInt32]) {
        condition.lock()
        for id in ids { outstanding.insert(id) }
        condition.unlock()
    }

    func observe(_ api: OmApi) {
        api.onDeviceChanged = { [weak self] device, status in
            guard let self else { return }
            switch status {
            case .complete, .cancelled, .error:
                self.condition.lock()
                self.results[device.deviceId] = status
                self.outstanding.remove(device.deviceId)
                self.condition.broadcast()
                self.condition.unlock()
            default:
                break
            }
        }
    }

    @discardableResult
    func wait(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !outstanding.isEmpty {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func status(_ id: UInt32) -> DownloadStatus? {
        condition.lock()
        defer { condition.unlock() }
        return results[id]
    }
}

extension RecordingDeviceInfo {
    /// A plain AX3: 100% battery, empty, standard AX3 capacity.
    static func ax3(battery: Int = 100,
                    hasData: Bool = false,
                    capacity: Int64 = OmDevice.standardCapacityAX3,
                    firmware: Int = 48,
                    deviceId: UInt32 = 1) -> RecordingDeviceInfo {
        RecordingDeviceInfo(deviceId: deviceId, batteryLevel: battery, hasData: hasData,
                            deviceCapacity: capacity, hasSyncGyro: false, firmwareVersion: firmware)
    }

    static func ax6(battery: Int = 100,
                    hasData: Bool = false,
                    capacity: Int64 = OmDevice.standardCapacityAX3,
                    firmware: Int = 53,
                    deviceId: UInt32 = 2) -> RecordingDeviceInfo {
        RecordingDeviceInfo(deviceId: deviceId, batteryLevel: battery, hasData: hasData,
                            deviceCapacity: capacity, hasSyncGyro: true, firmwareVersion: firmware)
    }
}

/// Thread-safe collector for `ProgressHandler` callbacks.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProgressReport] = []

    func add(_ report: ProgressReport) {
        lock.lock(); storage.append(report); lock.unlock()
    }

    var reports: [ProgressReport] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
