import Foundation

/// One attached (or recently removed) AX3/AX6, mirroring upstream `omapinet/OmDevice.cs`.
///
/// Values are cached exactly as OMGUI caches them: `update()` re-reads the battery every poll and
/// the rest of the status only until it has read it successfully once (`validData`).
public final class OmDevice: @unchecked Sendable {

    public let deviceId: UInt32
    private let backend: DeviceBackend
    private unowned let api: OmApi
    private let lock = NSRecursiveLock()

    // Cached state, all guarded by `lock`.
    private var _info: DeviceInfo?
    private var _connected = false
    private var _validData = false
    private var _failedCount = 0
    private var _lastUpdate: Date?
    private var _sessionId: UInt32 = .max
    private var _firmwareVersion: Int?
    private var _hardwareVersion: Int?
    private var _ledColor: LedState = .unknown
    private var _batteryLevel: Int?
    private var _timeDifference: TimeInterval?
    private var _startTime: OmDateTime = .zero
    private var _stopTime: OmDateTime = .zero
    private var _downloadStatus: DownloadStatus = .none
    private var _downloadValue = 0
    private var _warning: DeviceWarning = .none
    private var _hasChanged = false
    private var _downloadDestination: String?
    private var _downloadFinalPath: String?
    private var _downloadedThisSession = false
    private var _downloadFailure: String?
    private var _lastDownloadedPath: String?
    private var _accelConfig: AccelConfig?
    private var _syncTimeTiming: SyncTimeTiming = .upstream

