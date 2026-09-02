import Foundation

/// `OM_LED_STATE`. `unknown` is `omapinet`'s addition for "not read yet".
public enum LedState: Int32, Sendable, CaseIterable {
    case unknown = -2
    case auto = -1
    case off = 0
    case blue = 1
    case green = 2
    case cyan = 3
    case red = 4
    case magenta = 5
    case yellow = 6
    case white = 7

    /// Index into OMGUI's `Circle0.png`…`Circle7.png`; 8 is `Circle.png` (unknown).
    public var iconIndex: Int { (0...7).contains(Int(rawValue)) ? Int(rawValue) : 8 }
}

/// `OM_ERASE_LEVEL`.
public enum EraseLevel: Int32, Sendable {
    case none = 0
    case delete = 1
    case quickFormat = 2
    case wipe = 3
}

/// `OM_DOWNLOAD_STATUS`.
public enum DownloadStatus: Int32, Sendable {
    case none = 0
    case error = 1
    case progress = 2
    case complete = 3
    case cancelled = 4
}

/// `OM_DEVICE_STATUS`.
public enum DeviceConnectionStatus: Int32, Sendable {
    case removed = 0
    case connected = 1
}

/// `OmSource.SourceCategory` — the groups `DeviceListView.cs` puts rows into.
public enum SourceCategory: String, Sendable, CaseIterable {
    case other = "Devices"
    case newData = "New Data"
    case downloading = "Downloading"
    case downloaded = "Downloaded"
    case charging = "Charging"
    case standby = "Standby"
    case outbox = "Outbox"
    case removed = "Removed"
    case file = "Files"

    /// Group heading text, exactly as OMGUI labels it.
    public var groupName: String { rawValue }
}

/// `OmDevice.RecordStatus`.
public enum RecordStatus: Sendable, Equatable {
    case stopped
    case always
    case interval
}

/// `OmDevice.DeviceWarning` — 0 none, 1 discharged, 2 damaged.
public enum DeviceWarning: Int, Sendable {
    case none = 0
    /// The RTC was reset, so the battery was allowed to flatten completely.
    case discharged = 1
    /// The RTC reset very recently yet the battery reports a high charge.
    case damaged = 2

    /// The prefix OMGUI puts in front of the battery column text.
    public var batteryPrefix: String {
        switch self {
        case .none: return ""
        case .discharged: return "DISCHARGED? "
        case .damaged: return "DAMAGED? "
        }
    }
}

/// Static identity of an attached device, as the device finder reports it.
public struct DeviceInfo: Hashable, Sendable {
    /// Numeric device id (trailing digits of the USB serial number).
    public var deviceId: UInt32
    /// Full USB serial number, e.g. `"CWA17_01234"` / `"AX617_01234"`.
    public var serialId: String
    /// CDC serial port, e.g. `/dev/cu.usbmodem14201`.
    public var port: String
    /// Mounted mass-storage volume, e.g. `/Volumes/AX317_01234`.
    public var volumePath: String
    /// `<volumePath>/CWA-DATA.CWA`.
    public var dataFilePath: String

    public init(deviceId: UInt32, serialId: String, port: String, volumePath: String, dataFilePath: String? = nil) {
        self.deviceId = deviceId
        self.serialId = serialId
        self.port = port
        self.volumePath = volumePath
        self.dataFilePath = dataFilePath ?? (volumePath as NSString).appendingPathComponent("CWA-DATA.CWA")
    }

    /// `OmDevice.HasSyncGyro` — AX6 units, plus the `CWA64` prototype firmware.
    public var hasSyncGyro: Bool { serialId.hasPrefix("AX6") || serialId.hasPrefix("CWA64") }
}

/// Something a backend reports asynchronously.
public enum DeviceEvent: Sendable {
    case connected(UInt32)
    case removed(UInt32)
    case download(deviceId: UInt32, status: DownloadStatus, value: Int)
}
