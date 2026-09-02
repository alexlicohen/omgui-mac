import Foundation
import OmApi

/// The bits of a selected device that `DateRangeForm` reasons about.
public struct RecordingDeviceInfo: Sendable, Equatable {
    public var deviceId: UInt32
    public var batteryLevel: Int
    public var hasData: Bool
    public var deviceCapacity: Int64
    public var hasSyncGyro: Bool
    public var firmwareVersion: Int

    public init(deviceId: UInt32, batteryLevel: Int, hasData: Bool,
                deviceCapacity: Int64, hasSyncGyro: Bool, firmwareVersion: Int) {
        self.deviceId = deviceId
        self.batteryLevel = batteryLevel
        self.hasData = hasData
        self.deviceCapacity = deviceCapacity
        self.hasSyncGyro = hasSyncGyro
        self.firmwareVersion = firmwareVersion
    }

    public init(device: OmDevice) {
        self.init(deviceId: device.deviceId,
                  batteryLevel: device.batteryLevel ?? -1,
                  hasData: device.hasData,
                  deviceCapacity: device.deviceCapacity,
                  hasSyncGyro: device.hasSyncGyro,
                  firmwareVersion: device.firmwareVersion ?? 0)
    }
}

/// Headless model of OMGUI's `DateRangeForm` ("Recording Settings").
///
/// Every field, default, coupling rule, warning and validity test is a direct port of
/// `DateRangeForm.cs`; the view is a thin rendering of this type.
public struct RecordingSettings: Sendable, Equatable {

    // MARK: - Static lists (`DateRangeForm.Designer.cs`)

    /// "Freq. (Hz)" combo, in display order. Index 5 (100) is the default.
    public static let frequencies: [SampleRate] = [.hz3200, .hz1600, .hz800, .hz400, .hz200,
                                                   .hz100, .hz50, .hz25, .hz12_5, .hz6_25]
    public static let frequencyLabels = ["3200", "1600", "800", "400", "200",
                                         "100", "50", "25", "12.5", "6.25"]
    /// "Range (±g)" combo. Index 2 (8) is the default.
    public static let ranges: [AccelRange] = [.g2, .g4, .g8, .g16]
    public static let rangeLabels = ["2", "4", "8", "16"]
    /// "Gyro (±dps)" combo; index 0 is `(disabled)`.
    public static let gyroRanges: [GyroRange] = [.off, .dps2000, .dps1000, .dps500, .dps250, .dps125]
    public static let gyroLabels = ["(disabled)", "2000", "1000", "500", "250", "125"]

    public static let sessionIdMaximum: UInt32 = 2_147_483_647
    public static let delayDaysRange = 0...1000
    public static let durationDaysRange = 0...1000
    /// The pickers really do go to −1, which is how the roll-under arithmetic works.
    public static let durationHoursRange = -1...24
    public static let durationMinutesRange = -1...60

    /// `warningMessages` from `DateRangeForm.cs`, in index order.
    public static let warningMessages = [
        "Selected device(s) not fully charged",                                                        // 0
        "Selected device(s) not fully cleared",                                                        // 1
        "Selected device(s) capacity could limit duration",                                            // 2
        "Selected device(s) current battery charge could limit duration",                              // 3
        "Delayed start time is more than 14 days in the future",                                       // 4
        "End time is in the past",                                                                     // 5
        "Start time is in the past",                                                                   // 6
        "Chosen sampling frequency is not officially supported (use at own risk)",                     // 7
        "Chosen start and end times do not make an interval (end <= start)",                           // 8
        "Low power accelerometer produces noisier data (and does not significantly extend duration)",  // 9
        "A gyro-enabled device is being configured for accelerometer data only (no gyro data).",       // 10
    ]
    public static let invalidMessage = "Invalid configuration"

    // MARK: - Fields

