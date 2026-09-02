import Foundation
import OmApi

/// The four foreground colours OMGUI paints device-list cells with (`MainForm.DeviceListViewCreateItem`).
public enum CellColor: String, Sendable {
    case normal, red, orange, green
}

/// One rendered row of `devicesListView`, computed exactly as `DeviceListViewCreateItem` does.
///
/// Deliberately a value type with no AppKit types in it, so the column text and colours can be
/// asserted in tests.
public struct DeviceRow: Sendable, Identifiable, Equatable {
    public var deviceId: UInt32
    /// "Device" — `{0:00000}`.
    public var deviceText: String
    /// "Session Id" — `-` when unread.
    public var sessionText: String
    /// "Battery".
    public var batteryText: String
    /// "Download".
    public var downloadText: String
    /// "Recording".
    public var recordingText: String
    public var batteryColor: CellColor
    public var downloadColor: CellColor
    public var recordingColor: CellColor
    /// Index into OMGUI's `Circle0.png`…`Circle7.png`; 8 is the grey "unknown" circle.
    public var ledIconIndex: Int
    public var category: SourceCategory
    /// Enable-state inputs (`devicesListViewUpdateEnabled`).
    public var hasData: Bool
    public var isDownloading: Bool
    public var isRecordingNow: Bool
    public var isStoppedWithDataOrConfiguredWithout: Bool

    public var id: UInt32 { deviceId }

    /// `Interval {0:dd/MM/yy HH:mm:ss}-{1:dd/MM/yy HH:mm:ss}`.
    static func intervalFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "dd/MM/yy HH:mm:ss"
        return formatter
    }

    /// The "Recording" column text.
    ///
    /// Upstream compares the packed times directly here (it does *not* use `IsRecording`, which is
    /// what the colour uses), so an interval that has already elapsed still prints its dates.
    public static func recordingText(start: OmDateTime, stop: OmDateTime, hasData: Bool) -> String {
        var text: String
        if start.raw >= stop.raw {
            text = "Stopped"
        } else if start == .zero && stop == .infinite {
            text = "Always"
        } else {
            let formatter = intervalFormatter()
            let startText = start.date().map(formatter.string(from:)) ?? start.description
            let stopText = stop.date().map(formatter.string(from:)) ?? stop.description
            text = "Interval \(startText)-\(stopText)"
        }
        if hasData { text += " (with data)" }
        return text
    }

    /// The "Download" column text.
    public static func downloadText(status: DownloadStatus, value: Int) -> String {
        switch status {
        case .cancelled: return "Cancelled"
        case .complete: return "Complete"
        case .error: return String(format: "Error (0x%X)", value)
        case .progress: return "\(value)%"
        case .none: return ""
        }
    }

    /// The "Battery" column text, including the `-timecheck` warning prefixes.
    public static func batteryText(level: Int?, warning: DeviceWarning, timeCheck: Bool) -> String {
        let base = (level.map { $0 < 0 } ?? true) ? "-" : "\(level!)%"
        guard timeCheck else { return base }
        switch warning {
        case .damaged:
            return "DAMAGED? (\(base)) - indications of possibly damaged device battery or clock, check carefully."
        case .discharged:
            return "DISCHARGED? (\(base)) - allowing full discharge can damage battery."
        case .none:
            return base
        }
    }

    /// Battery colour. Upstream's final `else` also catches an unknown (negative) level, so a
    /// device whose battery has not been read yet shows "-" in green.
    public static func batteryColor(level: Int?) -> CellColor {
        let value = level ?? -1
        if value >= 0 && value < 33 { return .red }
        if value >= 33 && value < 66 { return .orange }
        return .green
    }

    public static func downloadColor(status: DownloadStatus) -> CellColor {
        switch status {
        case .cancelled, .error: return .red
        case .progress: return .orange
        case .complete: return .green
        case .none: return .normal
        }
    }

    /// Build the row for one device.
    public init(device: OmDevice, timeCheck: Bool, now: Date = Date()) {
        let downloading = device.isDownloading
        let data = downloading || device.hasData
        let start = device.startTime
        let stop = device.stopTime

        deviceId = device.deviceId
        deviceText = FilenameTemplate.deviceIdString(device.deviceId)
        sessionText = device.sessionId == UInt32.max ? "-" : String(device.sessionId)
        batteryText = DeviceRow.batteryText(level: device.batteryLevel,
                                            warning: device.warning,
                                            timeCheck: timeCheck)
        downloadText = DeviceRow.downloadText(status: device.downloadStatus, value: device.downloadValue)
        recordingText = DeviceRow.recordingText(start: start, stop: stop, hasData: data)
        batteryColor = DeviceRow.batteryColor(level: device.batteryLevel)
        downloadColor = DeviceRow.downloadColor(status: device.downloadStatus)
        recordingColor = device.isRecording == .stopped ? .red : .green
        ledIconIndex = device.ledColor.iconIndex
        category = device.category
        hasData = data
        isDownloading = downloading

        // `devicesListViewUpdateEnabled`: "recording" here means start < stop and the stop has not
        // passed, and the Clear predicate is "has data and stopped, or no data and configured".
        let stopDate = stop.date()
        let stopInFuture = stopDate.map { $0 >= now } ?? (stop == .infinite)
        isRecordingNow = start.raw < stop.raw && stopInFuture
        let stopped = start.raw >= stop.raw || !stopInFuture
        isStoppedWithDataOrConfiguredWithout = (data && stopped) || (!data && start.raw < stop.raw)
    }
}

