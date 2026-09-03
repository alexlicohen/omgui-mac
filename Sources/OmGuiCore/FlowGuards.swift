import Foundation
import OmApi

/// The guards a foreground device flow runs, in one testable place.
///
/// Each of these used to live only in `AppModel` (the `OmGui` executable target), which no
/// automated check reaches: `swift test` never loads it and `--self-test` is not wired into any
/// script. Deleting one of them left the suite green. They are here so a test can hold them, and
/// so the GUI and the CLI enforce the *same* rule rather than two drifting copies of it.

// MARK: - `--self-test` may only ever run against the mock backend

public enum SelfTestGuard {

    /// `--self-test` drives Clear/Wipe, Record and Stop over every attached device with every
    /// message box auto-answered. Against real hardware that erases whatever is plugged in, so the
    /// run is refused before the API is even started.
    public static func mustRefuse(selfTestRequested: Bool, backend: DeviceBackend) -> Bool {
        guard selfTestRequested else { return false }
        return !(backend is MockBackend)
    }
}

// MARK: - `BlockBackgroundTasks` / `EnableBackgroundTasks`

/// The 100 ms poll's on/off switch and its in-flight flag (`MainForm.refreshTimer` plus
/// `backgroundWorkerUpdate.IsBusy`).
///
/// Without this the poll runs `update()` -- an `ID`/`BATT`/`TIME` round trip, and a `reset()` after
/// every third failure -- on one device while a flow is part-way through configuring another.
/// `OmPortAcquire` refuses the second opener outright, so the visible result is a device that took
/// its delays but not its interval: configured, not recording.
@MainActor
public final class BackgroundTaskGate {

    /// How long a foreground flow waits for an in-flight poll to finish.
    ///
    /// Upstream's `BlockBackgroundTasks` spins with no cap at all. A first full `update()` issues
    /// up to seven serial commands with libomapi's 2 s timeout each (SAMPLE, ID, TIME, HIBERNATE,
    /// STOP, SESSION, RATE -- `OmGetDelays` is two of them), so anything under ~15 s expires
    /// *during a perfectly normal poll*. The poll is bounded by those timeouts, so this only ever
    /// fires when something is genuinely wedged -- and then it is fatal to the flow, never a
    /// warning line the flow runs past.
    public static let defaultDrainTimeout: TimeInterval = 20

    public private(set) var blocked = false
    public private(set) var pollInFlight = false
    public var drainTimeout: TimeInterval
    public var drainPollInterval: TimeInterval

    public init(drainTimeout: TimeInterval = BackgroundTaskGate.defaultDrainTimeout,
                drainPollInterval: TimeInterval = 0.02) {
        self.drainTimeout = drainTimeout
        self.drainPollInterval = drainPollInterval
    }

    /// `MainForm.BlockBackgroundTasks`.
    public func block() { blocked = true }

    /// `MainForm.EnableBackgroundTasks`.
    public func enable() { blocked = false }

    /// `refreshTimer_Tick`'s two conditions: no poll while a foreground flow owns the devices, and
    /// never two polls at once. Returns false when the tick must do nothing.
    public func beginPoll() -> Bool {
        guard !blocked, !pollInFlight else { return false }
        pollInFlight = true
        return true
    }

    public func endPoll() { pollInFlight = false }

