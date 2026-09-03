import Foundation
import OmApi
import OmGuiCore
import XCTest

/// Vectors for `DateRangeForm.updateWarningMessages` and the sampling defaults.
final class RecordingSettingsTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 ~ (fixed)

    private func settings(_ devices: [RecordingDeviceInfo] = [.ax3()]) -> RecordingSettings {
        var model = RecordingSettings(devices: devices, now: noon)
        model.finishInitialisation(now: noon)
        return model
    }

    // MARK: - Defaults

    func testDefaultsAre100HzAnd8g() {
        let model = settings()
        XCTAssertEqual(model.frequencyIndex, 5)
        XCTAssertEqual(model.rangeIndex, 2)
        XCTAssertEqual(model.sampleRate, .hz100)
        XCTAssertEqual(model.accelRange, .g8)
        XCTAssertEqual(model.samplingFrequency, 100)
        XCTAssertTrue(model.immediately)
        XCTAssertEqual(model.gyroIndex, 0)
    }

    func testDefaultsButtonResetsRateAndRange() {
        var model = settings()
        model.frequencyIndex = 0
        model.rangeIndex = 3
        model.applyDefaults()
        XCTAssertEqual(model.frequencyIndex, 5)
        XCTAssertEqual(model.rangeIndex, 2)
    }

    func testFrequencyListMatchesOmgui() {
        XCTAssertEqual(RecordingSettings.frequencyLabels,
                       ["3200", "1600", "800", "400", "200", "100", "50", "25", "12.5", "6.25"])
        XCTAssertEqual(RecordingSettings.rangeLabels, ["2", "4", "8", "16"])
        XCTAssertEqual(RecordingSettings.gyroLabels, ["(disabled)", "2000", "1000", "500", "250", "125"])
        // The API value is the integer truncation, which is what OmSetAccelConfig matches on.
        XCTAssertEqual(RecordingSettings.frequencies.map(\.apiValue),
                       [3200, 1600, 800, 400, 200, 100, 50, 25, 12, 6])
    }

    // MARK: - labelRateRangeSetting

    func testStandardRateAndRangeHasNoLabel() {
        let validation = settings().validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "")
        XCTAssertFalse(validation.invalid)
    }

    func testNonStandardRangeIsLabelledNonStandard() {
        var model = settings()
        model.rangeIndex = 3               // 16 g at 100 Hz
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "non-standard")
        XCTAssertFalse(validation.invalid)
    }

    func testHighFrequencyIsNotGuaranteed() {
        var model = settings()
        model.frequencyIndex = 0           // 3200 Hz
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not guaranteed")
        XCTAssertTrue(validation.flags.contains(7))
        XCTAssertFalse(validation.invalid)
    }

    func testLowFrequencyPackedIsUnsupported() {
        var model = settings()
        model.frequencyIndex = 9           // 6.25 Hz, truncates to 6
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not supported by firmware in packed mode")
        XCTAssertTrue(validation.invalid)
        XCTAssertFalse(validation.okEnabled)
    }

    func testLowFrequencyUnpackedIsOnlyNotGuaranteed() {
        var model = settings()
        model.frequencyIndex = 9
        model.unpacked = true
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not guaranteed")
        XCTAssertFalse(validation.invalid)
    }

    func testAx6Firmware53RejectsEightHundredHz() {
        var model = settings([.ax6(firmware: 53)])
        model.frequencyIndex = 2           // 800 Hz
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not supported by firmware")
        XCTAssertTrue(validation.invalid)
    }

    func testAx6NewerFirmwareAllowsEightHundredHz() {
        var model = settings([.ax6(firmware: 54)])
        model.frequencyIndex = 2
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not guaranteed")
        XCTAssertFalse(validation.invalid)
    }

    func testAx6RejectsAnythingAboveSixteenHundredHz() {
        var model = settings([.ax6(firmware: 60)])
        model.frequencyIndex = 0           // 3200 Hz
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not supported by device")
        XCTAssertTrue(validation.invalid)
    }

    func testGyroBelowTwentyFiveHzIsUnsupported() {
        var model = settings([.ax6(firmware: 60)])
        model.gyroIndex = 1                // 2000 dps
        model.frequencyIndex = 8           // 12.5 Hz
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.rateRangeText, "not supported with gyro")
        XCTAssertTrue(validation.invalid)
    }

    func testGyroDeviceWithGyroDisabledWarns() {
        let model = settings([.ax6()])
        let validation = model.validate(now: noon)
        XCTAssertTrue(validation.flags.contains(10))
        XCTAssertFalse(validation.invalid)
    }

    func testAx6IsAlwaysUnpackedAndNeverLowPower() {
        let model = settings([.ax6()])
        XCTAssertTrue(model.hasSyncGyro)
        XCTAssertFalse(model.lowPower)
        XCTAssertFalse(model.unpacked)
    }

    func testMixedSelectionIsNotTreatedAsGyroCapable() {
        let model = settings([.ax6(), .ax3()])
        XCTAssertFalse(model.hasSyncGyro)
    }

    // MARK: - Device warnings

    func testBatteryBelowNinetyWarns() {
        let model = settings([.ax3(battery: 89)])
        XCTAssertTrue(model.validate(now: noon).flags.contains(0))
        XCTAssertFalse(settings([.ax3(battery: 90)]).validate(now: noon).flags.contains(0))
    }

    func testDeviceWithDataWarns() {
        XCTAssertTrue(settings([.ax3(hasData: true)]).validate(now: noon).flags.contains(1))
        XCTAssertFalse(settings([.ax3(hasData: false)]).validate(now: noon).flags.contains(1))
    }

    func testDurationBeyondCapacityWarns() {
        var model = settings()
        model.immediately = false
        model.setStart(noon, now: noon)
        model.setDuration(days: 60, hours: 0, minutes: 0)
        XCTAssertTrue(model.validate(now: noon).flags.contains(2))
    }

    func testDurationBeyondBatteryLifeWarns() {
        // 100% battery at 100 Hz gives (100-10)/0.15 = 600 h.
        var model = settings()
        model.immediately = false
        model.setStart(noon, now: noon)
        model.setDuration(days: 26, hours: 0, minutes: 0)  // 624 h
        XCTAssertTrue(model.validate(now: noon).flags.contains(3))

        var shorter = settings()
        shorter.immediately = false
        shorter.setStart(noon, now: noon)
        shorter.setDuration(days: 24, hours: 0, minutes: 0)  // 576 h
        XCTAssertFalse(shorter.validate(now: noon).flags.contains(3))
    }

    func testBatteryLifeEstimateMatchesUpstreamFormula() {
        XCTAssertEqual(RecordingSettings.estimateBatteryLife(percent: 100, rate: 100),
                       90.0 / 0.15 * 3600, accuracy: 0.001)
        XCTAssertEqual(RecordingSettings.estimateBatteryLife(percent: 100, rate: 400),
                       90.0 / (0.15 * 4) * 3600, accuracy: 0.001)
        XCTAssertEqual(RecordingSettings.estimateBatteryLife(percent: 5, rate: 100), 0)
    }

    func testCapacityEstimateMatchesUpstreamFormula() {
        let bytes: Int64 = OmDevice.standardCapacityAX3
        let clusters = bytes / 32768
        let packed = Double((clusters * 64 - 2) * 120) / (1.0598 * 100)
        XCTAssertEqual(RecordingSettings.estimateCapacity(bytesFree: bytes, rate: 100,
                                                          unpacked: false, axes: 3),
                       packed, accuracy: 0.001)
        // Unpacked accelerometer-only is 80 samples per sector, gyro is 40.
        let unpacked = Double((clusters * 64 - 2) * 80) / (1.0598 * 100)
        XCTAssertEqual(RecordingSettings.estimateCapacity(bytesFree: bytes, rate: 100,
                                                          unpacked: true, axes: 3),
                       unpacked, accuracy: 0.001)
        let gyro = Double((clusters * 64 - 2) * 40) / (1.0598 * 100)
        XCTAssertEqual(RecordingSettings.estimateCapacity(bytesFree: bytes, rate: 100,
                                                          unpacked: true, axes: 6),
                       gyro, accuracy: 0.001)
        XCTAssertEqual(RecordingSettings.estimateCapacity(bytesFree: 0, rate: 100,
                                                          unpacked: false, axes: 3), 0)
    }

    // MARK: - Interval warnings

    func testEndInThePastIsInvalid() {
        var model = settings()
        model.immediately = false
        model.setStart(noon.addingTimeInterval(-4 * 86_400), now: noon)
        model.setDuration(days: 1, hours: 0, minutes: 0)
        let validation = model.validate(now: noon)
        XCTAssertTrue(validation.flags.contains(5))
        XCTAssertTrue(validation.invalid)
        XCTAssertFalse(validation.okEnabled)
    }

    func testStartAfterEndIsInvalid() {
        var model = settings()
        model.immediately = false
        model.setStart(noon.addingTimeInterval(86_400), now: noon)
        model.setDuration(days: 0, hours: 0, minutes: 0)
        let validation = model.validate(now: noon)
        XCTAssertTrue(validation.flags.contains(8))
        XCTAssertTrue(validation.invalid)
    }

    func testStartMoreThanFourteenDaysAheadWarns() {
        var model = settings()
        model.immediately = false
        model.setStart(noon.addingTimeInterval(15 * 86_400), now: noon)
        model.setDuration(days: 1, hours: 0, minutes: 0)
        let validation = model.validate(now: noon)
        XCTAssertTrue(validation.flags.contains(4))
        XCTAssertFalse(validation.invalid)
    }

    func testStartMoreThanADayInThePastWarns() {
        var model = settings()
        model.immediately = false
        model.setStart(noon.addingTimeInterval(-2 * 86_400), now: noon)
        model.setDuration(days: 10, hours: 0, minutes: 0)
        XCTAssertTrue(model.validate(now: noon).flags.contains(6))
    }

    func testIntervalWarningsAreSuppressedForImmediateRecording() {
        var model = settings()
        model.immediately = true
        model.setStart(noon.addingTimeInterval(-4 * 86_400), now: noon)
        model.setDuration(days: 1, hours: 0, minutes: 0)
        let validation = model.validate(now: noon)
        XCTAssertFalse(validation.flags.contains(5))
        XCTAssertFalse(validation.flags.contains(8))
        XCTAssertFalse(validation.invalid)
    }

    func testLowPowerWarns() {
        var model = settings()
        model.lowPower = true
        XCTAssertTrue(model.validate(now: noon).flags.contains(9))
    }

    // MARK: - The warning box text

    func testWarningTextIsHiddenWhenClean() {
        XCTAssertNil(settings().validate(now: noon).warningText)
    }

    func testWarningTextFormat() {
        var model = settings([.ax3(battery: 50, hasData: true)])
        model.lowPower = true
        let text = try! XCTUnwrap(model.validate(now: noon).warningText)
        XCTAssertTrue(text.hasPrefix("WARNINGS\n"))
        XCTAssertTrue(text.contains("\u{2022} Selected device(s) not fully charged"))
        XCTAssertTrue(text.contains("\u{2022} Selected device(s) not fully cleared"))
        XCTAssertTrue(text.contains("\u{2022} Low power accelerometer produces noisier data"))
    }

    func testInvalidConfigurationIsListedFirst() {
        var model = settings()
        model.immediately = false
        model.setStart(noon.addingTimeInterval(86_400), now: noon)
        model.setDuration(days: 0, hours: 0, minutes: 0)
        let text = try! XCTUnwrap(model.validate(now: noon).warningText)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "WARNINGS")
        XCTAssertEqual(lines.dropFirst().first, "\u{2022} Invalid configuration")
    }

    // MARK: - Encoding

    func testAccelConfigCarriesGyroOnlyForGyroDevices() {
        var ax6 = settings([.ax6()])
        ax6.gyroIndex = 2                 // 1000 dps
        XCTAssertEqual(ax6.accelConfig.gyro, .dps1000)
        XCTAssertEqual(ax6.accelConfig.apiRange, Int32(8 | (1000 << 16)))

        var ax3 = settings([.ax3()])
        ax3.gyroIndex = 2
        XCTAssertNil(ax3.accelConfig.gyro)
        XCTAssertEqual(ax3.accelConfig.apiRange, 8)
    }

    func testLowPowerNegatesTheRate() {
        var model = settings()
        model.lowPower = true
        XCTAssertEqual(model.accelConfig.apiRate, -100)
    }

    func testMetadataUsesOmguiKeyOrder() {
        var model = settings()
        model.metadata.studyCentre = "SITE1"
        model.metadata.studyCode = "STUDY"
        model.metadata.subjectSite = "left wrist"
        model.metadata.subjectCode = "P001"
        XCTAssertEqual(model.encodedMetadata, "_c=SITE1&_s=STUDY&_p=left+wrist&_sc=P001")
    }
}