/// Enabled state of the device toolbar, from the current selection (`devicesListViewUpdateEnabled`).
public struct DeviceToolbarState: Sendable, Equatable {
    public var download = false
    public var cancel = false
    public var clear = false
    public var record = false
    public var stop = false
    public var identify = false

    public init() {}

    public init(selection rows: [DeviceRow]) {
        let total = rows.count
        guard total > 0 else { return }
        let data = rows.filter(\.hasData).count
        let downloading = rows.filter(\.isDownloading).count
        let recording = rows.filter(\.isRecordingNow).count
        let clearable = rows.filter(\.isStoppedWithDataOrConfiguredWithout).count

        // Download: all have data & none recording & none downloading
        download = data == total && recording == 0 && downloading == 0
        // Clear: all "stopped with data / configured without data" & none downloading
        clear = clearable == total && downloading == 0
        // Cancel: some downloading
        cancel = downloading > 0
        // Stop: some recording & none downloading
        stop = recording > 0 && downloading == 0
        // Record: none have data & none downloading
        record = data == 0 && downloading == 0
        // Identify: any selection
        identify = true
    }
}

public extension SourceCategory {
    /// The order `DeviceListView` adds its groups in.
    static let displayOrder: [SourceCategory] = [
        .other, .newData, .downloading, .downloaded, .charging, .standby, .outbox, .removed, .file,
    ]

    var displayIndex: Int { SourceCategory.displayOrder.firstIndex(of: self) ?? 0 }
}

/// The device list's group header.
///
/// `DeviceListView()` registers all nine category groups ("Devices", "New Data", ... "Files"), but
/// `MainForm` never assigns one: `DeviceListViewItemUpdate` and `DeviceListViewCreateItem` both
/// carry the assignment commented out ("TS - Don't need this anymore because there aren't groups in
/// one list view but a list view each", `MainForm.cs:367`/`:397`). Every item therefore lands in
/// the `ListView`'s implicit default group, which is what the MOP's V1.0.0.45 screenshot shows:
/// one header reading "Default" with the connected devices under it. The nine registered groups
/// stay empty for the life of the process, so the port renders exactly one section.
public enum DeviceGroup {
    /// The header text a WinForms `ListView` gives its default group.
    public static let defaultTitle = "Default"
    /// The section id (the group's key, not its header text).
    public static let defaultIdentifier = "default"
}