    public var sessionId: UInt32 = 0
    public var frequencyIndex = 5
    public var rangeIndex = 2
    public var gyroIndex = 0
    /// `radioButtonImmediately` — "Immediately on Disconnect" (as opposed to "Interval").
    public var immediately = true
    public var startDate: Date
    public var endDate: Date
    public var delayDays = 0
    public var durationDays = 0
    public var durationHours = 0
    public var durationMinutes = 0
    public var flash = false
    public var lowPower = false
    public var unpacked = false
    public var metadata = StudyMetadata()

    /// The devices the dialog was opened for.
    public private(set) var devices: [RecordingDeviceInfo] = []
    /// `hasSyncGyro` — true only when every selected device has one.
    public private(set) var hasSyncGyro = false
    private var minAx6Firmware = Int.max
    private var minAx3Firmware = Int.max

    // MARK: - Construction

    /// `DateRangeForm(title, devices)` — the state after the constructor has run, before any
    /// stored profile is applied.
    public init(devices: [RecordingDeviceInfo], now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        let midnight = cal.startOfDay(for: now)
        startDate = midnight
        endDate = midnight

        self.devices = devices
        // Reproduces upstream's progressive `hasSyncGyro &= ...` loop, minimum-firmware included.
        var gyro = !devices.isEmpty
        for device in devices {
            gyro = gyro && device.hasSyncGyro
            if gyro, device.firmwareVersion > 0, device.firmwareVersion < minAx6Firmware {
                minAx6Firmware = device.firmwareVersion
            }
            if !gyro, device.firmwareVersion > 0, device.firmwareVersion < minAx3Firmware {
                minAx3Firmware = device.firmwareVersion
            }
        }
        hasSyncGyro = gyro
        if hasSyncGyro {
            // AX6: no low-power option, always unpacked.
            lowPower = false
            unpacked = false
        }
        applyDefaults()
    }

    /// The "Defaults" button: 100 Hz, ±8 g.
    public mutating func applyDefaults() {
        frequencyIndex = 5
        rangeIndex = 2
    }

    /// The tail of the constructor, run after any stored profile has been applied:
    /// nudge a zero-delay start up to the current time of day, then set the end from the duration.
    public mutating func finishInitialisation(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        if delayDays == 0 && timeOfDay(startDate, cal) < timeOfDay(now, cal) {
            startDate = cal.startOfDay(for: startDate).addingTimeInterval(timeOfDay(now, cal))
        }
        endDate = startDate.addingTimeInterval(duration)
    }

