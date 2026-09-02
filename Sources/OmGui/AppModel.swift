import AppKit
import Foundation
import OmApi
import OmGuiCore
import SwiftUI

/// The single main-actor model behind the main window.
///
/// Mirrors `MainForm`: it owns the `OmApi` instance, the refresh timer, the device and file lists,
/// the selection-driven toolbar state and every flow the toolbar buttons run.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Configuration

    let options: LaunchOptions
    let settings: AppSettings
    let api: OmApi

    /// `MainForm.defaultTitleText` — "Open Movement [V<version>]" (`AppInfo`).
    static var defaultTitle: String { AppInfo.defaultTitleText() }

    // MARK: - Devices

    @Published private(set) var rows: [DeviceRow] = []
    @Published var selectedDeviceIds: Set<UInt32> = []
    @Published private(set) var toolbar = DeviceToolbarState()
    @Published private(set) var devicePropertyRows: [PropertyRow] = []

    private var devicesById: [UInt32: OmDevice] = [:]

    // MARK: - Workspace

    @Published private(set) var workspace: URL
    @Published private(set) var dataFiles: [WorkspaceFile] = []
    @Published private(set) var outputFiles: [WorkspaceFile] = []
    @Published var selectedFilePaths: Set<String> = []
    @Published var selectedOutputPaths: Set<String> = []
    @Published private(set) var filePropertyRows: [PropertyRow] = []
    @Published private(set) var recentFolders: [String] = []
    @Published var showAllFiles = false
    /// `tabControlFiles.SelectedIndex` — 0 Data Files, 1 Plugin Queue, 2 Output Files.
    @Published var filesTab = 0

    /// The Data Files toolbar is only live while a file is selected (`FilesResetToolStripButtons`).
    var fileToolbarEnabled: Bool { !selectedFilePaths.isEmpty }

    // MARK: - Preview

    @Published private(set) var dataViewerSource: DataViewerSource?
    @Published var dataChannels: Set<DataChannel> = DataChannel.defaultChannels
    @Published var dataViewerMode: DataViewerMode = .zoom
    @Published var dataSelection: ClosedRange<Date>?

    // MARK: - Chrome

    @Published var showToolbar = true
    @Published var showStatusBar = true
    @Published var showPreview = true
    @Published var showDeviceProperties = true
    @Published var showFileProperties = true
    @Published var showLog = false

    @Published private(set) var logText = ""
    @Published var statusText = ""
    /// The last "Recording configured on ..." line, held in the status bar until the selection
    /// changes so a site can read the Form 2 date/time off the window as well as the Log.
    @Published private(set) var recordingConfirmation: String?
    @Published private(set) var progress: Double?

    @Published var windowTitle = AppInfo.defaultTitleText()

    // MARK: - Sheets

    @Published var recordingSheet: RecordingSheetContext?
    @Published var showOptions = false
    @Published var showAbout = false
    @Published var progressSheet: ProgressSheetContext?

    /// Phase 3b: the Export/Tools option dialogs, the plugin list and the plugin's HTML form.
    @Published var exportSheet: ExportSheetContext?
    @Published var pluginsSheet: PluginsSheetContext?
    @Published var runPluginSheet: RunPluginSheetContext?
    /// `ExportData(List<string> files, …)` shows one "Export raw data" dialog per selected file.
    var pendingRawCsv: [String] = []

    let pluginQueue = PluginQueue()

    /// Runs the omconvert/cwa-convert/plugin jobs and feeds the Plugin Queue tab.
    private(set) lazy var jobs: ToolJobController = {
        let controller = ToolJobController(queue: pluginQueue)
        controller.log = { [weak self] line in self?.log(line) }
        controller.onJobFinished = { [weak self] _, _ in self?.refreshFiles() }
        return controller
    }()

    // MARK: - Internals

    private var refreshTimer: Timer?
    private var refreshIndex = 0
    private var refreshCounter = 0
    private var identify = IdentifyController()
    private var identifyDevices: [OmDevice] = []
    private var pollInFlight = false
    private var logHandle: FileHandle?
    /// `<final path>` for a download in flight, so the completion can be logged and verified.
    private var downloadPaths: [UInt32: DownloadPlan] = [:]

    // MARK: - Life cycle

    init(options: LaunchOptions, settings: AppSettings = AppSettings()) {
        self.options = options
        self.settings = settings
        self.api = OmApi(backend: options.makeBackend())

        if let folder = options.startupFolder { settings.workingFolderTemplate = folder }
        if let path = options.downloadLog { settings.downloadLogFile = path }
        if let path = options.configLog { settings.configLogFile = path }
        workspace = settings.workingFolder

        showToolbar = settings.viewFlag(AppSettings.Key.viewToolbar)
        showStatusBar = settings.viewFlag(AppSettings.Key.viewStatusBar)
        showPreview = settings.viewFlag(AppSettings.Key.viewPreview)
        showDeviceProperties = settings.viewFlag(AppSettings.Key.viewDeviceProperties)
        showFileProperties = settings.viewFlag(AppSettings.Key.viewFileProperties)
        showLog = settings.viewFlag(AppSettings.Key.viewLog)
        showAllFiles = settings.showAllFiles
        recentFolders = settings.recentFolders

        if let path = options.logFile {
            FileManager.default.createFile(atPath: path, contents: nil)
            logHandle = FileHandle(forWritingAtPath: path)
            _ = try? logHandle?.seekToEnd()
        }
    }

    func start() {
        for warning in options.warnings { log(warning) }

        api.onLog = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        api.onDeviceAttached = { [weak self] device in
            Task { @MainActor in self?.deviceAttached(device) }
        }
        api.onDeviceRemoved = { [weak self] device in
            Task { @MainActor in self?.deviceRemoved(device) }
        }
        api.onDeviceChanged = { [weak self] device, status in
            Task { @MainActor in self?.deviceChanged(device, status: status) }
        }

        do {
            try api.startup()
            log("Open Movement API started (\(api.backend.name)).")
        } catch {
            log("ERROR: could not start the Open Movement API: \(error)")
            NSAlert.omguiWarn(title: "OMAPI Startup Failed",
                              message: "Error starting OMAPI (\(error))")
        }

        setWorkingFolder(settings.workingFolderTemplate, remember: false)
        rebuildRows()

        // `refreshTimer` — 100 ms, exactly as the designer leaves it.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        persistViewFlags()
        api.shutdown()
        try? logHandle?.close()
    }

    func persistViewFlags() {
        settings.setViewFlag(AppSettings.Key.viewToolbar, showToolbar)
        settings.setViewFlag(AppSettings.Key.viewStatusBar, showStatusBar)
        settings.setViewFlag(AppSettings.Key.viewPreview, showPreview)
        settings.setViewFlag(AppSettings.Key.viewDeviceProperties, showDeviceProperties)
        settings.setViewFlag(AppSettings.Key.viewFileProperties, showFileProperties)
        settings.setViewFlag(AppSettings.Key.viewLog, showLog)
        settings.showAllFiles = showAllFiles
    }

    // MARK: - Log

    /// Empties the Log pane. Only `--self-test` uses it, so a captured screenshot shows the app's
    /// own output rather than the transcript the run has been writing alongside it.
    func clearLog() { logText = "" }

    func log(_ message: String) {
        logText += message + "\n"
        if logText.count > 400_000 { logText.removeFirst(logText.count - 400_000) }
        if let logHandle { try? logHandle.write(contentsOf: Data((message + "\n").utf8)) }
    }

    // MARK: - Device events

    private func deviceAttached(_ device: OmDevice) {
        devicesById[device.deviceId] = device
        log("Device attached: \(FilenameTemplate.deviceIdString(device.deviceId)) \(device.serialId)")
        rebuildRows()
    }

    private func deviceRemoved(_ device: OmDevice) {
        devicesById.removeValue(forKey: device.deviceId)
        selectedDeviceIds.remove(device.deviceId)
        log("Device removed: \(FilenameTemplate.deviceIdString(device.deviceId))")
        rebuildRows()
    }

    private func deviceChanged(_ device: OmDevice, status: DownloadStatus) {
        switch status {
        case .complete:
            finishDownload(device)
        case .cancelled:
            downloadPaths.removeValue(forKey: device.deviceId)
            log("Download cancelled: \(FilenameTemplate.deviceIdString(device.deviceId))")
        case .error:
            downloadPaths.removeValue(forKey: device.deviceId)
            log(String(format: "Download error (0x%X): %@", device.downloadValue,
                       FilenameTemplate.deviceIdString(device.deviceId)))
        default:
            break
        }
        rebuildRows()
    }

    private func finishDownload(_ device: OmDevice) {
        guard let plan = downloadPaths.removeValue(forKey: device.deviceId) else { return }
        // `OmDevice.finishedDownloading` performs the `.part` → `.cwa` rename.
        let final = plan.finalPath.path
        if plan.partialPath.path != final + ".part" {
            prompter.warn(title: "Warning",
                              message: "An inconsistency has been identified downloading a file -- please delete and download again:\n\n" + final)
        }
        log("DOWNLOAD-OK: \(final)")
        if let logPath = settings.downloadLogFile {
            let line = DownloadLog.line(filename: plan.finalPath.lastPathComponent)
            if !DownloadLog.append(line, to: logPath) {
                prompter.warn(title: "Warning",
                                  message: "Problem while appending to download log file (\(logPath)) - check the folder exists, you have write permission, and the file is not locked open by another process.")
            }
        }
        refreshFiles()
    }

    // MARK: - Polling (`refreshTimer_Tick`)

    private func tick() {
        refreshCounter += 1
        var doIdentify = false
        if refreshCounter % 5 == 0 { doIdentify = true }

        guard !pollInFlight else { return }

        if doIdentify && identify.isRunning {
            let state = identify.advance()
            let targets = identifyDevices
            pollInFlight = true
            Task.detached {
                for device in targets { _ = device.setLed(state) }
                await MainActor.run { self.pollInFlight = false }
            }
            return
        }

        let ordered = rows.map(\.deviceId)
        guard !ordered.isEmpty else { return }
        if refreshIndex >= ordered.count { refreshIndex = 0 }
        let deviceId = ordered[refreshIndex]
        refreshIndex += 1
        guard let device = devicesById[deviceId] else { return }

        pollInFlight = true
        let resetIfUnresponsive = options.resetIfUnresponsive
        Task.detached {
            let changed = device.update(resetIfUnresponsive: resetIfUnresponsive)
            await MainActor.run {
                self.pollInFlight = false
                if changed { self.rebuildRows() }
            }
        }
    }

    // MARK: - Rows and selection

    func rebuildRows() {
        let devices = api.devices
        devicesById = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0) })
        // `DeviceListView.Sorting = SortOrder.Ascending` sorts on the Device column. Category was
        // only ever a grouping key, and `MainForm` never assigns a group (see `DeviceGroup`), so
        // sorting by category here would impose an order the user has no header to explain.
        rows = devices
            .map { DeviceRow(device: $0, timeCheck: options.timeCheck) }
            .sorted { $0.deviceText == $1.deviceText ? $0.deviceId < $1.deviceId
                                                     : $0.deviceText < $1.deviceText }
        selectedDeviceIds = selectedDeviceIds.filter { devicesById[$0] != nil }
        selectionChanged()
    }

    /// The devices the toolbar acts on, in list order (`devicesListView.SelectedItems`).
    var selectedDevices: [OmDevice] {
        rows.filter { selectedDeviceIds.contains($0.deviceId) }.compactMap { devicesById[$0.deviceId] }
    }

    var selectedRows: [DeviceRow] {
        rows.filter { selectedDeviceIds.contains($0.deviceId) }
    }

    /// `listViewDevices_SelectedIndexChanged`.
    func selectionChanged() {
        toolbar = DeviceToolbarState(selection: selectedRows)

        if !selectedDeviceIds.isEmpty { selectedFilePaths.removeAll() }

        devicePropertyRows = showDeviceProperties ? PropertyGrid.rows(forDevices: selectedDevices) : []

        let devices = selectedDevices
        if devices.count == 1, devices[0].connected, !devices[0].isDownloading {
            dataViewerSource = .device(devices[0])
        } else if selectedFilePaths.count != 1 {
            dataViewerSource = nil
        }
        updateStatus()
    }

    /// `filesListView_SelectedIndexChanged`.
    func fileSelectionChanged() {
        if !selectedFilePaths.isEmpty { selectedDeviceIds.removeAll() }

        if showFileProperties, selectedFilePaths.count == 1, let path = selectedFilePaths.first {
            filePropertyRows = PropertyGrid.rows(for: FileMetadata(path: path))
        } else {
            filePropertyRows = []
        }

        if selectedFilePaths.count == 1, let path = selectedFilePaths.first {
            dataViewerSource = .file(URL(fileURLWithPath: path))
        } else if selectedDeviceIds.isEmpty {
            dataViewerSource = nil
        }
        toolbar = DeviceToolbarState(selection: selectedRows)
        updateStatus()
    }

    private func updateStatus() {
        guard progressSheet == nil else { return }
        if let recordingConfirmation {
            statusText = recordingConfirmation
            return
        }
        var parts: [String] = []
        parts.append("\(rows.count) device(s)")
        if !selectedDeviceIds.isEmpty { parts.append("\(selectedDeviceIds.count) selected") }
        parts.append("\(dataFiles.count) data file(s)")
        if !selectedFilePaths.isEmpty { parts.append("\(selectedFilePaths.count) file(s) selected") }
        statusText = parts.joined(separator: "   ")
    }

    // MARK: - Workspace

    /// `MainForm.SetWorkingFolder` + `LoadWorkingFolder`.
    func setWorkingFolder(_ template: String, remember: Bool = true) {
        if remember {
            recentFolders = settings.setWorkingFolder(template)
        } else {
            settings.workingFolderTemplate = template
            if settings.recentFolders.isEmpty {
                recentFolders = settings.setWorkingFolder(template)
            } else {
                recentFolders = settings.recentFolders
            }
        }
        var folder = WorkspacePath.url(template)
        if !FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                let fallback = WorkspacePath.url("{MyDocuments}")
                prompter.warn(title: "Error - Missing Working Folder",
                                  message: "Could not find last working folder: \(folder.path)\n\nDefaulting to: \(fallback.path)")
                settings.workingFolderTemplate = "{MyDocuments}"
                folder = fallback
            }
        }
        workspace = folder
        windowTitle = AppInfo.windowTitle(workspace: folder)
        refreshFiles()
    }

    func chooseWorkingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace
        panel.prompt = "Choose"
        panel.message = "Choose Working Folder"
        if panel.runModal() == .OK, let url = panel.url {
            setWorkingFolder(url.path)
        }
    }

    func openWorkingFolderInFinder() {
        NSWorkspace.shared.open(workspace)
    }

    func refreshFiles() {
        dataFiles = WorkspaceListing.dataFiles(in: workspace, showAll: showAllFiles)
        outputFiles = WorkspaceListing.outputFiles(in: workspace)
        selectedFilePaths = selectedFilePaths.filter { path in dataFiles.contains { $0.location == path } }
        selectedOutputPaths = selectedOutputPaths.filter { path in outputFiles.contains { $0.location == path } }
        fileSelectionChanged()
    }

    func toggleShowAllFiles() {
        showAllFiles.toggle()
        settings.showAllFiles = showAllFiles
        refreshFiles()
    }

    /// `toolStripButtonShowFiles.Text`.
    var showFilesButtonTitle: String { showAllFiles ? "Show *.CWA Only" : "Show All Files" }

    // MARK: - Flows

    /// The message-box implementation. `--self-test` swaps in a scripted one.
    var prompter: any UserPrompting = AlertPrompter()

    func download() {
        recordingConfirmation = nil
        dataViewerSource = nil
        let devices = selectedDevices
        let outcome = DownloadFlow.run(devices: devices,
                                       template: settings.filenameTemplate,
                                       workspace: workspace,
                                       prompt: prompter)
        for plan in outcome.started {
            downloadPaths[plan.deviceId] = plan
            log("Downloading \(FilenameTemplate.deviceIdString(plan.deviceId)) -> \(plan.finalPath.path)")
        }
        for key in outcome.errorOrder {
            log("Download refused for \(key): \(outcome.errors[key] ?? "")")
        }
        rebuildRows()
    }

    func cancelDownload() {
        recordingConfirmation = nil
        for device in selectedDevices where device.isDownloading {
            device.cancelDownload()
        }
        rebuildRows()
    }

    func clear(shiftHeld: Bool) {
        recordingConfirmation = nil
        let wipe = ClearFlow.wipeRequested(shiftHeld: shiftHeld)
        let selection = selectedDevices
        guard ensureNoSelectedDownloading(selection, prompt: prompter) else { return }
        let devices = selection.filter { !$0.isDownloading }

        guard prompter.confirm(title: windowTitle,
                               message: ClearFlow.promptMessage(wipe: wipe, count: selection.count)) else { return }

        dataViewerSource = nil
        let title = ClearFlow.progressTitle(wipe: wipe)
        runInBackground(title: title, message: "\(title) devices...") { progress in
            ClearFlow.perform(devices: devices, wipe: wipe, progress: progress)
        } completion: { [weak self] fails in
            guard let self else { return }
            if !fails.isEmpty {
                self.prompter.warn(title: FlowMessages.errorTitle, message: FlowMessages.failed(ids: fails))
            }
            self.rebuildRows()
        }
    }

    func stopRecording() {
        recordingConfirmation = nil
        let devices = selectedDevices
        dataViewerSource = nil
        runInBackground(title: "Stopping", message: "Stopping devices...") { progress in
            StopFlow.perform(devices: devices, progress: progress)
        } completion: { [weak self] fails in
            guard let self else { return }
            if !fails.isEmpty {
                self.prompter.warn(title: FlowMessages.errorTitle, message: FlowMessages.failed(ids: fails))
            }
            self.rebuildRows()
        }
    }

    func identifySelected() {
        identifyDevices = selectedDevices
        guard !identifyDevices.isEmpty else { return }
        identify.start()
        log("Identify: \(identifyDevices.map { FilenameTemplate.deviceIdString($0.deviceId) }.joined(separator: ", "))")
    }

    /// `toolStripButtonRecord_Click` up to the point the dialog opens.
    func openRecordingSettings() {
        recordingConfirmation = nil
        let devices = selectedDevices
        guard ensureNoSelectedDownloading(devices, prompt: prompter) else { return }

        for device in devices where device.warning == .damaged {
            var decided = false
            while !decided {
                switch prompter.abortRetryIgnore(title: FlowMessages.damagedTitle,
                                                 message: FlowMessages.damaged(deviceId: device.deviceId)) {
                case .ignore: decided = true
                case .retry: continue
                case .abort: return
                }
            }
        }

        var settingsModel = RecordingSettings(devices: devices.map(RecordingDeviceInfo.init(device:)))
        if let profile = RecordingProfile.load(from: workspace) {
            profile.apply(to: &settingsModel)
        } else {
            // No per-workspace profile yet: start from the ARIA MOP's values rather than OMGUI's,
            // so the only field a site has to touch is the Recording Session ID (MOP §9.4.2).
            settingsModel.applyInitialProfile()
        }
        settingsModel.finishInitialisation()
        recordingSheet = RecordingSheetContext(devices: devices, settings: settingsModel)
    }

    /// The dialog's OK button.
    func commitRecording(_ settingsModel: RecordingSettings, devices: [OmDevice]) {
        RecordingProfile(capturing: settingsModel).save(to: workspace)
        dataViewerSource = nil
        let configLog = settings.configLogFile

        runInBackground(title: "Configuring", message: "Configuring devices...") { progress in
            RecordFlow.perform(devices: devices, settings: settingsModel, progress: progress)
        } completion: { [weak self] result in
            guard let self else { return }
            for line in result.logLines {
                self.log(line)
                if let configLog { DownloadLog.append(line, to: configLog) }
            }
            // The line a site copies into Lasso Form 2 ("Date recording initiated in OMGUI").
            let now = Date()
            let confirmations = result.configured.map {
                RecordFlow.confirmationLine(deviceId: $0, sessionId: settingsModel.sessionId, at: now)
            }
            for line in confirmations { self.log(line) }
            if let last = confirmations.last { self.recordingConfirmation = last }
            if !result.failures.isEmpty {
                let details = result.failures.map { (id: $0.id, error: $0.error) }
                self.prompter.warn(title: FlowMessages.errorTitle, message: FlowMessages.failed(details: details))
            }
            self.rebuildRows()
        }
    }

    /// `ShowProgressWithBackground` — a modal progress sheet over a background worker.
    func runInBackground<T: Sendable>(title: String,
                                      message: String,
                                      work: @escaping @Sendable (ProgressHandler?) -> T,
                                      completion: @escaping @MainActor (T) -> Void) {
        let context = ProgressSheetContext(title: title, message: message)
        progressSheet = context
        progress = 0
        statusText = message

        Task.detached {
            let handler: ProgressHandler = { report in
                Task { @MainActor in
                    if report.percent >= 0 { self.progress = Double(report.percent) / 100.0 }
                    self.progressSheet?.message = report.message
                    self.statusText = report.message
                }
            }
            let result = work(handler)
            await MainActor.run {
                self.progressSheet = nil
                self.progress = nil
                completion(result)
                self.updateStatus()
            }
        }
    }
}

/// What the Recording Settings sheet is editing.
final class RecordingSheetContext: ObservableObject, Identifiable {
    let id = UUID()
    let devices: [OmDevice]
    @Published var settings: RecordingSettings

    init(devices: [OmDevice], settings: RecordingSettings) {
        self.devices = devices
        self.settings = settings
    }
}

final class ProgressSheetContext: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// `MessageBox` — OMGUI's prompts, as `NSAlert`s.
@MainActor
final class AlertPrompter: UserPrompting {

    func warn(title: String, message: String) {
        NSAlert.omguiWarn(title: title, message: message)
    }

    func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        // MessageBoxDefaultButton.Button2 — Cancel is the default.
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    func abortRetryIgnore(title: String, message: String) -> AbortRetryIgnore {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Ignore")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .retry
        case .alertThirdButtonReturn: return .ignore
        default: return .abort
        }
    }
}

extension NSAlert {
    @MainActor
    static func omguiWarn(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    static func omguiError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
