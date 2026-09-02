import Foundation
import XCTest
@testable import OmGuiCore

/// Time↔pixel mapping and the zoom/selection arithmetic, against `DataViewer.cs`.
final class DataViewerAxisTests: XCTestCase {

    private let day: ClosedRange<Double> = 0...86_400
    private func axis(start: Double = 0, span: Double = 86_400, width: Double = 800) -> DataTimeAxis {
        DataTimeAxis(bounds: day, start: start, span: span, width: width)
    }

    func testTimeAndPointAreInverses() {
        let axis = self.axis(start: 3600, span: 7200, width: 640)
        XCTAssertEqual(axis.time(atX: 0), 3600)
        XCTAssertEqual(axis.time(atX: 640), 10_800)
        XCTAssertEqual(axis.time(atX: 320), 7200)
        XCTAssertEqual(axis.x(forTime: 3600), 0)
        XCTAssertEqual(axis.x(forTime: 10_800), 640)
        for x in stride(from: 0.0, through: 640.0, by: 37.0) {
            XCTAssertEqual(axis.x(forTime: axis.time(atX: x)), x, accuracy: 1e-9)
        }
        XCTAssertEqual(axis.secondsPerPoint, 7200 / 640)
    }

    func testAZeroWidthAxisDoesNotDivideByZero() {
        let axis = self.axis(width: 0)
        XCTAssertEqual(axis.time(atX: 100), axis.start)
        XCTAssertEqual(DataTimeAxis(bounds: day, start: 0, span: 0, width: 800).x(forTime: 50), 0)
    }

    // MARK: - Zoom

    func testZoomInHalvesTheWindowAroundThePoint() {
        // `ZoomIn`: newNum = num / 2; newFirst = a - newNum / 2.
        let zoomed = axis(start: 0, span: 40_000).zoomedIn(at: 30_000)
        XCTAssertEqual(zoomed.span, 20_000)
        XCTAssertEqual(zoomed.start, 20_000)
        XCTAssertEqual(zoomed.time(atX: zoomed.width / 2), 30_000, "the point stays under the cursor")
    }

    func testZoomOutDoublesAndClipsToTheRecording() {
        let zoomed = axis(start: 40_000, span: 20_000).zoomedOut(at: 50_000)
        XCTAssertEqual(zoomed.span, 40_000)
        XCTAssertEqual(zoomed.start, 30_000)

        // Past the ends, `StartAnimation` pulls the window back inside.
        let atStart = axis(start: 0, span: 20_000).zoomedOut(at: 1_000)
        XCTAssertEqual(atStart.start, 0)
        XCTAssertEqual(atStart.span, 40_000)

        var full = axis(start: 0, span: 60_000)
        for _ in 0..<4 { full = full.zoomedOut(at: 30_000) }
        XCTAssertEqual(full.span, 86_400, "never wider than the recording")
        XCTAssertEqual(full.start, 0)
        XCTAssertTrue(full.isFullExtent)
    }

    func testZoomInStopsAtTheMinimumSpan() {
        var axis = self.axis()
        for _ in 0..<40 { axis = axis.zoomedIn(at: 43_200) }
        XCTAssertEqual(axis.span, DataTimeAxis.minimumSpan)
        XCTAssertGreaterThanOrEqual(axis.start, 0)
        XCTAssertLessThanOrEqual(axis.end, 86_400)
    }

    func testZoomToRangeAndFullExtent() {
        let zoomed = axis().zoomed(to: 10_000...12_000)
        XCTAssertEqual(zoomed.start, 10_000)
        XCTAssertEqual(zoomed.span, 2_000)
        XCTAssertFalse(zoomed.isFullExtent)

        let reset = zoomed.fullExtent()
        XCTAssertEqual(reset.start, 0)
        XCTAssertEqual(reset.span, 86_400)
        XCTAssertTrue(reset.isFullExtent)
    }

    func testAGrowingRecordingKeepsAZoomedWindowButFollowsAFullOne() {
        let zoomed = axis(start: 10_000, span: 2_000)
        let grown = zoomed.rebound(to: 0...100_000, followingEnd: false)
        XCTAssertEqual(grown.start, 10_000, "a zoomed window stays put")
        XCTAssertEqual(grown.span, 2_000)

        let live = axis().rebound(to: 0...100_000, followingEnd: false)
        XCTAssertEqual(live.span, 100_000, "a full-extent window keeps showing everything")
    }

    // MARK: - Selection

    private func selection(_ begin: Double, _ end: Double) -> DataViewerSelection {
        DataViewerSelection(begin: begin, end: end)
    }

    func testGripFollowsGetSelectionTypeAtPoint() {
        let axis = self.axis(start: 0, span: 800, width: 800)   // one second per pixel
        let selection = self.selection(200, 400)

        XCTAssertEqual(selection.grip(atX: 200, axis: axis), .begin)
        XCTAssertEqual(selection.grip(atX: 204, axis: axis), .begin, "5 px of margin")
        XCTAssertEqual(selection.grip(atX: 396, axis: axis), .end)
        XCTAssertEqual(selection.grip(atX: 300, axis: axis), .move)
        XCTAssertEqual(selection.grip(atX: 100, axis: axis), .none)
        XCTAssertEqual(selection.grip(atX: 700, axis: axis), .none)

        // Closest marker wins when both are in range.
        let tight = self.selection(300, 304)
        XCTAssertEqual(tight.grip(atX: 301, axis: axis), .begin)
        XCTAssertEqual(tight.grip(atX: 303, axis: axis), .end)

        XCTAssertEqual(self.selection(100, 100).grip(atX: 100, axis: axis), .none, "no selection")
        XCTAssertTrue(self.selection(100, 100).isEmpty)
    }

    func testDraggingAMarkerThroughTheOtherSwapsTheRoles() {
        var selection = self.selection(200, 400)
        var grip = selection.drag(.end, to: 350)
        XCTAssertEqual(grip, .end)
        XCTAssertEqual(selection.range, 200...350)

        grip = selection.drag(grip, to: 100)
        XCTAssertEqual(grip, .begin, "dragged past the start, so it is now the start marker")
        XCTAssertEqual(selection.range, 100...200)

        grip = selection.drag(grip, to: 500)
        XCTAssertEqual(grip, .end)
        XCTAssertEqual(selection.range, 200...500)
    }

    func testMovingASelectionKeepsItsSpan() {
        var selection = self.selection(200, 400)
        _ = selection.drag(.move, to: 1_000)
        XCTAssertEqual(selection.begin, 1_000)
        XCTAssertEqual(selection.end, 1_200)
        XCTAssertEqual(selection.range.upperBound - selection.range.lowerBound, 200)

        selection.clamp(to: 0...1_100)
        XCTAssertEqual(selection.range, 1_000...1_100, "`graphPanel_MouseUp` clips to the recording")
    }

    func testSelectionConvertsToTheDateRangeTheBindingCarries() {
        let selection = self.selection(1_756_713_600, 1_756_717_200)
        XCTAssertEqual(selection.dateRange.lowerBound, Date(timeIntervalSince1970: 1_756_713_600))
        XCTAssertEqual(selection.dateRange.upperBound, Date(timeIntervalSince1970: 1_756_717_200))
        XCTAssertEqual(self.selection(500, 100).dateRange.lowerBound,
                       Date(timeIntervalSince1970: 100), "the range is always ordered")
    }
}
