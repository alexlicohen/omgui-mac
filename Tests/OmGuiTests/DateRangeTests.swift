import Foundation
import OmGuiCore
import XCTest

/// The start / delay / duration / end coupling `DateRangeForm` implements in its event handlers.
final class DateRangeTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()

    /// A fixed "now" at 10:30 local time.
    private lazy var now: Date = {
        var components = DateComponents()
        components.year = 2027; components.month = 3; components.day = 10
        components.hour = 10; components.minute = 30; components.second = 45
        return calendar.date(from: components)!
    }()

    private func fresh() -> RecordingSettings {
        RecordingSettings(devices: [.ax3()], now: now, calendar: calendar)
    }

    func testStartStartsAtMidnightThenSnapsToNowAtZeroDelay() {
        var model = fresh()
        XCTAssertEqual(model.startDate, calendar.startOfDay(for: now))
        model.finishInitialisation(now: now, calendar: calendar)
        // Time-of-day is copied from `now`, including seconds.
        let expected: TimeInterval = 10 * 3600 + 30 * 60 + 45
        let actual = model.startDate.timeIntervalSince(calendar.startOfDay(for: now))
        XCTAssertEqual(actual, expected, accuracy: 0.001)
        XCTAssertEqual(model.endDate, model.startDate)
    }

    func testDurationDrivesTheEndDate() {
        var model = fresh()
        model.setStart(now, now: now, calendar: calendar)
        model.setDuration(days: 7, hours: 2, minutes: 30)
        let expectedDuration: TimeInterval = 7 * 86_400 + 2 * 3600 + 30 * 60
        XCTAssertEqual(model.duration, expectedDuration)
        XCTAssertEqual(model.endDate, model.startDate.addingTimeInterval(model.duration))
    }

    func testMinutesRollOverIntoHours() {
        var model = fresh()
        model.setDuration(days: 0, hours: 1, minutes: 60)
        XCTAssertEqual(model.durationHours, 2)
        XCTAssertEqual(model.durationMinutes, 0)
    }

    func testMinutesRollUnderBorrowsAnHour() {
        var model = fresh()
        model.setDuration(days: 0, hours: 3, minutes: -1)
        XCTAssertEqual(model.durationHours, 2)
        XCTAssertEqual(model.durationMinutes, 59)
    }

    func testMinutesClampAtZeroWhenThereIsNothingToBorrow() {
        var model = fresh()
        model.setDuration(days: 0, hours: 0, minutes: -1)
        XCTAssertEqual(model.durationDays, 0)
        XCTAssertEqual(model.durationHours, 0)
        XCTAssertEqual(model.durationMinutes, 0)
    }

    func testHoursRollOverIntoDays() {
        var model = fresh()
        model.setDuration(days: 1, hours: 24, minutes: 0)
        XCTAssertEqual(model.durationDays, 2)
        XCTAssertEqual(model.durationHours, 0)
    }

    func testHoursRollUnderBorrowsADay() {
        var model = fresh()
        model.setDuration(days: 2, hours: -1, minutes: 0)
        XCTAssertEqual(model.durationDays, 1)
        XCTAssertEqual(model.durationHours, 23)
    }

    func testEndDateDrivesTheDuration() {
        var model = fresh()
        model.setStart(now, now: now, calendar: calendar)
        model.setEnd(model.startDate.addingTimeInterval(3 * 86_400 + 4 * 3600 + 5 * 60),
                     calendar: calendar)
        XCTAssertEqual(model.durationDays, 3)
        XCTAssertEqual(model.durationHours, 4)
        XCTAssertEqual(model.durationMinutes, 5)
    }

    func testDurationSetterRoundsToTheNearestMinute() {
        // Upstream adds 30 s before splitting, so 1 m 45 s becomes 2 m.
        var model = fresh()
        model.setDuration(105)
        XCTAssertEqual(model.durationMinutes, 2)
        model.setDuration(89)
        XCTAssertEqual(model.durationMinutes, 1)
    }

    func testDelayDaysMovesTheStartDateKeepingTheTime() {
        var model = fresh()
        model.finishInitialisation(now: now, calendar: calendar)
        let timeOfDay = model.startDate.timeIntervalSince(calendar.startOfDay(for: model.startDate))
        model.setDuration(days: 1, hours: 0, minutes: 0)
        model.setDelayDays(5, now: now, calendar: calendar)

        XCTAssertEqual(model.delayDays, 5)
        let expectedDay = calendar.date(byAdding: .day, value: 5, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(calendar.startOfDay(for: model.startDate), expectedDay)
        XCTAssertEqual(model.startDate.timeIntervalSince(calendar.startOfDay(for: model.startDate)),
                       timeOfDay, accuracy: 0.001)
        XCTAssertEqual(model.endDate, model.startDate.addingTimeInterval(86_400))
    }

    func testDelayDaysClampToTheDesignerRange() {
        var model = fresh()
        model.setDelayDays(-4, now: now, calendar: calendar)
        XCTAssertEqual(model.delayDays, 0)
        model.setDelayDays(5000, now: now, calendar: calendar)
        XCTAssertEqual(model.delayDays, 1000)
    }

    func testSettingTheStartDateRecomputesTheDelay() {
        var model = fresh()
        model.setStart(now.addingTimeInterval(3 * 86_400), now: now, calendar: calendar)
        XCTAssertEqual(model.delayDays, 3)
    }

    func testStartDatePickerDropsSeconds() {
        var model = fresh()
        model.setStart(now, now: now, calendar: calendar)
        let seconds = calendar.component(.second, from: model.startDate)
        XCTAssertEqual(seconds, 0)
    }
}
