import XCTest
@testable import OmGuiCore

/// `MainForm.Designer.cs`'s split containers, as arithmetic.
final class SplitGeometryTests: XCTestCase {

    /// `splitContainerLog.SplitterDistance = 562` in a pane that is only ~537 tall: WinForms clamps
    /// to `Panel2MinSize`, which is what keeps the log visible rather than opening it at 0 px.
    func testDistanceIsClampedToBothMinimums() {
        let geometry = SplitGeometry(fixed: .panel2, minimum1: 160, minimum2: 120)
        XCTAssertEqual(geometry.clamp(562, available: 537), 417)
        XCTAssertEqual(geometry.clamp(10, available: 537), 160)
        XCTAssertEqual(geometry.clamp(218, available: 537), 218)
    }

    /// `splitContainerPreview` — FixedPanel.Panel1: the device pane keeps its 218 when the log opens.
    func testFixedPanel1KeepsItsSize() {
        var geometry = SplitGeometry(fixed: .panel1, minimum1: 60, minimum2: 120)
        geometry.record(panel1: 218, available: 537)
        let sizes = geometry.layout(available: 416)
        XCTAssertEqual(sizes?.panel1, 218)
        XCTAssertEqual(sizes?.panel2, 198)
    }

    /// `splitContainer1` — FixedPanel.Panel2: the files pane keeps its size and the preview absorbs
    /// the change, down to its minimum.
    func testFixedPanel2KeepsItsSizeAndPanel1AbsorbsDownToItsMinimum() {
        var geometry = SplitGeometry(fixed: .panel2, minimum1: 40, minimum2: 120)
        geometry.record(panel1: 89, available: 318)
        XCTAssertEqual(geometry.layout(available: 418)?.panel1, 189)   // grew by 100
        let squeezed = geometry.layout(available: 197)
        XCTAssertEqual(squeezed?.panel1, 40)                           // clamped at Panel1MinSize
        XCTAssertEqual(squeezed?.panel2, 157)
    }

    /// `splitContainerDevices` — FixedPanel.None: both panes keep their share.
    func testFixedPanelNoneIsProportional() {
        var geometry = SplitGeometry(fixed: .none, minimum1: 200, minimum2: 100)
        geometry.record(panel1: 747, available: 1055)
        let sizes = geometry.layout(available: 2110)
        XCTAssertEqual(sizes!.panel1, 1494, accuracy: 1)
        XCTAssertEqual(sizes!.panel1 + sizes!.panel2, 2110, accuracy: 0.001)
    }

    /// SwiftUI lays a hosting view out at a degenerate size before it settles; recording there would
    /// store `panel2 = 0` and hand panel 1 the whole container from then on.
    func testADegenerateContainerIsNotRecorded() {
        var geometry = SplitGeometry(fixed: .panel2, minimum1: 40, minimum2: 120)
        geometry.record(panel1: 40, available: 0)
        XCTAssertFalse(geometry.isRecorded)
        XCTAssertNil(geometry.layout(available: 318))

        geometry.record(panel1: 89, available: 318)
        XCTAssertTrue(geometry.isRecorded)
        XCTAssertEqual(geometry.layout(available: 318)?.panel1, 89)
    }

    /// The panes always fill the container exactly, whatever the rule.
    func testPanesAlwaysFillTheContainer() {
        for fixed in [SplitGeometry.FixedPanel.none, .panel1, .panel2] {
            var geometry = SplitGeometry(fixed: fixed, minimum1: 60, minimum2: 120)
            geometry.record(panel1: 218, available: 537)
            for available in stride(from: 200.0, through: 1200.0, by: 37.0) {
                let sizes = geometry.layout(available: available)!
                XCTAssertEqual(sizes.panel1 + sizes.panel2, available, accuracy: 0.001,
                               "\(fixed) at \(available)")
                XCTAssertGreaterThanOrEqual(sizes.panel1, 60, "\(fixed) at \(available)")
            }
        }
    }

    /// The divider is subtracted before the panes are sized.
    func testAvailableExcludesTheDivider() {
        XCTAssertEqual(SplitGeometry.available(extent: 538, divider: 1), 537)
        XCTAssertEqual(SplitGeometry.available(extent: 0, divider: 1), 0)
    }
}
