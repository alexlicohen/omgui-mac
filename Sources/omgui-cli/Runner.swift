import Foundation
import OmApi

/// Blocks the calling thread until every tracked download finishes, so the CLI can stay
/// synchronous while backend callbacks arrive on other threads.
final class DownloadWatcher: @unchecked Sendable {
    private let lock = NSCondition()
    private var outstanding: Set<UInt32> = []
    private var results: [UInt32: (status: DownloadStatus, value: Int, path: String?)] = [:]
    private var lastPrinted: [UInt32: Int] = [:]
    private let verbose: Bool

    init(verbose: Bool) { self.verbose = verbose }

    func expect(_ deviceId: UInt32) {
        lock.lock(); outstanding.insert(deviceId); lock.unlock()
    }

    func handle(_ device: OmDevice, status: DownloadStatus, finalPath: String?) {
        switch status {
        case .progress:
            guard verbose else { return }
            lock.lock()
            let value = device.downloadValue
            let show = lastPrinted[device.deviceId] != value && value % 10 == 0
            if show { lastPrinted[device.deviceId] = value }
            lock.unlock()
            if show {
                FileHandle.standardError.write(Data("  \(FilenameTemplate.deviceIdString(device.deviceId)): \(value)%\n".utf8))
            }
        case .complete, .cancelled, .error:
            lock.lock()
            results[device.deviceId] = (status, device.downloadValue, finalPath)
            outstanding.remove(device.deviceId)
            lock.broadcast()
            lock.unlock()
        case .none:
            break
        }
    }

    /// Returns false on timeout.
    @discardableResult
    func waitForAll(timeout: TimeInterval = 600) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while !outstanding.isEmpty {
            if !lock.wait(until: deadline) { return false }
        }
        return true
    }

    func result(for deviceId: UInt32) -> (status: DownloadStatus, value: Int, path: String?)? {
        lock.lock(); defer { lock.unlock() }
        return results[deviceId]
    }
}

/// Owns the `OmApi` instance for one CLI invocation.
final class Runner: @unchecked Sendable {
    let api: OmApi
    let options: Options
    private(set) var logLines: [String] = []
    private let lock = NSLock()

    init(options: Options) {
        self.options = options
        var environment = ProcessInfo.processInfo.environment
        if options.useMock { environment[OmApi.mockEnvironmentKey] = "1" }
        if let root = options.values["--mock-root"] { environment[OmApi.mockRootEnvironmentKey] = root }
        api = OmApi(backend: OmApi.defaultBackend(environment: environment))
    }

    func start() throws {
        let verbose = options.has("--verbose")
        api.onLog = { [weak self] message in
            guard let self else { return }
            self.lock.lock(); self.logLines.append(message); self.lock.unlock()
            if verbose { FileHandle.standardError.write(Data("[\(message)]\n".utf8)) }
        }
        do {
            try api.startup()
        } catch {
            throw CLIError.failed("Could not start the Open Movement API: \(error)")
        }
    }

    func stop() { api.shutdown() }

    /// The devices the command should act on: `--device` selections, or every attached device.
    func selectedDevices() throws -> [OmDevice] {
        let attached = api.devices
        guard !attached.isEmpty else { throw CLIError.noDevices }
        guard !options.deviceIds.isEmpty else { return attached }
        var chosen: [OmDevice] = []
        for id in options.deviceIds {
            guard let device = attached.first(where: { $0.deviceId == id }) else {
                throw CLIError.failed("Device \(FilenameTemplate.deviceIdString(id)) is not attached")
            }
            chosen.append(device)
        }
        return chosen
    }
}
