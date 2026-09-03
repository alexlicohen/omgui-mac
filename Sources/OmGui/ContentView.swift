import AppKit
import OmApi
import OmGuiCore
import SwiftUI

/// The main window (`MainForm.Designer.cs`).
///
/// Split proportions, column widths and control order follow the designer file; every splitter is
/// a `SplitPaneView` (an `NSSplitView`), which is the only way to open a pane at the designer's
/// exact `SplitterDistance` and still let the user drag it.
struct ContentView: View {

    @EnvironmentObject var model: AppModel

    /// `splitContainerPreview.SplitterDistance`.
    static let devicesHeight: CGFloat = 218
    /// `splitContainer1.SplitterDistance`.
    static let previewHeight: CGFloat = 89
    /// `splitContainerDevices.SplitterDistance`.
    static let devicesTableWidth: CGFloat = 747
    /// `splitContainerFileProperties.SplitterDistance`.
    static let filesTableWidth: CGFloat = 738
    /// `splitContainerLog.SplitterDistance` — 562 of 590, so the log starts short.
    static let contentHeight: CGFloat = 562

    var body: some View {
        VStack(spacing: 0) {
            if model.showToolbar {
                DeviceToolbar()
                Divider()
            }
            // `splitContainerLog` / `splitContainerPreview` / `splitContainerDevices` /
            // `splitContainer1`, with the designer's 562 / 218 / 747 / 89 distances.
            MainSplitView(showDeviceProperties: model.showDeviceProperties,
                          showPreview: model.showPreview,
                          showLog: model.showLog) {
                GroupedTableView(columns: DeviceColumns.all,
                                 sections: deviceSections,
                                 selection: deviceSelectionBinding)
            } deviceProperties: {
                PropertyGridView(title: "Device", rows: model.devicePropertyRows)
            } preview: {
                previewPane.environmentObject(model)
            } files: {
                filesPane.environmentObject(model)
            } log: {
                LogPane().environmentObject(model)
            }
            if model.showStatusBar {
                Divider()
                StatusBar()
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .sheet(item: $model.recordingSheet) { context in
            RecordingSettingsView(context: context)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showOptions) {
            OptionsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showAbout) {
            AboutView()
        }
        .sheet(item: $model.progressSheet) { context in
            ProgressSheet(context: context).environmentObject(model)
        }
        .sheet(item: $model.exportSheet) { context in
            ExportSheet(context: context).environmentObject(model)
        }
        .sheet(item: $model.pluginsSheet) { context in
            PluginsSheet(context: context).environmentObject(model)
        }
        .sheet(item: $model.runPluginSheet) { context in
            RunPluginSheet(context: context).environmentObject(model)
        }
    }

    private var deviceSelectionBinding: Binding<Set<String>> {
        Binding(get: { Set(model.selectedDeviceIds.map(String.init)) },
                set: { ids in
                    model.selectedDeviceIds = Set(ids.compactMap { UInt32($0) })
                    model.selectionChanged()
                })
    }

    /// One section, headed "Default".
    ///
    /// `DeviceListView` registers the nine category groups but `MainForm` never puts an item in
    /// one (`MainForm.cs:367`/`:397`), so V1.0.0.45 shows every connected device under the
    /// `ListView`'s implicit default group — the "Default" header in the MOP's screenshot. See
    /// `DeviceGroup` and `refs/09-mop-alignment-notes.md`.
    private var deviceSections: [GridSection] {
        guard !model.rows.isEmpty else { return [] }
        return [GridSection(id: DeviceGroup.defaultIdentifier,
                            title: DeviceGroup.defaultTitle,
                            rows: model.rows.map { row in
                                GridRow(id: String(row.deviceId), cells: [
                                    GridCell(row.deviceText, iconIndex: row.ledIconIndex),
                                    GridCell(row.sessionText),
                                    GridCell(row.batteryText, color: row.batteryColor),
                                    GridCell(row.downloadText, color: row.downloadColor),
                                    GridCell(row.recordingText, color: row.recordingColor),
                                ])
                            })]
    }

    // MARK: - Preview

    private var previewPane: some View {
        HStack(spacing: 0) {
            DataViewerView(source: model.dataViewerSource,
                           channels: model.dataChannels,
                           mode: model.dataViewerMode,
                           selection: $model.dataSelection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            DataOptionsBox()
                .frame(width: 96)
        }
    }

    // MARK: - Files

    private var filesPane: some View {
        VStack(spacing: 0) {
            WorkspaceBar()
            Divider()
            FilesTabView()
        }
    }
}

/// `devicesListView`'s columns and widths.
enum DeviceColumns {
    static let all = [
        // `columnDevice.Width = 70` fits a 7-digit ID in Segoe UI 9 pt but not in the macOS system
        // font at 11 pt, where "6036222" plus the LED circle needs 72 pt. The MOP's device IDs are
        // seven digits, so the column is widened rather than allowed to truncate them
        // (`refs/09-mop-alignment-notes.md`); the other four widths are the designer's.
        GridColumn("device", "Device", width: 84),
        GridColumn("session", "Session Id", width: 90),
        GridColumn("battery", "Battery", width: 70),
        GridColumn("download", "Download", width: 90),
        GridColumn("recording", "Recording", width: 280),
    ]
}

/// The toolbar images.
///
/// Upstream sets one `Image` per `ToolStripButton` (`MainForm.Designer.cs`), and the MOP names one
/// of them by its picture -- "the \"Clear\" button, which has an eraser icon next to it" -- so the
/// port needs icons, not just labels. Each entry names the SF Symbol that stands in for OMGUI's
/// PNG, and the colour upstream's icon is drawn in (nil = the normal template tint).
struct ToolbarIcon: Equatable {
    let symbol: String
    let color: NSColor?

    init(_ symbol: String, _ color: NSColor? = nil) {
        self.symbol = symbol
        self.color = color
    }

    // toolStripMain (`Download.png`, a red circle-x, `Eraser.png`, `RecordHS.png`, `StopHS.png`,
    // a lit bulb).
    static let download = ToolbarIcon("square.and.arrow.down")
    static let cancel = ToolbarIcon("xmark.circle", .secondaryLabelColor)
    static let clear = ToolbarIcon("eraser.fill")
    static let record = ToolbarIcon("circle.fill", .systemRed)
    static let stop = ToolbarIcon("stop.fill", .secondaryLabelColor)
    static let identify = ToolbarIcon("lightbulb.fill")

    // toolStripFiles (`Resources.Export`, `FunctionHS`, `User`, `SyncTime`,
    // `EditBrightContrastHS`, the plugin jigsaw).
    static let export = ToolbarIcon("square.and.arrow.up")
    static let svm = ToolbarIcon("function")
    static let cutPoints = ToolbarIcon("person.fill")
    static let wearTime = ToolbarIcon("clock.fill")
    static let sleep = ToolbarIcon("moon.zzz.fill")
    static let plugins = ToolbarIcon("puzzlepiece.extension.fill")

    static let all: [(String, ToolbarIcon)] = [
        ("Download", .download), ("Cancel", .cancel), ("Clear", .clear),
        ("Record...", .record), ("Stop", .stop), ("Identify", .identify),
        ("Export", .export), ("SVM...", .svm), ("Cut Points...", .cutPoints),
        ("Wear Time...", .wearTime), ("Sleep Analysis...", .sleep), ("Plugins...", .plugins),
    ]

    /// The `NSImage`, coloured where upstream's icon is coloured. Returns nil when the symbol is
    /// missing from this OS, which `--self-test` checks for.
    func nsImage(pointSize: CGFloat = 11) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let color { configuration = configuration.applying(.init(paletteColors: [color])) }
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = (color == nil)
        return image
    }

    @ViewBuilder var view: some View {
        if let image = nsImage() {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol)
        }
    }
}

/// A toolbar button drawn the way a WinForms `ToolStripButton` is: image then text.
struct ToolbarButton: View {
    let title: String
    let icon: ToolbarIcon
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                icon.view
                Text(title)
            }
        }
        .help(help ?? title)
    }
}