    private func timeOfDay(_ date: Date, _ calendar: Calendar) -> TimeInterval {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    // MARK: - Derived values

    public var sampleRate: SampleRate { RecordingSettings.frequencies[frequencyIndex] }
    public var accelRange: AccelRange { RecordingSettings.ranges[rangeIndex] }
    public var gyroRange: GyroRange { RecordingSettings.gyroRanges[gyroIndex] }
    /// `(int)float.Parse(...)` — 12.5 becomes 12, 6.25 becomes 6.
    public var samplingFrequency: Int { sampleRate.apiValue }

    /// `Duration` — days/hours/minutes as a `TimeSpan`.
    public var duration: TimeInterval {
        TimeInterval(durationDays) * 86_400 + TimeInterval(durationHours) * 3_600 + TimeInterval(durationMinutes) * 60
    }

    /// The `AccelConfig` the commit writes. The gyro range is only sent to a gyro device.
    public var accelConfig: AccelConfig {
        AccelConfig(rate: sampleRate,
                    range: accelRange,
                    lowPower: lowPower,
                    gyro: (hasSyncGyro && gyroRange != .off) ? gyroRange : nil)
    }

    /// `MetaDataTools.CreateMetaData` over the Study/Subject fields, in OMGUI's key order.
    public var encodedMetadata: String { metadata.encoded }

    // MARK: - Field coupling (the `*_ValueChanged` handlers)

    /// `StartDate` setter — also recomputes `DayDelay` from the date.
    public mutating func setStart(_ value: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        // The pickers drop seconds.
        let day = cal.startOfDay(for: value)
        let components = cal.dateComponents([.hour, .minute], from: value)
        startDate = day.addingTimeInterval(TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: day).day ?? 0
        delayDays = min(max(days, RecordingSettings.delayDaysRange.lowerBound),
                        RecordingSettings.delayDaysRange.upperBound)
    }

    /// `DayDelay` setter — moves the start date, keeping its time of day.
    public mutating func setDelayDays(_ value: Int, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        delayDays = min(max(value, RecordingSettings.delayDaysRange.lowerBound),
                        RecordingSettings.delayDaysRange.upperBound)
        let time = timeOfDay(startDate, cal)
        // Calendar-day arithmetic, so the wall-clock time survives a DST boundary (which is what
        // .NET's `now.Date + TimeSpan.FromDays(n)` does on a zone-less `DateTime`).
        let day = cal.date(byAdding: .day, value: delayDays, to: cal.startOfDay(for: now))
            ?? cal.startOfDay(for: now).addingTimeInterval(TimeInterval(delayDays) * 86_400)
        startDate = day.addingTimeInterval(time)
        endDate = startDate.addingTimeInterval(duration)
    }

    /// `startDuration_ValueChanged` — normalise the three duration pickers, then set the end.
    public mutating func setDuration(days: Int, hours: Int, minutes: Int) {
        durationDays = days
        durationHours = hours
        durationMinutes = minutes

        if durationMinutes < 0 {
            if durationHours == 0 && durationDays == 0 { durationMinutes = 0 }
            else { durationHours -= 1; durationMinutes = 59 }
        }
        if durationMinutes >= 60 { durationMinutes = 0; durationHours += 1 }
        if durationHours < 0 {
            if durationDays == 0 { durationHours = 0 }
            else { durationDays -= 1; durationHours = 23 }
        }
        if durationHours >= 24 { durationHours = 0; durationDays += 1 }
        durationDays = min(max(durationDays, RecordingSettings.durationDaysRange.lowerBound),
                           RecordingSettings.durationDaysRange.upperBound)

        endDate = startDate.addingTimeInterval(duration)
    }

    /// `Duration` setter — upstream adds 30 s before splitting, so a computed duration rounds to
    /// the nearest minute rather than truncating.
    public mutating func setDuration(_ interval: TimeInterval) {
        let v = interval + 30
        let totalDays = Int(v / 86_400)
        let remainder = v - TimeInterval(totalDays) * 86_400
        let hours = Int(remainder / 3_600)
        let minutes = Int((remainder - TimeInterval(hours) * 3_600) / 60)
        durationDays = max(totalDays, 0)
        durationHours = max(hours, 0)
        durationMinutes = max(minutes, 0)
    }

    /// `end_ValueChanged` — the end drives the duration.
    public mutating func setEnd(_ value: Date, calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        let day = cal.startOfDay(for: value)
        let components = cal.dateComponents([.hour, .minute], from: value)
        endDate = day.addingTimeInterval(TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60))
        setDuration(endDate.timeIntervalSince(startDate))
    }

    // MARK: - Estimates (`DateRangeForm.EstimateBatteryLife` / `EstimateCapacityFromBytesFree`)

    public static func estimateBatteryLife(percent: Int, rate: Int) -> Double {
        let percentReserved = 10
        let dischargeRate100Hz = 0.15
        let dischargeRate = rate <= 100 ? dischargeRate100Hz : dischargeRate100Hz * Double(rate) / 100.0
        if percent < percentReserved { return 0 }
        return Double(percent - percentReserved) / dischargeRate * 60 * 60
    }

    public static func estimateCapacity(bytesFree: Int64, rate: Int, unpacked: Bool, axes: Int) -> Double {
        let clustersFree = bytesFree / 32768
        if clustersFree <= 0 { return 0 }
        // Integer division, as in C#.
        let samplesPerSector = (!unpacked && axes == 3) ? 120 : 480 / 2 / axes
        let numSamples = (clustersFree * Int64(32768 / 512) - 2) * Int64(samplesPerSector)
        return Double(numSamples) / (1.0598 * Double(rate))
    }

