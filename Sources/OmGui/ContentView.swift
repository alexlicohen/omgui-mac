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

    private var deviceSections: [GridSection] {
        let grouped = Dictionary(grouping: model.rows, by: \.category)
        return SourceCategory.displayOrder.compactMap { category in
            guard let rows = grouped[category], !rows.isEmpty else { return nil }
            return GridSection(id: category.rawValue,
                               title: category.groupName,
                               rows: rows.map { row in
                                   GridRow(id: String(row.deviceId), cells: [
                                       GridCell(row.deviceText, iconIndex: row.ledIconIndex),
                                       GridCell(row.sessionText),
                                       GridCell(row.batteryText, color: row.batteryColor),
                                       GridCell(row.downloadText, color: row.downloadColor),
                                       GridCell(row.recordingText, color: row.recordingColor),
                                   ])
                               })
        }
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
        GridColumn("device", "Device", width: 70),
        GridColumn("session", "Session Id", width: 90),
        GridColumn("battery", "Battery", width: 70),
        GridColumn("download", "Download", width: 90),
        GridColumn("recording", "Recording", width: 280),
    ]
}

/// `toolStripMain`.
struct DeviceToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button("Download") { model.download() }
                .disabled(!model.toolbar.download)
            Button("Cancel") { model.cancelDownload() }
                .disabled(!model.toolbar.cancel)
                .help("Cancel Download")
            Button("Clear") { model.clear(shiftHeld: NSEvent.modifierFlags.contains(.shift)) }
                .disabled(!model.toolbar.clear)
                .help("Clear Device (hold Shift for a quick format instead of a full wipe)")
            Divider().frame(height: 16)
            Button("Record...") { model.openRecordingSettings() }
                .disabled(!model.toolbar.record)
                .help("Record Interval")
            Button("Stop") { model.stopRecording() }
                .disabled(!model.toolbar.stop)
                .help("Stop Recording")
            Divider().frame(height: 16)
            Button("Identify") { model.identifySelected() }
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
            HStack(spacing: 6) {
                // `toolStripFiles` — every item is live only while a file is selected
                // (`filesListView_SelectedIndexChanged` / `FilesResetToolStripButtons`).
                Menu("Export") {
                    Button("Export Resampled WAV...") { model.exportResampledWav() }
                    Button("Export Resampled CSV...") { model.exportResampledCsv() }
                    Button("Export Raw CSV...") { model.exportRawCsv() }
                }
                .disabled(!model.fileToolbarEnabled)
                .fixedSize()
                fileToolButton("SVM...") { model.calculateSvm() }
                fileToolButton("Cut Points...") { model.calculateCutPoints() }
                fileToolButton("Wear Time...") { model.calculateWearTime() }
                fileToolButton("Sleep Analysis...") { model.calculateSleepTime() }
                fileToolButton("Plugins...") { model.showPlugins() }
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

    private func fileToolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
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
        GroupedTableView(columns: FileColumns.output,
                         sections: [GridSection(id: "output", title: "", rows: model.outputFiles.map(FileColumns.row))],
                         selection: Binding(get: { model.selectedOutputPaths },
                                            set: { model.selectedOutputPaths = $0 }))
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