    /// Wait for an in-flight poll to finish.
    ///
    /// Returns false when it had not finished within `drainTimeout`. That is fatal for the caller:
    /// it must abandon the flow (tear the sheet down, re-enable the poll, tell the operator) and
    /// never run the flow alongside a live poll.
    public func drainPoll(now: @escaping @MainActor () -> Date = { Date() }) async -> Bool {
        let deadline = now().addingTimeInterval(drainTimeout)
        while pollInFlight {
            if now() >= deadline { return !pollInFlight }
            let nanoseconds = UInt64(max(0.001, drainPollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        return true
    }
}

// MARK: - Clear's recording-with-data exclusion

/// The one device state OMGUI's Clear button refuses outright: recording *and* already holding
/// data.
///
/// `DeviceToolbarState.clear` is `clearable == total`, where clearable is
/// `(data && stopped) || (!data && configured)` (`DeviceListViewUpdateEnabled`) -- so a device that
/// is mid-recording with data on it is excluded and the button greys out. Erasing one destroys a
/// recording in progress, which is not recoverable, so the CLI has to make the same exclusion
/// rather than infer it from a predicate written for a toolbar.
public enum ClearGuard {

    public static func isRecordingWithData(_ device: OmDevice) -> Bool {
        device.isRecording != .stopped && device.hasData
    }

    /// The same question asked of a rendered row, so the toolbar and the CLI cannot drift.
    public static func isRecordingWithData(_ row: DeviceRow) -> Bool {
        row.isRecordingNow && row.hasData
    }

    public static func recordingWithData(_ devices: [OmDevice]) -> [OmDevice] {
        devices.filter(isRecordingWithData)
    }

    public static func refusalMessage(ids: [String]) -> String {
        "\(ids.count) selected device(s) are recording and already hold data: \(ids.joined(separator: ", "))."
            + " OMGUI's Clear button refuses these -- erasing one destroys a recording in progress."
    }
}

// MARK: - The configuration log

/// `MainForm.cs:247-269`'s `-configlog` append, which silently loses the `AX3-CONFIG-OK/ERROR`
/// rows a site files against a recording when the path is not writable.
public enum ConfigLog {

    /// Appends every line, returning the path that could not be written (nil when all of them
    /// were, or when there is no log configured).
    public static func append(_ lines: [String], to path: String?) -> String? {
        guard let path, !lines.isEmpty else { return nil }
        var failed = false
        for line in lines where !DownloadLog.append(line, to: path) { failed = true }
        return failed ? path : nil
    }
}

// MARK: - The preflight Record and Clear share

/// What `MainForm` checks before a flow touches hardware, in its order: nothing downloading
/// (`EnsureNoSelectedDownloading`), then `CheckFirmware`, then -- for Clear -- the toolbar's
/// recording-with-data exclusion.
///
/// The GUI and the CLI both go through this, so the firmware blacklist cannot be enforced in one
/// and missing from the other.
@MainActor
public enum DeviceFlowPreflight {

    public enum Refusal: Equatable {
        /// A download is in progress on some of the selection.
        case downloading(ids: [String], total: Int)
        /// The operator cancelled `CheckFirmware`, or would not continue without it.
        case firmware
        /// Clear only: devices that are recording and hold data.
        case recordingWithData(ids: [String])

        public var description: String {
            switch self {
            case .downloading(let ids, let total):
                return FlowMessages.downloadInProgress(downloading: ids.count, total: total)
                    + " (\(ids.joined(separator: ", ")))"
            case .firmware:
                return "Firmware check not passed."
            case .recordingWithData(let ids):
                return ClearGuard.refusalMessage(ids: ids)
            }
        }
    }

    /// - Parameters:
    ///   - refuseRecordingWithData: Clear's toolbar exclusion. The GUI leaves this off because
    ///     `DeviceToolbarState.clear` has already greyed the button out for those devices; a CLI
    ///     has no such gate, so it turns it on unless the operator passed `--force`.
    ///   - readVersion: how to fetch a firmware version that has not been polled yet. The GUI
    ///     passes nil -- the poll thread owns device I/O -- so unknown versions become a question
    ///     for the operator instead.
    public static func run(devices: [OmDevice],
                           blacklist: FirmwareBlacklist,
                           prompt: any UserPrompting,
                           log: ((String) -> Void)? = nil,
                           refuseRecordingWithData: Bool = false,
                           readVersion: ((OmDevice) -> Int?)? = nil) -> Refusal? {
        let downloading = devices.filter(\.isDownloading)
        if !downloading.isEmpty {
            prompt.warn(title: FlowMessages.downloadInProgressTitle,
                        message: FlowMessages.downloadInProgress(downloading: downloading.count,
                                                                 total: devices.count))
            return .downloading(ids: downloading.map { FilenameTemplate.deviceIdString($0.deviceId) },
                                total: devices.count)
        }

        if refuseRecordingWithData {
            let unsafe = ClearGuard.recordingWithData(devices)
            if !unsafe.isEmpty {
                return .recordingWithData(ids: unsafe.map { FilenameTemplate.deviceIdString($0.deviceId) })
            }
        }

        if checkFirmware(devices, blacklist: blacklist, prompt: prompt, log: log,
                         readVersion: readVersion) {
            return .firmware
        }
        return nil
    }
}
