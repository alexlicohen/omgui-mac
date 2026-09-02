import AppKit
import OmGuiCore
import SwiftUI

/// A WinForms `SplitContainer`, as an `NSSplitView`.
///
/// SwiftUI's `HSplitView`/`VSplitView` distribute space by *ideal* size and offer no way to open a
/// pane at an exact point, so `MainForm`'s designer distances (218 / 747 / 89 / 738 / 562) cannot be
/// reproduced with them — the panes end up sharing the container evenly. This is the AppKit
/// equivalent: the divider opens at `distance` points, `fixedPanel` decides which side keeps its
/// size when the window resizes (WinForms `FixedPanel`), and either panel can be collapsed
/// (`Panel1Collapsed` / `Panel2Collapsed`) for the View menu toggles.
struct SplitPaneView<Panel1: View, Panel2: View>: NSViewRepresentable {

    /// WinForms `Orientation`: `.horizontal` stacks the panes, `.vertical` puts them side by side.
    enum Orientation {
        case horizontal
        case vertical

        /// `NSSplitView.isVertical` — true when the *divider* is vertical.
        var isVerticalDivider: Bool { self == .vertical }
    }

    /// WinForms `FixedPanel`.
    enum FixedPanel {
        case none, panel1, panel2
    }

    let orientation: Orientation
    /// `SplitterDistance` — the size of panel 1 along the split axis, in points.
    let distance: CGFloat
    var fixedPanel: FixedPanel = .none
    var panel1Minimum: CGFloat = 40
    var panel2Minimum: CGFloat = 40
    var panel1Collapsed = false
    var panel2Collapsed = false
    let panel1: Panel1
    let panel2: Panel2

    init(_ orientation: Orientation,
         distance: CGFloat,
         fixedPanel: FixedPanel = .none,
         panel1Minimum: CGFloat = 40,
         panel2Minimum: CGFloat = 40,
         panel1Collapsed: Bool = false,
         panel2Collapsed: Bool = false,
         @ViewBuilder panel1: () -> Panel1,
         @ViewBuilder panel2: () -> Panel2) {
        self.orientation = orientation
        self.distance = distance
        self.fixedPanel = fixedPanel
        self.panel1Minimum = panel1Minimum
        self.panel2Minimum = panel2Minimum
        self.panel1Collapsed = panel1Collapsed
        self.panel2Collapsed = panel2Collapsed
        self.panel1 = panel1()
        self.panel2 = panel2()
    }

    @MainActor
    final class Coordinator: NSObject {
        var host1: NSHostingView<Panel1>?
        var host2: NSHostingView<Panel2>?
        var lastCollapsed: (Bool, Bool) = (false, false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DesignerSplitView {
        let splitView = DesignerSplitView()
        splitView.isVertical = orientation.isVerticalDivider
        splitView.dividerStyle = .thin

        let host1 = NSHostingView(rootView: panel1)
        let host2 = NSHostingView(rootView: panel2)
        host1.sizingOptions = []
        host2.sizingOptions = []
        context.coordinator.host1 = host1
        context.coordinator.host2 = host2

        // Plain `addSubview`, not `addArrangedSubview`: the arranged-subview API makes NSSplitView
        // lay out through Auto Layout and holding priorities, where `resizeSubviews(withOldSize:)`
        // is never called and `FixedPanel` cannot be reproduced.
        splitView.addSubview(SplitPaneView.wrap(host1))
        splitView.addSubview(SplitPaneView.wrap(host2))

        apply(fixedPanel: fixedPanel, to: splitView)
        splitView.minimums = (panel1Minimum, panel2Minimum)
        splitView.subviews[0].isHidden = panel1Collapsed
        splitView.subviews[1].isHidden = panel2Collapsed
        splitView.pendingDistance = distance
        splitView.designerDistance = distance
        context.coordinator.lastCollapsed = (panel1Collapsed, panel2Collapsed)
        return splitView
    }

    func updateNSView(_ splitView: DesignerSplitView, context: Context) {
        context.coordinator.host1?.rootView = panel1
        context.coordinator.host2?.rootView = panel2
        apply(fixedPanel: fixedPanel, to: splitView)
        splitView.minimums = (panel1Minimum, panel2Minimum)

        let collapsed = (panel1Collapsed, panel2Collapsed)
        guard collapsed != context.coordinator.lastCollapsed else { return }
        context.coordinator.lastCollapsed = collapsed
        splitView.subviews[0].isHidden = panel1Collapsed
        splitView.subviews[1].isHidden = panel2Collapsed
        // Re-opening a pane re-applies the designer distance, as WinForms does — the stored
        // `SplitterDistance` survives a collapse.
        splitView.pendingDistance = distance
        splitView.resetPlacement()
        splitView.needsLayout = true
    }

    private func apply(fixedPanel: FixedPanel, to splitView: DesignerSplitView) {
        switch fixedPanel {
        case .none: splitView.fixed = .none
        case .panel1: splitView.fixed = .panel1
        case .panel2: splitView.fixed = .panel2
        }
    }

    /// `NSSplitView` lays its arranged subviews out by frame; an `NSHostingView` wants Auto Layout.
    /// Keeping each hosting view inside a plain autoresizing container keeps the two apart.
    private static func wrap(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

/// `Panel1MinSize` / `Panel2MinSize` while the user drags the divider.
@MainActor
final class DragLimits: NSObject, NSSplitViewDelegate {
    weak var owner: DesignerSplitView?

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, owner?.minimums.0 ?? proposedMinimumPosition)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let owner else { return proposedMaximumPosition }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, max(owner.minimums.0, extent - owner.minimums.1))
    }
}

/// An `NSSplitView` that opens its divider at an exact `SplitterDistance` the first time it has a
/// size to place it in (and again whenever a collapsed pane is re-opened).
final class DesignerSplitView: NSSplitView {

