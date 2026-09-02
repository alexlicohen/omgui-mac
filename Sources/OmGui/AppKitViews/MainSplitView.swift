import AppKit
import SwiftUI

/// `MainForm`'s four nested `SplitContainer`s, built as one AppKit hierarchy.
///
/// ```
/// splitContainerLog      (Horizontal, FixedPanel=Panel2, dist 562)
///   splitContainerPreview  (Horizontal, FixedPanel=Panel1, dist 218)
///     splitContainerDevices  (Vertical,   dist 747)      devicesListView | propertyGridDevice
///     splitContainer1        (Horizontal, FixedPanel=Panel2, dist 89)  dataViewer / files
///   textBoxLog
/// ```
///
/// The nesting is deliberately *not* done by putting a `SplitPaneView` inside another one's SwiftUI
/// pane: an `NSHostingView` between two `NSSplitView`s does not reliably pass a frame change down,
/// so opening the log left the inner splitters believing they were still full height. Building the
/// tree in AppKit and hosting SwiftUI only at the five leaves removes that negotiation entirely.
struct MainSplitView<Devices: View, DeviceProperties: View, Preview: View, Files: View, Log: View>: NSViewRepresentable {

    let showDeviceProperties: Bool
    let showPreview: Bool
    let showLog: Bool
    let devices: Devices
    let deviceProperties: DeviceProperties
    let preview: Preview
    let files: Files
    let log: Log

    init(showDeviceProperties: Bool,
         showPreview: Bool,
         showLog: Bool,
         @ViewBuilder devices: () -> Devices,
         @ViewBuilder deviceProperties: () -> DeviceProperties,
         @ViewBuilder preview: () -> Preview,
         @ViewBuilder files: () -> Files,
         @ViewBuilder log: () -> Log) {
        self.showDeviceProperties = showDeviceProperties
        self.showPreview = showPreview
        self.showLog = showLog
        self.devices = devices()
        self.deviceProperties = deviceProperties()
        self.preview = preview()
        self.files = files()
        self.log = log()
    }

    @MainActor
    final class Coordinator: NSObject {
        var devicesHost: NSHostingView<Devices>?
        var devicePropertiesHost: NSHostingView<DeviceProperties>?
        var previewHost: NSHostingView<Preview>?
        var filesHost: NSHostingView<Files>?
        var logHost: NSHostingView<Log>?

        var logSplit: DesignerSplitView?
        var previewSplit: DesignerSplitView?
        var devicesSplit: DesignerSplitView?
        var dataSplit: DesignerSplitView?

        var lastFlags: (Bool, Bool, Bool)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DesignerSplitView {
        let coordinator = context.coordinator

        let devicesHost = SplitHosting.make(devices)
        let devicePropertiesHost = SplitHosting.make(deviceProperties)
        let previewHost = SplitHosting.make(preview)
        let filesHost = SplitHosting.make(files)
        let logHost = SplitHosting.make(log)
        coordinator.devicesHost = devicesHost
        coordinator.devicePropertiesHost = devicePropertiesHost
        coordinator.previewHost = previewHost
        coordinator.filesHost = filesHost
        coordinator.logHost = logHost

        // splitContainerDevices — IsSplitterFixed, FixedPanel.None, dist 747.
        let devicesSplit = DesignerSplitView.make(vertical: true, fixed: .none,
                                                  minimums: (200, 100), distance: 747,
                                                  SplitHosting.wrap(devicesHost),
                                                  SplitHosting.wrap(devicePropertiesHost))
        // splitContainer1 — FixedPanel.Panel2, dist 89.
        let dataSplit = DesignerSplitView.make(vertical: false, fixed: .panel2,
                                               minimums: (40, 120), distance: 89,
                                               SplitHosting.wrap(previewHost),
                                               SplitHosting.wrap(filesHost))
        // splitContainerPreview — FixedPanel.Panel1, dist 218.
        let previewSplit = DesignerSplitView.make(vertical: false, fixed: .panel1,
                                                  minimums: (60, 120), distance: 218,
                                                  devicesSplit, dataSplit)
        // splitContainerLog — FixedPanel.Panel2, dist 562.
        let logSplit = DesignerSplitView.make(vertical: false, fixed: .panel2,
                                              minimums: (160, 120), distance: 562,
                                              previewSplit, SplitHosting.wrap(logHost))

        coordinator.devicesSplit = devicesSplit
        coordinator.dataSplit = dataSplit
        coordinator.previewSplit = previewSplit
        coordinator.logSplit = logSplit

        applyFlags(context: context, force: true)
        return logSplit
    }

    func updateNSView(_ view: DesignerSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.devicesHost?.rootView = devices
        coordinator.devicePropertiesHost?.rootView = deviceProperties
        coordinator.previewHost?.rootView = preview
        coordinator.filesHost?.rootView = files
        coordinator.logHost?.rootView = log
        applyFlags(context: context, force: false)
    }

    /// The View-menu toggles: `Panel1Collapsed` / `Panel2Collapsed` on the containers that hold the
    /// device property grid, the preview and the log.
    private func applyFlags(context: Context, force: Bool) {
        let coordinator = context.coordinator
        let flags = (showDeviceProperties, showPreview, showLog)
        guard force || coordinator.lastFlags == nil || coordinator.lastFlags! != flags else { return }
        coordinator.lastFlags = flags
        coordinator.devicesSplit?.setCollapsed(panel1: false, panel2: !showDeviceProperties)
        coordinator.dataSplit?.setCollapsed(panel1: !showPreview, panel2: false)
        coordinator.logSplit?.setCollapsed(panel1: false, panel2: !showLog)
    }
}

/// Hosting-view plumbing shared by the split containers.
enum SplitHosting {

    @MainActor
    static func make<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        return host
    }

    /// `NSSplitView` positions its panes by frame; an `NSHostingView` wants Auto Layout. Keeping
    /// each hosting view inside a plain autoresizing container keeps the two apart.
    @MainActor
    static func wrap(_ view: NSView) -> NSView {
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

extension DesignerSplitView {

    @MainActor
    static func make(vertical: Bool,
                     fixed: Fixed,
                     minimums: (CGFloat, CGFloat),
                     distance: CGFloat,
                     _ panel1: NSView,
                     _ panel2: NSView) -> DesignerSplitView {
        let split = DesignerSplitView()
        split.translatesAutoresizingMaskIntoConstraints = true
        split.autoresizingMask = [.width, .height]
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.fixed = fixed
        split.minimums = minimums
        split.addSubview(panel1)
        split.addSubview(panel2)
        split.pendingDistance = distance
        split.designerDistance = distance
        return split
    }

    /// `Panel1Collapsed` / `Panel2Collapsed`. Re-opening a pane restores the stored
    /// `SplitterDistance`, as WinForms does.
    @MainActor
    func setCollapsed(panel1: Bool, panel2: Bool) {
        guard subviews.count == 2 else { return }
        let changed = subviews[0].isHidden != panel1 || subviews[1].isHidden != panel2
        subviews[0].isHidden = panel1
        subviews[1].isHidden = panel2
        guard changed else { return }
        if !panel1 && !panel2 {
            resetPlacement()
            pendingDistance = designerDistance
        }
        needsLayout = true
    }
}
