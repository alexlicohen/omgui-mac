import Foundation

/// The arithmetic behind a WinForms `SplitContainer`: a remembered `SplitterDistance`, the
/// `Panel1MinSize`/`Panel2MinSize` clamp, and the `FixedPanel` rule that says which panel keeps its
/// size when the container is resized.
///
/// Kept out of the view so it can be asserted without a window; `DesignerSplitView` is a thin shell
/// over it.
public struct SplitGeometry: Equatable, Sendable {

    public enum FixedPanel: String, Sendable {
        case none, panel1, panel2
    }

    public var fixed: FixedPanel
    /// `Panel1MinSize`.
    public var minimum1: Double
    /// `Panel2MinSize`.
    public var minimum2: Double

    /// The remembered geometry. WinForms keeps `SplitterDistance` as a property and recomputes the
    /// panels from it; deriving instead from whatever the frames currently are lets one transient
    /// layout pass at a tiny size stick forever.
    public private(set) var panel1: Double = 0
    public private(set) var panel2: Double = 0
    public private(set) var ratio: Double = 0
    public private(set) var isRecorded = false

    public init(fixed: FixedPanel = .none, minimum1: Double = 40, minimum2: Double = 40) {
        self.fixed = fixed
        self.minimum1 = minimum1
        self.minimum2 = minimum2
    }

    /// The space the two panels share (the container less the divider).
    public static func available(extent: Double, divider: Double) -> Double {
        max(0, extent - divider)
    }

    /// `SplitterDistance`, clamped to both panel minimums — this is what keeps the log pane visible
    /// even though its designer distance (562) is larger than the space the pane ever gets.
    public func clamp(_ value: Double, available: Double) -> Double {
        let upperBound = max(minimum1, available - minimum2)
        return max(minimum1, min(value, upperBound))
    }

    /// Remember a distance. A degenerate container is ignored: recording `panel2 = 0` there would
    /// make `FixedPanel.panel2` hand panel 1 the whole container from then on.
    public mutating func record(panel1 value: Double, available: Double) {
        guard available >= minimum1 + minimum2 else { return }
        panel1 = value
        panel2 = max(0, available - value)
        ratio = value / max(1, available)
        isRecorded = true
    }

    /// The panel sizes for a container of this size. `nil` before anything has been recorded.
    public func layout(available: Double) -> (panel1: Double, panel2: Double)? {
        guard isRecorded else { return nil }
        let wanted: Double
        switch fixed {
        case .panel1: wanted = panel1                  // panel 2 absorbs the change
        case .panel2: wanted = available - panel2      // panel 1 absorbs the change
        case .none: wanted = available * ratio         // proportional, as FixedPanel.None
        }
        let first = clamp(wanted, available: available)
        return (first, max(0, available - first))
    }
}