    // MARK: - Validation (`updateWarningMessages`)

    public struct Validation: Sendable, Equatable {
        /// Indices into `RecordingSettings.warningMessages` that are set.
        public var flags: [Int] = []
        public var invalid = false
        /// `labelRateRangeSetting`.
        public var rateRangeText = ""
        /// The whole `richTextBoxWarning` body, or nil when the box is hidden.
        public var warningText: String?
        public var okEnabled: Bool { !invalid }
    }

    public func validate(now: Date = Date()) -> Validation {
        var result = Validation()
        var flags = Array(repeating: false, count: RecordingSettings.warningMessages.count)
        var invalid = false

        let interval = endDate.timeIntervalSince(startDate)
        let sampFreq = samplingFrequency
        let capacityGyroRange = gyroRange.rawValue
        let axes = capacityGyroRange > 0 ? 6 : 3
        // A gyro device is always unpacked.
        let effectiveUnpacked = hasSyncGyro || unpacked

        for device in devices {
            if device.batteryLevel < 90 { flags[0] = true }
            if device.hasData { flags[1] = true }

            let capacitySeconds = RecordingSettings.estimateCapacity(bytesFree: device.deviceCapacity,
                                                                     rate: sampFreq,
                                                                     unpacked: effectiveUnpacked,
                                                                     axes: axes)
            if interval > capacitySeconds { flags[2] = true }

            let batterySeconds = RecordingSettings.estimateBatteryLife(percent: device.batteryLevel, rate: sampFreq)
            if interval > batterySeconds { flags[3] = true }
        }

        let isInterval = !immediately
        if isInterval && startDate > now.addingTimeInterval(14 * 86_400) { flags[4] = true }
        if isInterval && endDate < now && endDate != startDate {
            flags[5] = true
            invalid = true
        }
        if isInterval && startDate < now.addingTimeInterval(-86_400) { flags[6] = true }
        if sampFreq > 200 || sampFreq < 50 { flags[7] = true }
        if isInterval && startDate >= endDate {
            flags[8] = true
            invalid = true
        }
        if lowPower { flags[9] = true }
        if hasSyncGyro && capacityGyroRange == 0 { flags[10] = true }

        // labelRateRangeSetting
        let sampRange = accelRange.rawValue
        if sampFreq == 100 && sampRange == 8 {
            result.rateRangeText = ""
        } else if hasSyncGyro && minAx6Firmware <= 53 && sampFreq >= 800 && sampFreq <= 1600 {
            result.rateRangeText = "not supported by firmware"
            invalid = true
        } else if hasSyncGyro && sampFreq > 1600 {
            result.rateRangeText = "not supported by device"
            invalid = true
        } else if hasSyncGyro && capacityGyroRange > 0 && sampFreq < 25 {
            result.rateRangeText = "not supported with gyro"
            invalid = true
        } else if !hasSyncGyro && sampFreq < 12 && !unpacked {
            result.rateRangeText = "not supported by firmware in packed mode"
            invalid = true
        } else if sampFreq > 200 || sampFreq < 50 {
            result.rateRangeText = "not guaranteed"
        } else {
            result.rateRangeText = "non-standard"
        }

        var lines: [String] = []
        if invalid { lines.append("\u{2022} " + RecordingSettings.invalidMessage) }
        for (index, set) in flags.enumerated() where set {
            lines.append("\u{2022} " + RecordingSettings.warningMessages[index])
        }

        result.flags = flags.enumerated().compactMap { $1 ? $0 : nil }
        result.invalid = invalid
        result.warningText = lines.isEmpty ? nil : "WARNINGS\n" + lines.joined(separator: "\n") + "\n"
        return result
    }
}
