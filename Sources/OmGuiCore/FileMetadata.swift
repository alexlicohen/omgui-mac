import Foundation
import OmApi

/// The metadata map OMGUI builds for a `.cwa` file (`MetaDataTools.MetadataFromFile`): the decoded
/// annotation under its display names, plus the header's own identity and configuration.
///
/// Used for two things: the download-filename template expansion (and its identity verification),
/// and the file property grid.
public struct FileMetadata: Sendable, Equatable {

    public var deviceId: UInt32
    public var sessionId: UInt32
    /// `3200 / (1 << (15 - (code & 0x0f)))`.
    public var samplingRate: Double?
    /// `16 >> (code >> 6)`.
    public var samplingRange: Int?
    public var startTime: Date?
    public var endTime: Date?
    /// Decoded annotation, keyed by OMGUI display name (`StudyCode`, `SubjectSite`, …).
    public var named: [String: String]

    /// `{DeviceId}` as OMGUI formats it in the map: `%05u`.
    public var deviceIdText: String { FilenameTemplate.deviceIdString(deviceId) }
    /// `{SessionId}`: `%010u`.
    public var sessionIdText: String { FilenameTemplate.sessionIdString(sessionId) }

    /// The full `metadataMap`, in the same shape `MainForm` consumes.
    public var map: [String: String] {
        var out = named
        out["DeviceId"] = deviceIdText
        out["SessionId"] = sessionIdText
        if let samplingRate { out["SamplingRate"] = FileMetadata.numberText(samplingRate) }
        if let samplingRange { out["SamplingRange"] = String(samplingRange) }
        if let startTime {
            out["StartTime"] = FileMetadata.text(startTime, "yyyy-MM-dd HH:mm:ss")
            out["StartTimeNumeric"] = FileMetadata.text(startTime, "yyyyMMddHHmmss")
        }
        if let endTime {
            out["EndTime"] = FileMetadata.text(endTime, "yyyy-MM-dd HH:mm:ss")
            out["EndTimeNumeric"] = FileMetadata.text(endTime, "yyyyMMddHHmmss")
        }
        return out
    }

    static func text(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Header offset of the `RATE` code byte in a CWA `MD` block.
    public static let samplingRateCodeOffset = 36

    /// Read a `.cwa` file's header. Returns nil when the reader rejects it.
    public init?(path: String) {
        guard let reader = try? OmReader(path: path) else { return nil }
        defer { reader.close() }

        deviceId = reader.deviceId
        sessionId = reader.sessionId
        named = MetadataTools.namedMap(reader.metadata)
        startTime = reader.startTime.date()
        endTime = reader.endTime.date()

        // libomapi's reader does not expose the header rate byte, so read it directly.
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: FileMetadata.samplingRateCodeOffset + 1),
               data.count > FileMetadata.samplingRateCodeOffset {
                let code = data[FileMetadata.samplingRateCodeOffset]
                let rate = 3200.0 / Double(1 << (15 - Int(code & 0x0F)))
                let range = 16 >> Int(code >> 6)
                if rate != 0 { samplingRate = rate }
                if range != 0 { samplingRange = range }
            }
        }
    }

    public init(deviceId: UInt32, sessionId: UInt32, samplingRate: Double? = nil,
                samplingRange: Int? = nil, startTime: Date? = nil, endTime: Date? = nil,
                named: [String: String] = [:]) {
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.samplingRate = samplingRate
        self.samplingRange = samplingRange
        self.startTime = startTime
        self.endTime = endTime
        self.named = named
    }
}

/// One "Category / Name = Value" row of a property grid.
public struct PropertyRow: Sendable, Hashable, Identifiable {
    public var category: String
    public var name: String
    public var value: String
    public var id: String { category + "/" + name }

    public init(_ category: String, _ name: String, _ value: String) {
        self.category = category
        self.name = name
        self.value = value
    }
}

public enum PropertyGrid {