    init(api: OmApi, backend: DeviceBackend, deviceId: UInt32) {
        self.api = api
        self.backend = backend
        self.deviceId = deviceId
        _info = try? backend.info(deviceId)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Identity

    public var info: DeviceInfo? { withLock { _info } }
    public var serialId: String { withLock { _info?.serialId ?? "" } }
    public var port: String { withLock { _info?.port ?? "" } }
    public var devicePath: String { withLock { _info?.volumePath ?? "" } }
    public var dataFilePath: String { withLock { _info?.dataFilePath ?? "" } }

    /// `OmDevice.HasSyncGyro` — an AX6 (or `CWA64` prototype firmware).
    public var hasSyncGyro: Bool { withLock { _info?.hasSyncGyro ?? false } }

    // MARK: - Cached status

    public var connected: Bool { withLock { _connected } }
    public var validData: Bool { withLock { _validData } }
    public var failedCount: Int { withLock { _failedCount } }
    /// `UInt32.max` until read.
    public var sessionId: UInt32 { withLock { _sessionId } }
    public var firmwareVersion: Int? { withLock { _firmwareVersion } }
    public var hardwareVersion: Int? { withLock { _hardwareVersion } }
    public var ledColor: LedState { withLock { _ledColor } }
    /// `nil` until read.
    public var batteryLevel: Int? { withLock { _batteryLevel } }
    /// Device clock minus host clock.
    public var timeDifference: TimeInterval? { withLock { _timeDifference } }
    public var startTime: OmDateTime { withLock { _startTime } }
    public var stopTime: OmDateTime { withLock { _stopTime } }
    public var downloadStatus: DownloadStatus { withLock { _downloadStatus } }
    public var downloadValue: Int { withLock { _downloadValue } }
    public var warning: DeviceWarning { withLock { _warning } }

    /// Why the last download ended in `.error` when the failure was ours rather than the device's
    /// — currently only the `.part` → `.cwa` rename. `nil` for a device-side error.
    public var downloadFailure: String? { withLock { _downloadFailure } }

    /// The file the last completed download actually produced — set only once the rename has been
    /// made and the file has been seen on disk, so a `.complete` status and this value together
    /// are the proof a `DOWNLOAD-OK` record needs.
    public var lastDownloadedPath: String? { withLock { _lastDownloadedPath } }

    /// The accelerometer configuration as of the last poll (`update()`), a device write, or a
    /// clear. Reading it costs nothing: `accelConfig()` is a 2 s-timeout `RATE` round trip, and a
    /// property grid that calls it on every selection change serialises against the flows.
    public var cachedAccelConfig: AccelConfig? { withLock { _accelConfig } }

    /// How long `syncTime()` waits. `.upstream` is what `OmDevice.cs` does; tests shorten it.
    public var syncTimeTiming: SyncTimeTiming {
        get { withLock { _syncTimeTiming } }
        set { withLock { _syncTimeTiming = newValue } }
    }

    /// `OmDevice.IsDownloading`.
    public var isDownloading: Bool { withLock { _connected && _downloadStatus == .progress } }

    /// `OmDevice.HasData` — a data file bigger than one header block.
    public var hasData: Bool {
        if isDownloading { return true }
        let path = dataFilePath
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 1024
    }

    /// `OmDevice.HasNewData`.
    ///
    /// OMGUI reads the Windows *archive* attribute, which macOS does not have. We track whether
    /// this session has downloaded the device since the file appeared instead; a device we have
    /// not downloaded counts as new.
    public var hasNewData: Bool {
        if isDownloading { return true }
        return hasData && !withLock { _downloadedThisSession }
    }

    /// AX3 NAND capacity fallback used by `OmDevice.DeviceCapacity` when the volume cannot be sized.
    public static let standardCapacityAX3: Int64 = 507_904_000

    /// Total bytes on the device volume.
    public var deviceCapacity: Int64 {
        let path = devicePath
        if !path.isEmpty,
           let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let size = attributes[.systemSize] as? NSNumber, size.int64Value > 0 {
            return size.int64Value
        }
        return serialId.hasPrefix("CWA") ? OmDevice.standardCapacityAX3 : -1
    }

    /// `OmDevice.IsRecording`.
    public var isRecording: RecordStatus {
        let (start, stop) = withLock { (_startTime, _stopTime) }
        let now = Date()
        let stopDate = stop.date()
        if stop.raw <= start.raw { return .stopped }
        if let stopDate, stopDate <= now { return .stopped }
        if start == .zero && stop == .infinite { return .always }
        return .interval
    }

    /// The text OMGUI puts in the "Recording" column.
    public var recordingDescription: String {
        var text: String
        switch isRecording {
        case .stopped: text = "Stopped"
        case .always: text = "Always"
        case .interval:
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM/yy HH:mm:ss"
            let start = startTime.date().map(formatter.string(from:)) ?? startTime.description
            let stop = stopTime.date().map(formatter.string(from:)) ?? stopTime.description
            text = "Interval \(start)-\(stop)"
        }
        if hasData { text += " (with data)" }
        return text
    }

    /// `OmSource.SourceCategory`, reproducing `OmDevice.Category` exactly — including its
    /// standing TODO, which collapses "New Data" into the plain "Devices" group.
    public var category: SourceCategory {
        let strict = strictCategory
        return strict == .newData ? .other : strict
    }

    /// `category` without OMGUI's TODO override, so a UI can offer the "New Data" group.
    public var strictCategory: SourceCategory {
        guard connected else { return .removed }
        if isDownloading { return .downloading }
        if hasData { return hasNewData ? .newData : .downloaded }
        if sessionId == 0 {
            return (batteryLevel ?? 0) < 100 ? .charging : .standby
        }
        return .outbox
    }

    // MARK: - Internal state changes

    func setConnected(_ value: Bool) {
        withLock {
            guard _connected != value else { return }
            _connected = value
            _validData = false
            _ledColor = .unknown
            _downloadStatus = .none
            _downloadValue = 0
            _warning = .none
            _lastUpdate = nil
            _accelConfig = nil
            if value { _info = try? backend.info(deviceId) }
        }
    }

    /// Re-read the static device info (`OmGetDevicePath` and friends) from the backend.
    ///
    /// The volume can be re-mounted at a different path after a commit, so anything that writes to
    /// the device's file system after configuring it must resolve the path again rather than reuse
    /// the one captured when the device was attached.
    @discardableResult
    public func refreshInfo() -> DeviceInfo? {
        guard let info = try? backend.info(deviceId) else { return nil }
        withLock { _info = info }
        return info
    }

    func updateDownloadStatus(_ status: DownloadStatus, value: Int) {
        // The `.part` → `.cwa` rename happens *before* the status is published: a rename that
        // failed is a failed download, and must never reach a UI (or a download log) as
        // "complete". Upstream cannot produce that state because `File.Move` throws.
        var effective = status
        var effectiveValue = value
        var failure: String?
        if status == .complete, finishedDownloading() == nil {
            effective = .error
            effectiveValue = Int(OmError.accessDenied.code)
            failure = withLock { _downloadFailure } ?? "the downloaded file could not be renamed"
        }
        withLock {
            _downloadStatus = effective
            _downloadValue = effectiveValue
            _downloadFailure = failure
            _hasChanged = true
        }
        api.deviceChanged(self, downloadStatus: effective)
    }

    // MARK: - Polling

    /// `OmDevice.Update`. Returns true when anything a UI shows has changed.
    ///
    /// - Parameter resetIfUnresponsive: reset the device after every Nth consecutive failure
    ///   (0 disables), as OMGUI does.
    @discardableResult
    public func update(resetIfUnresponsive: Int = 0, force: Bool = false) -> Bool {
        var changed = false
        let now = Date()

        let (lastUpdate, failed) = withLock { (_lastUpdate, _failedCount) }
        let interval = min(30.0 + Double(failed) * 10.0, 120.0)
        guard force || lastUpdate == nil || now.timeIntervalSince(lastUpdate!) > interval else {
            return withLock {
                let c = _hasChanged
                _hasChanged = false
                return c
            }
        }

        var error = 0

        let newBattery = try? backend.batteryLevel(deviceId)
        withLock { _lastUpdate = now }
        if newBattery == nil { error |= 0x10 }
        if newBattery != withLock({ _batteryLevel }) || (error != 0 && failed == 0) {
            withLock { _batteryLevel = newBattery }
            changed = true
        }

        if error == 0 && !withLock({ _validData }) {
            if let version = try? backend.version(deviceId) {
                withLock { _firmwareVersion = version.firmware; _hardwareVersion = version.hardware }
            } else { error |= 0x01 }

            if let deviceTime = try? backend.time(deviceId) {
                if let date = deviceTime.date() {
                    withLock { _timeDifference = date.timeIntervalSince(now) }
                    // OMGUI's two hardware cautions, both derived from the RTC.
                    var cautionComponents = DateComponents()
                    cautionComponents.year = 2008; cautionComponents.month = 1; cautionComponents.day = 1
                    let caution = Calendar.current.date(from: cautionComponents) ?? .distantPast
                    if withLock({ _warning.rawValue < 1 }) && date < caution {
                        withLock { _warning = .discharged }
                        changed = true
                    }
                    var warnComponents = DateComponents()
                    warnComponents.year = 2000; warnComponents.month = 1; warnComponents.day = 1
                    warnComponents.hour = 0; warnComponents.minute = 15
                    let warn = Calendar.current.date(from: warnComponents) ?? .distantPast
                    if withLock({ _warning.rawValue < 2 }) && date < warn && (newBattery ?? 0) >= 70 {
                        withLock { _warning = .damaged }
                        changed = true
                    }
                }
            } else { error |= 0x02 }

            if let delays = try? backend.delays(deviceId) {
                withLock { _startTime = delays.start; _stopTime = delays.stop }
            } else { error |= 0x04 }

            if let session = try? backend.sessionId(deviceId) {
                withLock { _sessionId = session }
            } else { error |= 0x08 }

            // Not one of OMGUI's five status reads (so it does not feed `error`/`validData`), but
            // read here for the same reason they are: the property grid needs the value and this
            // is the only thread allowed to ask the device for it.
            if let raw = try? backend.accelConfig(deviceId),
               let config = AccelConfig(apiRate: raw.rate, apiRange: raw.range) {
                withLock { _accelConfig = config }
            }

            changed = true
            if error == 0 { withLock { _validData = true } }
        }

        if error != 0 {
            let count = withLock { () -> Int in _failedCount += 1; return _failedCount }
            if resetIfUnresponsive > 0, count % resetIfUnresponsive == 0, !isDownloading {
                _ = try? reset()
            }
        }

        return withLock {
            let c = changed || _hasChanged
            _hasChanged = false
            return c
        }
    }

    // MARK: - Settings and commands

    public func metadata() throws -> String { try backend.metadata(deviceId) }

    public func setMetadata(_ value: String) throws {
        try backend.setMetadata(deviceId, value)
        markChanged()
    }

    /// Ask the device (a blocking `RATE` command). Callers on the main thread want
    /// `cachedAccelConfig` instead.
    public func accelConfig() throws -> AccelConfig {
        let raw = try backend.accelConfig(deviceId)
        guard let config = AccelConfig(apiRate: raw.rate, apiRange: raw.range) else {
            throw OmApiError("Unrecognised accelerometer configuration (rate=\(raw.rate), range=\(raw.range))")
        }
        withLock { _accelConfig = config }
        return config
    }

    public func setAccelConfig(_ config: AccelConfig) throws {
        // OMGUI drops the gyro request on a device with no gyro rather than failing.
        var effective = config
        if !hasSyncGyro { effective.gyro = nil }
        try backend.setAccelConfig(deviceId, rate: effective.apiRate, range: effective.apiRange)
        withLock { _accelConfig = effective }
        markChanged()
    }

    public func maxSamples() throws -> Int { try backend.maxSamples(deviceId) }
    public func setMaxSamples(_ value: Int) throws { try backend.setMaxSamples(deviceId, value) }

    /// `OmDevice.SetLed`.
    @discardableResult
    public func setLed(_ state: LedState) -> Bool {
        withLock { _ledColor = state }
        guard (try? backend.setLed(deviceId, state)) != nil else { return false }
        markChanged()
        api.deviceChanged(self)
        return true
    }

    /// `OmDevice.SetDebug` — OMGUI's "Flash during recording" is `3`, off is `0`.
    @discardableResult
    public func setDebug(_ code: Int) -> Bool {
        (try? backend.setDebug(deviceId, code)) != nil
    }

    /// `OmDevice.SetSessionId`.
    @discardableResult
    public func setSessionId(_ value: UInt32, commit: Bool) -> Bool {
        var ok = (try? backend.setSessionId(deviceId, value)) != nil
        if ok && commit { ok = (try? backend.commit(deviceId)) != nil }
        if ok { withLock { _sessionId = value } }
        markChanged()
        api.deviceChanged(self)
        return ok
    }

    /// `OmDevice.SetInterval` — sets the delays and commits (this is what starts a recording).
    @discardableResult
    public func setInterval(start: OmDateTime, stop: OmDateTime) -> Bool {
        var ok = (try? backend.setDelays(deviceId, start: start, stop: stop)) != nil
        if ok { ok = (try? backend.commit(deviceId)) != nil }
        if ok { withLock { _startTime = start; _stopTime = stop } }
        markChanged()
        api.deviceChanged(self)
        return ok
    }

    /// `OmDevice.AlwaysRecord` — start on disconnect, never stop.
    @discardableResult
    public func alwaysRecord() -> Bool { setInterval(start: .zero, stop: .infinite) }

    /// `OmDevice.NeverRecord`.
    @discardableResult
    public func neverRecord() -> Bool { setInterval(start: .infinite, stop: .infinite) }

    /// `OmDevice.SyncTime`, minus the busy-spin: sets the device clock to the next whole second,
    /// waits for it to settle, verifies it reads back within 5 s, then verifies the clock is
    /// actually ticking.
    ///
    /// Both waits matter. A device whose RTC crystal is dead latches the write and reads it back
    /// unchanged, so a read-back taken milliseconds later passes and the study gets a week stamped
    /// with a frozen clock; upstream sleeps 1200 ms and then polls until the value strictly
    /// increases, giving up after 4 s.
    @discardableResult
    public func syncTime(retries: Int? = nil) -> Bool {
        let timing = syncTimeTiming
        withLock { _warning = .none }
        var remaining = retries ?? timing.retries
        var lastRead: OmDateTime?

        while remaining > 0 {
            remaining -= 1
            // Align to the next second boundary so the device is set on a whole second.
            let now = Date()
            var boundary = (now.timeIntervalSince1970).rounded(.down)
            if timing.alignToSecondBoundary {
                boundary += 1
                Thread.sleep(forTimeInterval: max(0, boundary - now.timeIntervalSince1970))
            }
            let setDate = Date(timeIntervalSince1970: boundary)
            guard (try? backend.setTime(deviceId, OmDateTime(date: setDate))) != nil else { continue }
            // "Wait before checking the time" — the device needs to have taken the write.
            Thread.sleep(forTimeInterval: timing.settle)
            guard let readBack = try? backend.time(deviceId), let readDate = readBack.date() else { continue }
            let difference = readDate.timeIntervalSince(setDate)
            withLock { _timeDifference = difference }
            if abs(difference) > 5 { continue }
            lastRead = readBack
            break
        }

        guard let lastRead else { return false }
        markChanged()
        api.deviceChanged(self)

        // Verify that the clock is ticking: the packed value has to strictly increase, and land
        // within a few seconds of now.
        let checkStart = Date()
        while true {
            guard let current = try? backend.time(deviceId) else { return false }
            if current.raw > lastRead.raw, let currentDate = current.date(),
               Date().timeIntervalSince(currentDate) < 5 {
                return true
            }
            if Date().timeIntervalSince(checkStart) > timing.tickTimeout { return false }
            Thread.sleep(forTimeInterval: timing.tickPollInterval)
        }
    }

    /// `OmDevice.Clear` — the exact sequence OMGUI's Clear button runs.
    ///
    /// `wipe` is `true` for a full NAND wipe (OMGUI's default) and `false` for a quick format
    /// (OMGUI's Shift-click).
    @discardableResult
    public func clear(wipe: Bool) -> Bool {
        var failed = false
        failed = ((try? backend.setSessionId(deviceId, 0)) == nil) || failed
        failed = ((try? backend.setMetadata(deviceId, "")) == nil) || failed
        failed = ((try? backend.setDelays(deviceId, start: .infinite, stop: .infinite)) == nil) || failed
        let defaults = AccelConfig.deviceDefault
        failed = ((try? backend.setAccelConfig(deviceId, rate: defaults.apiRate, range: defaults.apiRange)) == nil) || failed
        failed = ((try? backend.eraseAndCommit(deviceId, level: wipe ? .wipe : .quickFormat)) == nil) || failed

        if !failed {
            withLock {
                _sessionId = 0
                _startTime = .infinite
                _stopTime = .infinite
                _downloadedThisSession = false
                _accelConfig = defaults
            }
            if withLock({ _warning }) != .none { _ = syncTime() }
        }
        markChanged()
        api.deviceChanged(self)
        return !failed
    }

    /// `RESET` — drops the device into the bootloader path OMGUI uses to unstick a device.
    @discardableResult
    public func reset() throws -> Bool {
        try backend.setDebug(deviceId, -1)
        return true
    }

    // MARK: - Download

    /// `OmDevice.BeginDownloading` — downloads to `destination`, then renames to `finalPath`.
    public func beginDownloading(to destination: String, renameTo finalPath: String?) throws {
        withLock {
            _downloadDestination = destination
            _downloadFinalPath = finalPath
            _downloadFailure = nil
            _lastDownloadedPath = nil
        }
        try backend.beginDownload(deviceId, to: destination)
    }

    /// `OmDevice.CancelDownload`.
    public func cancelDownload() { try? backend.cancelDownload(deviceId) }

    /// `OmDevice.FinishedDownloading` — the `.cwa.part` → `.cwa` rename. Returns the final path,
    /// or nil (with `downloadFailure` set) when the download cannot be published.
    ///
    /// As upstream's `File.Move`, an existing destination is *not* removed: the overwrite question
    /// is asked once, at the start of the download (`DownloadFlow`), and a file that appeared in
    /// the workspace since then belongs to somebody else. The move fails and the download is
    /// reported as failed rather than silently destroying it.
    @discardableResult
    public func finishedDownloading() -> String? {
        let (source, destination) = withLock { (_downloadDestination, _downloadFinalPath) }
        guard let source else {
            withLock { _downloadFailure = "no download was in progress" }
            return nil
        }
        var final = source
        if let destination, destination != source {
            do {
                try FileManager.default.moveItem(atPath: source, toPath: destination)
                final = destination
            } catch {
                withLock {
                    _downloadFailure = "could not rename \(source) to \(destination): "
                        + ((error as NSError).localizedFailureReason ?? error.localizedDescription)
                }
                return nil
            }
        }
        guard FileManager.default.fileExists(atPath: final) else {
            withLock { _downloadFailure = "the downloaded file is missing: \(final)" }
            return nil
        }
        withLock {
            _downloadDestination = nil
            _downloadFinalPath = nil
            _downloadedThisSession = true
            _downloadFailure = nil
            _lastDownloadedPath = final
        }
        return final
    }

    /// Bytes in the device's data file.
    public func dataFileSize() throws -> Int { try backend.dataFileSize(deviceId) }

    private func markChanged() { withLock { _hasChanged = true } }
}

extension OmDevice: CustomStringConvertible {
    public var description: String {
        "OmDevice(\(FilenameTemplate.deviceIdString(deviceId)) \(serialId) \(category.groupName))"
    }
}
