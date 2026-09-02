import Foundation

/// The visible time window and its mapping to pixels.
///
/// `DataViewer.cs` works in *block index* space (`BlockAtPoint`, `PointForBlock`, `firstBlock`,
/// `numBlocks`). This port works in wall-clock seconds instead, because the phase-2 preview
/// signature already hands the selection out as a `ClosedRange<Date>` and because a time axis
/// shows a recording's gaps at their true width — in block space a stopped device is invisible.
/// Every operation below is otherwise the arithmetic `DataViewer.cs` performs, including the
/// clipping order `StartAnimation` applies after each zoom.
public struct DataTimeAxis: Equatable, Sendable {

    /// The whole recording, in seconds since 1970 on the device's clock.
    public var bounds: ClosedRange<Double>
    /// Start of the visible window.
    public var start: Double
    /// Width of the visible window, in seconds.
    public var span: Double
    /// Width of the plot, in pixels.
    public var width: Double

    /// `numBlocks < 1` in `StartAnimation` — a floor of one block; here, one second.
    public static let minimumSpan: Double = 1.0

    public init(bounds: ClosedRange<Double>, start: Double, span: Double, width: Double) {
        self.bounds = bounds
        self.start = start
        self.span = span
        self.width = width
    }

    /// The full extent of the recording.
    public init(bounds: ClosedRange<Double>, width: Double) {
        self.init(bounds: bounds,
                  start: bounds.lowerBound,
                  span: Swift.max(bounds.upperBound - bounds.lowerBound, DataTimeAxis.minimumSpan),
                  width: width)
    }

    public var end: Double { start + span }
    public var range: ClosedRange<Double> { start...(start + span) }
    /// Seconds one pixel covers.
    public var secondsPerPoint: Double { width > 0 ? span / width : span }
    public var isFullExtent: Bool {
        start <= bounds.lowerBound + 1e-6 && end >= bounds.upperBound - 1e-6
    }

    /// `BlockAtPoint`.
    public func time(atX x: Double) -> Double {
        guard width > 0 else { return start }
        return start + x * span / width
    }

    /// `PointForBlock`.
    public func x(forTime time: Double) -> Double {
        guard span > 0 else { return 0 }
        return width * (time - start) / span
    }

    /// `StartAnimation`'s clip: span to the recording, then the window inside it.
    public func clamped() -> DataTimeAxis {
        var axis = self
        let total = Swift.max(bounds.upperBound - bounds.lowerBound, DataTimeAxis.minimumSpan)
        if axis.span > total { axis.span = total }
        if axis.span < DataTimeAxis.minimumSpan { axis.span = DataTimeAxis.minimumSpan }
        if axis.start + axis.span > bounds.upperBound { axis.start = bounds.upperBound - axis.span }
        if axis.start < bounds.lowerBound { axis.start = bounds.lowerBound }
        return axis
    }

    /// `ZoomIn` — halve the window around `time`.
    public func zoomedIn(at time: Double) -> DataTimeAxis {
        var axis = self
        let newSpan = Swift.max(span / 2, DataTimeAxis.minimumSpan)
        axis.span = newSpan
        axis.start = time - newSpan / 2
        return axis.clamped()
    }

    /// `ZoomOut` — double the window around `time`.
    public func zoomedOut(at time: Double) -> DataTimeAxis {
        var axis = self
        let newSpan = span * 2
        axis.span = newSpan
        axis.start = time - newSpan / 2
        return axis.clamped()
    }

    /// `ZoomRange` — fit the window to a time range.
    public func zoomed(to range: ClosedRange<Double>) -> DataTimeAxis {
        var axis = self
        axis.start = range.lowerBound
        axis.span = Swift.max(range.upperBound - range.lowerBound, DataTimeAxis.minimumSpan)
        return axis.clamped()
    }

    /// Back to the whole recording.
    public func fullExtent() -> DataTimeAxis {
        DataTimeAxis(bounds: bounds, width: width).clamped()
    }

    /// Same window, new pixel width.
    public func resized(width: Double) -> DataTimeAxis {
        var axis = self
        axis.width = width
        return axis.clamped()
    }

    /// Same window over a recording that has grown (a device still writing to its data file).
    public func rebound(to bounds: ClosedRange<Double>, followingEnd: Bool) -> DataTimeAxis {
        var axis = self
        let wasFull = isFullExtent
        axis.bounds = bounds
        if wasFull || followingEnd {
            axis.span = Swift.max(bounds.upperBound - bounds.lowerBound, DataTimeAxis.minimumSpan)
            axis.start = bounds.lowerBound
        }
        return axis.clamped()
    }
}

/// A selected time slice — `beginBlock`/`endBlock` in `DataViewer.cs`, which feeds Export Raw CSV.
public struct DataViewerSelection: Equatable, Sendable {
    public var begin: Double
    public var end: Double

    public init(begin: Double, end: Double) {
        self.begin = begin
        self.end = end
    }

    /// `HasSelection`.
    public var isEmpty: Bool { begin == end }
    /// Ordered low…high, which is the invariant `graphPanel_MouseMove` maintains by swapping.
    public var range: ClosedRange<Double> { begin <= end ? begin...end : end...begin }
    public var dateRange: ClosedRange<Date> {
        Date(timeIntervalSince1970: range.lowerBound)...Date(timeIntervalSince1970: range.upperBound)
    }

    public mutating func clamp(to bounds: ClosedRange<Double>) {
        begin = Swift.min(Swift.max(begin, bounds.lowerBound), bounds.upperBound)
        end = Swift.min(Swift.max(end, bounds.lowerBound), bounds.upperBound)
    }
}

/// `DataViewer.SelectionType` — what a press at a given x would grab.
public enum DataViewerGrip: Equatable, Sendable {
    case none
    case move
    case begin
    case end
}

extension DataViewerSelection {

    /// `GetSelectionTypeAtPoint`: within 5 px of a marker grabs it (closest wins), inside the
    /// selection moves it, anything else is not a selection gesture.
    public func grip(atX x: Double, axis: DataTimeAxis, margin: Double = 5) -> DataViewerGrip {
        guard !isEmpty else { return .none }
        let beginX = axis.x(forTime: begin)
        let endX = axis.x(forTime: end)
        let isBegin = abs(x - beginX) <= margin
        let isEnd = abs(x - endX) <= margin
        if isBegin && isEnd {
            return abs(x - beginX) <= abs(x - endX) ? .begin : .end
        }
        if isBegin { return .begin }
        if isEnd { return .end }
        if (x >= beginX && x <= endX) || (x >= endX && x <= beginX) { return .move }
        return .none
    }

    /// Drags a grabbed marker, swapping the roles when the markers cross — exactly what
    /// `graphPanel_MouseMove` does, so a drag through the other end keeps tracking the pointer.
    public mutating func drag(_ grip: DataViewerGrip, to time: Double) -> DataViewerGrip {
        switch grip {
        case .begin:
            begin = time
            if begin > end {
                swap(&begin, &end)
                return .end
            }
        case .end:
            end = time
            if begin > end {
                swap(&begin, &end)
                return .begin
            }
        case .move:
            let span = end - begin
            begin = time
            end = begin + span
        case .none:
            break
        }
        return grip
    }
}