/// `toolStripMain`.
struct DeviceToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ToolbarButton(title: "Download", icon: .download) { model.download() }
                .disabled(!model.toolbar.download)
            ToolbarButton(title: "Cancel", icon: .cancel, help: "Cancel Download") {
                model.cancelDownload()
            }
            .disabled(!model.toolbar.cancel)
            ToolbarButton(title: "Clear", icon: .clear,
                          help: "Clear Device (hold Shift for a quick format instead of a full wipe)") {
                model.clear(shiftHeld: NSEvent.modifierFlags.contains(.shift))
            }
            .disabled(!model.toolbar.clear)
            Divider().frame(height: 16)
            ToolbarButton(title: "Record...", icon: .record, help: "Record Interval") {
                model.openRecordingSettings()
            }
            .disabled(!model.toolbar.record)
            ToolbarButton(title: "Stop", icon: .stop, help: "Stop Recording") { model.stopRecording() }
                .disabled(!model.toolbar.stop)
            Divider().frame(height: 16)
            ToolbarButton(title: "Identify", icon: .identify) { model.identifySelected() }
                .disabled(!model.toolbar.identify)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// `groupBoxOptions` — the `toolStripData` Zoom/Selection buttons plus the channel check boxes,
/// in the row order `tableLayoutPanel1` puts them in.
struct DataOptionsBox: View {
    @EnvironmentObject var model: AppModel