    typealias Fixed = SplitGeometry.FixedPanel

    var fixed: Fixed {
        get { geometry.fixed }
        set { geometry.fixed = newValue }
    }
    var pendingDistance: CGFloat?
    /// `Panel1MinSize` / `Panel2MinSize`: WinForms clamps `SplitterDistance` to them, which is what
    /// keeps the log pane visible even though its designer distance (562) is taller than the space
    /// the pane actually has.
    var minimums: (CGFloat, CGFloat) {
        get { (geometry.minimum1, geometry.minimum2) }
        set { geometry.minimum1 = newValue.0; geometry.minimum2 = newValue.1 }
    }
    /// The designer `SplitterDistance`, re-applied when a collapsed pane re-opens.
    var designerDistance: CGFloat = 0

    private var geometry = SplitGeometry()
    private var lastAppliedExtent: CGFloat = -1
    /// The geometry this view last placed itself. `splitViewDidResizeSubviews` arrives after our
    /// own placements too, so "did the user drag it?" is answered by comparing against this rather
    /// than by a flag we would have already cleared.
    private var lastPlaced: (panel1: CGFloat, extent: CGFloat) = (-1, -1)
    private let limits = DragLimits()

    override init(frame: NSRect) {
        super.init(frame: frame)
        limits.owner = self
        delegate = limits
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard !userDragging else { return }
        let extent = isVertical ? bounds.width : bounds.height
        guard extent > 1, subviews.allSatisfy({ !$0.isHidden }) else {
            pendingDistance = nil
            return
        }

        if let distance = pendingDistance {
            // SwiftUI lays a hosting view out several times before it settles, and the first pass
            // can be far smaller than the final size. Keep re-applying until the extent repeats.
            if extent == lastAppliedExtent { pendingDistance = nil } else { lastAppliedExtent = extent }
            record(panel1: clampPanel1(distance, extent: extent), extent: extent)
        }
        // NSSplitView re-distributes the panes proportionally through a path that is not
        // `resizeSubviews(withOldSize:)` or `adjustSubviews`, so the FixedPanel geometry has to be
        // re-asserted here, after everything else has had its say.
        layoutPanels(fallback: {})
    }

    /// Re-arm the placement so a re-opened pane gets the designer distance again.
    func resetPlacement() {
        lastAppliedExtent = -1
        geometry = SplitGeometry(fixed: geometry.fixed,
                                 minimum1: geometry.minimum1,
                                 minimum2: geometry.minimum2)
    }

    private var userDragging = false

    /// Dragging the divider is what sets a new `SplitterDistance`; `super.mouseDown` runs the whole
    /// tracking loop, so the new geometry is readable as soon as it returns.
    override func mouseDown(with event: NSEvent) {
        userDragging = true
        super.mouseDown(with: event)
        userDragging = false
        let extent = isVertical ? bounds.width : bounds.height
        guard extent > 1, subviews.allSatisfy({ !$0.isHidden }), let first = subviews.first else { return }
        pendingDistance = nil
        record(panel1: isVertical ? first.frame.width : first.frame.height, extent: extent)
    }

    private func record(panel1: CGFloat, extent: CGFloat) {
        geometry.record(panel1: panel1, available: available(extent))
        lastPlaced = (panel1, extent)
    }

    private func available(_ extent: CGFloat) -> CGFloat {
        SplitGeometry.available(extent: extent, divider: dividerThickness)
    }

    private func clampPanel1(_ value: CGFloat, extent: CGFloat) -> CGFloat {
        geometry.clamp(value, available: available(extent))
    }

    /// WinForms resizes a `SplitContainer`'s panels itself: `FixedPanel` says which one keeps its
    /// size, and both are clamped to their minimums. `NSSplitView`'s holding priorities give the
    /// first half of that but ignore the minimums, which collapses the losing pane to nothing.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutPanels(fallback: { super.resizeSubviews(withOldSize: oldSize) })
    }

    /// `adjustSubviews` is NSSplitView's proportional distributor, and it runs *after*
    /// `resizeSubviews(withOldSize:)` — overriding only the latter left the proportional result in
    /// place, which is why FixedPanel appeared to do nothing.
    override func adjustSubviews() {
        layoutPanels(fallback: { super.adjustSubviews() })
    }

    private func layoutPanels(fallback: () -> Void) {
        let visible = subviews.filter { !$0.isHidden }
        guard visible.count == 2 else {
            for view in visible { view.frame = bounds }
            return
        }
        let extent = isVertical ? bounds.width : bounds.height
        guard extent > 1, let sizes = geometry.layout(available: available(extent)) else {
            fallback()
            return
        }
        let panel1 = sizes.panel1
        let panel2 = sizes.panel2
        lastPlaced = (panel1, extent)

        if isVertical {
            visible[0].frame = NSRect(x: 0, y: 0, width: panel1, height: bounds.height)
            visible[1].frame = NSRect(x: panel1 + dividerThickness, y: 0,
                                      width: panel2, height: bounds.height)
        } else if isFlipped {
            // A horizontal NSSplitView is flipped: y = 0 is the top, where panel 1 belongs.
            visible[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: panel1)
            visible[1].frame = NSRect(x: 0, y: panel1 + dividerThickness,
                                      width: bounds.width, height: panel2)
        } else {
            visible[0].frame = NSRect(x: 0, y: bounds.height - panel1, width: bounds.width, height: panel1)
            visible[1].frame = NSRect(x: 0, y: 0, width: bounds.width, height: panel2)
        }
    }
}