    /// `MetadataObject` — the file property grid, in declaration order.
    public static func rows(for metadata: FileMetadata?) -> [PropertyRow] {
        guard let metadata else { return [] }
        let map = metadata.map
        func value(_ key: String) -> String { map[key] ?? "" }
        return [
            PropertyRow("Recording", "Device ID", metadata.deviceIdText),
            PropertyRow("Recording", "Session ID", metadata.sessionIdText),
            PropertyRow("Recording", "Sampling Rate", value("SamplingRate")),
            PropertyRow("Recording", "Sampling Range", value("SamplingRange")),
            PropertyRow("Recording", "Time Start", value("StartTime")),
            PropertyRow("Recording", "Time End", value("EndTime")),
            PropertyRow("Study", "Centre", value("StudyCentre")),
            PropertyRow("Study", "Code", value("StudyCode")),
            PropertyRow("Study", "Investigator", value("StudyInvestigator")),
            PropertyRow("Study", "Exercise Type", value("StudyExerciseType")),
            PropertyRow("Study", "Operator", value("StudyOperator")),
            PropertyRow("Study", "Notes", value("StudyNotes")),
            PropertyRow("Subject", "Site", value("SubjectSite")),
            PropertyRow("Subject", "Code", value("SubjectCode")),
            PropertyRow("Subject", "Sex", value("SubjectSex")),
            PropertyRow("Subject", "Height", value("SubjectHeight")),
            PropertyRow("Subject", "Weight", value("SubjectWeight")),
            PropertyRow("Subject", "Handedness", value("SubjectHandedness")),
            PropertyRow("Subject", "Notes", value("SubjectNotes")),
        ]
    }

    /// A multi-device selection, merged the way a WinForms `PropertyGrid` merges
    /// `SelectedObjects`: shared values are shown, differing ones become an empty cell.
    public static func rows(forDevices devices: [OmDevice]) -> [PropertyRow] {
        guard let first = devices.first else { return [] }
        var merged = rows(for: first)
        for device in devices.dropFirst() {
            let other = rows(for: device)
            let lookup = Dictionary(other.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
            for index in merged.indices where lookup[merged[index].id] != merged[index].value {
                merged[index].value = ""
            }
        }
        return merged
    }

    /// The device property grid — every `OmDevice` field OMGUI's `propertyGridDevice` exposes.
    public static func rows(for device: OmDevice) -> [PropertyRow] {
        let info = device.info
        func time(_ value: OmDateTime) -> String { value.description }
        var rows: [PropertyRow] = [
            PropertyRow("Device", "Device ID", FilenameTemplate.deviceIdString(device.deviceId)),
            PropertyRow("Device", "Serial ID", device.serialId),
            PropertyRow("Device", "Connected", device.connected ? "True" : "False"),
            PropertyRow("Device", "Port", device.port),
            PropertyRow("Device", "Device Path", device.devicePath),
            PropertyRow("Device", "Filename", device.dataFilePath),
            PropertyRow("Device", "Has Sync Gyro", device.hasSyncGyro ? "True" : "False"),
            PropertyRow("Device", "Device Capacity", String(device.deviceCapacity)),
            PropertyRow("Status", "Session ID", device.sessionId == .max ? "-" : String(device.sessionId)),
            PropertyRow("Status", "Battery Level", device.batteryLevel.map { String($0) } ?? "-"),
            PropertyRow("Status", "LED Color", String(describing: device.ledColor)),
            PropertyRow("Status", "Firmware Version", device.firmwareVersion.map { String($0) } ?? "-"),
            PropertyRow("Status", "Hardware Version", device.hardwareVersion.map { String($0) } ?? "-"),
            PropertyRow("Status", "Valid Data", device.validData ? "True" : "False"),
            PropertyRow("Status", "Device Warning", String(device.warning.rawValue)),
            PropertyRow("Status", "Time Difference",
                        device.timeDifference.map { String(format: "%.0f s", $0) } ?? "-"),
            PropertyRow("Recording", "Start Time", time(device.startTime)),
            PropertyRow("Recording", "Stop Time", time(device.stopTime)),
            PropertyRow("Recording", "Is Recording", String(describing: device.isRecording)),
            PropertyRow("Recording", "Has Data", device.hasData ? "True" : "False"),
            PropertyRow("Recording", "Has New Data", device.hasNewData ? "True" : "False"),
            PropertyRow("Download", "Download Status", String(describing: device.downloadStatus)),
            PropertyRow("Download", "Download Value", String(device.downloadValue)),
        ]
        // The cached value, never a live `RATE` command: this runs on the main thread from every
        // selection change and every device-changed callback, and the device's serial port is
        // exclusive — asking here collides with whatever flow currently owns the device.
        if let config = device.cachedAccelConfig {
            rows.append(PropertyRow("Recording", "Sampling Rate", config.rate.displayString))
            rows.append(PropertyRow("Recording", "Sampling Range", String(config.range.rawValue)))
            if let gyro = config.gyro, gyro != .off {
                rows.append(PropertyRow("Recording", "Gyro Range", String(gyro.rawValue)))
            }
        }
        if info == nil {
            rows.append(PropertyRow("Device", "Info", "(unavailable)"))
        }
        return rows
    }
}