    /// `tableLayoutPanel1.Controls.Add(...)` order.
    static let order: [DataChannel] = [.x, .y, .z, .svm, .light, .temperature,
                                       .batteryPercent, .batteryVolts, .time,
                                       .gyroX, .gyroY, .gyroZ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Options").font(.system(size: 10, weight: .semibold))
            HStack(spacing: 2) {
                ForEach(DataViewerMode.allCases) { mode in
                    Button(mode.rawValue) { model.dataViewerMode = mode }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(model.dataViewerMode == mode ? .accentColor : nil)
                        .help(mode.rawValue)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(DataOptionsBox.order) { channel in
                        Toggle(channel.title, isOn: Binding(
                            get: { model.dataChannels.contains(channel) },
                            set: { on in
                                if on { model.dataChannels.insert(channel) }
                                else { model.dataChannels.remove(channel) }
                            }))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                    }
                }
            }
            .frame(minHeight: 0, idealHeight: 24, maxHeight: .infinity)
        }
        .padding(4)
        .frame(idealHeight: 60, maxHeight: .infinity, alignment: .top)
    }
}

/// `toolStripWorkingFolder`.
struct WorkspaceBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text("Workspace:").font(.system(size: 11))
            TextField("", text: .constant(model.workspace.path))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(true)
            Button("...") { model.chooseWorkingFolder() }
                .help("Choose working folder")
            Button { model.openWorkingFolderInFinder() } label: {
                Image(systemName: "folder")
            }
            .help("Open working folder")
            Button { model.refreshFiles() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// `tabControlFiles`.
struct FilesTabView: View {
    @EnvironmentObject var model: AppModel

    private var tab: Int { model.filesTab }

    var body: some View {
        VStack(spacing: 0) {
            // `tabControlFiles` — a WinForms `TabControl` draws its tabs left-aligned along the top
            // edge, which SwiftUI's centre-aligned `TabView` does not do (and which does not render
            // its strip at all inside an `NSHostingView`).
            HStack(spacing: 2) {
                tabButton("Data Files", 0)
                tabButton("Plugin Queue", 1)
                tabButton("Output Files", 2)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 3)
            Divider()
            Group {
                switch tab {
                case 1: pluginQueueTab
                case 2: outputFilesTab
                default: dataFilesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        let selected = tab == index
        return Button { model.filesTab = index } label: {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(selected ? Color(nsColor: .controlBackgroundColor)
                                       : Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(index)")
    }

    // MARK: Data Files

    private var dataFilesTab: some View {
        VStack(spacing: 0) {
            WorkspaceListingNotice(folder: model.workspace)
            HStack(spacing: 6) {
                // `toolStripFiles` — every item is live only while a file is selected
                // (`filesListView_SelectedIndexChanged` / `FilesResetToolStripButtons`).
                Menu {
                    Button("Export Resampled WAV...") { model.exportResampledWav() }
                    Button("Export Resampled CSV...") { model.exportResampledCsv() }
                    Button("Export Raw CSV...") { model.exportRawCsv() }
                } label: {
                    HStack(spacing: 4) {
                        ToolbarIcon.export.view
                        Text("Export")
                    }
                }
                .disabled(!model.fileToolbarEnabled)
                .help("Export data")
                .fixedSize()
                fileToolButton("SVM...", .svm, "Calculate the scalar vector magnitude") { model.calculateSvm() }
                fileToolButton("Cut Points...", .cutPoints, "Calculate energy 'cut points'") { model.calculateCutPoints() }
                fileToolButton("Wear Time...", .wearTime, "Calculate wear time") { model.calculateWearTime() }
                fileToolButton("Sleep Analysis...", .sleep, "Sleep Analysis") { model.calculateSleepTime() }
                fileToolButton("Plugins...", .plugins, "Plugins") { model.showPlugins() }
                Divider().frame(height: 14)
                Button(model.showFilesButtonTitle) { model.toggleShowAllFiles() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.vertical, 4)

            // `splitContainerFileProperties` (Vertical, FixedPanel=Panel2, dist 738).
            SplitPaneView(.vertical,
                          distance: ContentView.filesTableWidth,
                          fixedPanel: .panel2,
                          panel1Minimum: 200,
                          panel2Minimum: 100,
                          panel2Collapsed: !model.showFileProperties) {
                GroupedTableView(columns: FileColumns.data,
                                 sections: [GridSection(id: "files", title: "", rows: model.dataFiles.map(FileColumns.row))],
                                 selection: Binding(get: { model.selectedFilePaths },
                                                    set: { model.selectedFilePaths = $0; model.fileSelectionChanged() }))
            } panel2: {
                PropertyGridView(title: "File", rows: model.filePropertyRows)
            }
        }
    }

    private func fileToolButton(_ title: String, _ icon: ToolbarIcon, _ help: String,
                                action: @escaping () -> Void) -> some View {
        ToolbarButton(title: title, icon: icon, help: help, action: action)
            .disabled(!model.fileToolbarEnabled)
    }

    // MARK: Plugin Queue

    @State private var queueSelection: Set<String> = []

    private var pluginQueueTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Cancel") {
                    model.pluginQueue.cancel(Set(queueSelection.compactMap(UUID.init(uuidString:))))
                }
                .disabled(queueSelection.isEmpty)
                Button("Clear Completed") { model.pluginQueue.clearCompleted() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.vertical, 4)

            GroupedTableView(columns: FileColumns.queue,
                             sections: [GridSection(id: "queue", title: "", rows: queueRows)],
                             selection: $queueSelection)
        }
    }

    private var queueRows: [GridRow] {
        model.pluginQueue.items.map { item in
            GridRow(id: item.id.uuidString, cells: [
                GridCell(item.pluginName),
                GridCell(item.source),
                GridCell(item.progressText),
            ])
        }
    }

    // MARK: Output Files

    private var outputFilesTab: some View {
        VStack(spacing: 0) {
            WorkspaceListingNotice(folder: model.workspace)
            GroupedTableView(columns: FileColumns.output,
                             sections: [GridSection(id: "output", title: "", rows: model.outputFiles.map(FileColumns.row))],
                             selection: Binding(get: { model.selectedOutputPaths },
                                                set: { model.selectedOutputPaths = $0 }))
        }
    }
}

/// Why the file lists are empty, when the folder could not be listed at all.
///
/// OMGUI has no equivalent because Windows has nothing like TCC: on macOS the default working
/// folder is `~/Documents`, and a "Don't Allow" there leaves a listing that fails silently and a
/// tab that looks like an empty folder (`refs/10-deep-review.md` C28).
struct WorkspaceListingNotice: View {
    let folder: URL

    private var failure: WorkspaceListingFailure? {
        guard let failure = WorkspaceListing.lastFailure, failure.folder == folder.path else { return nil }
        return failure
    }

    var body: some View {
        if let failure {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure.message)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
        }
    }
}

enum FileColumns {
    static let data = [
        GridColumn("name", "Name", width: 335),
        GridColumn("location", "File Location", width: 0),
        GridColumn("size", "Size (MB)", width: 78, alignment: .right),
        GridColumn("date", "Date Modified", width: 172),
    ]
    static let output = [
        GridColumn("name", "File Name", width: 351),
        GridColumn("location", "File Location", width: 0),
        GridColumn("size", "File Size (MB)", width: 116, alignment: .right),
        GridColumn("date", "Date Modified", width: 187),
    ]
    static let queue = [
        GridColumn("plugin", "Plugin", width: 162),
        GridColumn("source", "Source", width: 392),
        GridColumn("progress", "Progress (%)", width: 121, alignment: .right),
    ]

    static func row(_ file: WorkspaceFile) -> GridRow {
        GridRow(id: file.location, cells: [
            GridCell(file.name),
            GridCell(file.location),
            GridCell(file.sizeText),
            GridCell(file.dateText),
        ])
    }
}

/// `textBoxLog`.
struct LogPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .id("log-end")
            }
            .onChange(of: model.logText) { _, _ in
                proxy.scrollTo("log-end", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// `statusStripMain` — a spring label plus the 16 px progress slot.
struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.statusText)
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer()
            if let progress = model.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .controlSize(.small)
            } else {
                Color.clear.frame(width: 16, height: 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 22)
    }
}
