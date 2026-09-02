import Foundation

/// A packed AX3/AX6 date/time: `[YYYYYYMM MMDDDDDh hhhhmmmm mmssssss]`.
///
/// Mirrors `OM_DATETIME` and the `OM_DATETIME_*` macros in `omapi.h` (function-like C macros are
/// not imported into Swift, so they are re-expressed here) and `OmApi.OmDateTimePack/Unpack` in
/// upstream `omapinet`.
///
/// The device keeps wall-clock time in whatever zone the host set it to, and OMGUI packs
/// `DateTime.Now` (local). Conversions here therefore default to `TimeZone.current`.
public struct OmDateTime: Hashable, Sendable, CustomStringConvertible {
    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    /// "Infinitely early" (`OM_DATETIME_ZERO`).
    public static let zero = OmDateTime(raw: 0)
    /// "Infinitely late" (`OM_DATETIME_INFINITE`).
    public static let infinite = OmDateTime(raw: 0xFFFF_FFFF)
    /// `OM_DATETIME_MIN_VALID` — 2000-01-01 00:00:00.
    public static let minValid = OmDateTime(year: 2000, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    /// `OM_DATETIME_MAX_VALID` — 2063-12-31 23:59:59.
    public static let maxValid = OmDateTime(year: 2063, month: 12, day: 31, hour: 23, minute: 59, second: 59)

    /// `OM_DATETIME_FROM_YMDHMS`.
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let y = UInt32(year % 100) & 0x3F
        let mo = UInt32(truncatingIfNeeded: month) & 0x0F
        let d = UInt32(truncatingIfNeeded: day) & 0x1F
        let h = UInt32(truncatingIfNeeded: hour) & 0x1F
        let mi = UInt32(truncatingIfNeeded: minute) & 0x3F
        let s = UInt32(truncatingIfNeeded: second) & 0x3F
        raw = (y << 26) | (mo << 22) | (d << 17) | (h << 12) | (mi << 6) | s
    }

    public var year: Int { Int((raw >> 26) & 0x3F) + 2000 }
    public var month: Int { Int((raw >> 22) & 0x0F) }
    public var day: Int { Int((raw >> 17) & 0x1F) }
    public var hour: Int { Int((raw >> 12) & 0x1F) }
    public var minute: Int { Int((raw >> 6) & 0x3F) }
    public var second: Int { Int(raw & 0x3F) }

    /// True when the value denotes a real instant (not `zero`/`infinite`/out of range).
    public var isValid: Bool { raw >= OmDateTime.minValid.raw && raw <= OmDateTime.maxValid.raw }

    /// `OmDateTimeUnpack`. `zero` and `infinite` have no `Date` equivalent.
    public func date(in timeZone: TimeZone = .current) -> Date? {
        guard isValid, month >= 1, month <= 12 else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: c)
    }

    /// `OmDateTimePack`: before 2000 clamps to `zero`, after 2063 clamps to `infinite`.
    public init(date: Date, in timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = c.year ?? 0
        if y < 2000 { self = .zero; return }
        if y > 2063 { self = .infinite; return }
        self.init(year: y, month: c.month ?? 1, day: c.day ?? 1,
                  hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// `OmDateTimeToString` — `"YYYY/MM/DD,hh:mm:ss"`, or `"0"` / `"-1"` for the sentinels.
    public var apiString: String {
        if raw == 0 { return "0" }
        if raw == 0xFFFF_FFFF { return "-1" }
        return String(format: "%04d/%02d/%02d,%02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    public var description: String {
        if raw == 0 { return "(never)" }
        if raw == 0xFFFF_FFFF { return "(always)" }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    /// Parses `"YYYY/MM/DD,hh:mm:ss"` or `"YYYY-MM-DD hh:mm:ss"` (also `0` / `-1`).
    public static func parse(_ value: String) -> OmDateTime? {
        let s = value.trimmingCharacters(in: .whitespaces)
        if s == "0" { return .zero }
        if s == "-1" { return .infinite }
        let parts = s.split(whereSeparator: { "/-,: T".contains($0) }).map(String.init)
        guard parts.count >= 6, let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4]), let sec = Int(parts[5]) else { return nil }
        return OmDateTime(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)
    }
}
