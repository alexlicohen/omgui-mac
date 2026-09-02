import XCTest
@testable import OmApi

final class OmDateTimeTests: XCTestCase {

    func testPackedLayout() {
        // [YYYYYYMM MMDDDDDh hhhhmmmm mmssssss]
        let value = OmDateTime(year: 2026, month: 9, day: 2, hour: 13, minute: 45, second: 7)
        XCTAssertEqual(value.year, 2026)
        XCTAssertEqual(value.month, 9)
        XCTAssertEqual(value.day, 2)
        XCTAssertEqual(value.hour, 13)
        XCTAssertEqual(value.minute, 45)
        XCTAssertEqual(value.second, 7)
        let expected: UInt32 = (26 << 26) | (9 << 22) | (2 << 17) | (13 << 12) | (45 << 6) | 7
        XCTAssertEqual(value.raw, expected)
    }

    func testSentinelsAndBounds() {
        XCTAssertEqual(OmDateTime.zero.raw, 0)
        XCTAssertEqual(OmDateTime.infinite.raw, 0xFFFF_FFFF)
        XCTAssertEqual(OmDateTime.minValid.raw, 0x0042_0000)   // 2000-01-01 00:00:00
        XCTAssertEqual(OmDateTime.maxValid.raw, 0xFF3F_7EFB)   // 2063-12-31 23:59:59
        XCTAssertFalse(OmDateTime.zero.isValid)
        XCTAssertFalse(OmDateTime.infinite.isValid)
        XCTAssertTrue(OmDateTime.minValid.isValid)
        XCTAssertTrue(OmDateTime.maxValid.isValid)
        XCTAssertNil(OmDateTime.zero.date())
        XCTAssertNil(OmDateTime.infinite.date())
    }

    func testDateRoundTrip() {
        let value = OmDateTime(year: 2026, month: 9, day: 2, hour: 13, minute: 45, second: 7)
        let date = try! XCTUnwrap(value.date(in: .gmt))
        XCTAssertEqual(OmDateTime(date: date, in: .gmt), value)
    }

    func testPackClampsOutOfRangeYears() {
        // OmDateTimePack: before 2000 is "infinitely early", after 2063 "infinitely late".
        var components = DateComponents()
        components.year = 1999; components.month = 6; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        XCTAssertEqual(OmDateTime(date: calendar.date(from: components)!, in: .gmt), .zero)
        components.year = 2099
        XCTAssertEqual(OmDateTime(date: calendar.date(from: components)!, in: .gmt), .infinite)
    }

    func testStringForms() {
        let value = OmDateTime(year: 2026, month: 9, day: 2, hour: 13, minute: 45, second: 7)
        XCTAssertEqual(value.apiString, "2026/09/02,13:45:07")
        XCTAssertEqual(value.description, "2026-09-02 13:45:07")
        XCTAssertEqual(OmDateTime.zero.apiString, "0")
        XCTAssertEqual(OmDateTime.infinite.apiString, "-1")
    }

    func testParse() {
        let expected = OmDateTime(year: 2026, month: 9, day: 2, hour: 13, minute: 45, second: 7)
        XCTAssertEqual(OmDateTime.parse("2026/09/02,13:45:07"), expected)
        XCTAssertEqual(OmDateTime.parse("2026-09-02 13:45:07"), expected)
        XCTAssertEqual(OmDateTime.parse("0"), .zero)
        XCTAssertEqual(OmDateTime.parse("-1"), .infinite)
        XCTAssertNil(OmDateTime.parse("not a date"))
    }
}
