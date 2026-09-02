import AppKit
import OmApi
import OmGuiCore

/// `--self-test`'s data-viewer leg: open a real multi-day recording in the real plot, drive real
/// mouse events through it, and assert what came out.
///
/// Nothing here simulates the viewer. The events go to `DataPlotView.mouseDown(with:)` and friends,
/// the selection is read back off the `AppModel` binding the export flow uses, and the frame times
/// are measured by forcing the view to recompose.
extension SelfTest {

    @MainActor
    static func exerciseViewer(model: AppModel,
                               say: @MainActor (String) -> Void,
                               shot: @MainActor (String) async -> Void,
                               pause: @MainActor (Double) async -> Void) async {

        guard let plot = DataViewerRegistry.shared.plot else {
            say("WARNING: the data viewer never appeared")
            return
        }

        // --- A multi-day recording to look at ----------------------------------------------
        let file = model.workspace.appendingPathComponent("viewer-preview.cwa")
        let began = Date()
        let written = SyntheticPreview.write(to: file, days: 2)
        say(String(format: "synthetic preview: %@ %.1f MB, %.1f h, written in %.2f s",
                   file.lastPathComponent, Double(written.bytes) / 1_048_576,
                   written.hours, -began.timeIntervalSinceNow))
        model.refreshFiles()

        guard let row = model.dataFiles.first(where: { $0.name == file.lastPathComponent }) else {
            say("WARNING: the synthetic preview file is not in the workspace listing")
            return
        }
        model.selectedFilePaths = [row.location]
        model.fileSelectionChanged()

        guard let viewer = await waitForViewer(path: row.location, say: say, pause: pause) else { return }
        let lod = viewer.lod
        say(String(format: "opened %@: %d blocks, %.1f h, base bucket %.0f s, levels %@, %d KB of buckets",
                   file.lastPathComponent,
                   lod?.blocksRead ?? 0,
                   ((lod?.bounds.upperBound ?? 0) - (lod?.bounds.lowerBound ?? 0)) / 3600,
                   lod?.baseDuration ?? 0,
                   (lod?.levelDurations ?? []).map { String(format: "%.0f", $0) }.joined(separator: "/"),
                   (lod?.byteCount ?? 0) / 1024))
        await shot("14-viewer-file.png")

        // --- Channels ------------------------------------------------------------------------
        model.dataChannels = Set(DataChannel.allCases)
        await pause(0.4)
        say("all twelve channels on: " + DataOptionsBox.order.map(\.title).joined(separator: " "))
        await shot("14-viewer-channels.png")

        model.dataChannels = [.x, .y, .z, .light, .temperature, .batteryPercent, .time, .svm]
        await pause(0.4)
        say("hour bands and the ±1g guides on, gyro off (this file is an AX3: hasGyro=\(viewer.hasGyro))")
        await shot("14-viewer-bands.png")

        // --- Zoom ----------------------------------------------------------------------------
        model.dataViewerMode = .zoom
        await pause(0.2)
        let fullSpan = plot.axis.span
        drag(plot, from: 0.35, to: 0.45)
        await pause(0.4)
        say(String(format: "rubber-band zoom: %.1f h -> %.1f min (%@ .. %@)",
                   fullSpan / 3600, plot.axis.span / 60,
                   DataPlotView.timeString(plot.axis.start),
                   DataPlotView.timeString(plot.axis.end)))
        await shot("14-viewer-zoom.png")

        let zoomedSpan = plot.axis.span
        click(plot, at: 0.5)
        await pause(0.3)
        say(String(format: "click zoom-in: %.1f min -> %.1f min (halved, as ZoomIn does)",
                   zoomedSpan / 60, plot.axis.span / 60))

        let deepSpan = plot.axis.span
        click(plot, at: 0.5, type: .rightMouseDown)
        await pause(0.3)
        say(String(format: "right-click zoom-out: %.1f min -> %.1f min (doubled)",
                   deepSpan / 60, plot.axis.span / 60))
        await shot("14-viewer-zoomed-detail.png")

        // Deep enough that the pyramid's base bucket is too coarse and the model reads the window
        // back off disk.
        for _ in 0..<8 { click(plot, at: 0.5) }
        await pause(0.8)
        say(String(format: "eight more zoom-ins: span %.1f s, %.3f s per pixel, detail window %@",
                   plot.axis.span, plot.axis.secondsPerPoint,
                   viewer.detail.map { String(format: "%.3f s buckets", $0.duration) } ?? "(none)"))
        await shot("14-viewer-detail.png")

        doubleClick(plot, at: 0.5)
        await pause(0.4)
        say(String(format: "double-click reset: back to %.1f h (full extent = %@)",
                   plot.axis.span / 3600, "\(plot.axis.isFullExtent)"))

        // --- Selection -------------------------------------------------------------------------
        model.dataViewerMode = .selection
        await pause(0.2)
        let from = 0.30, to = 0.55
        drag(plot, from: from, to: to)
        await pause(0.4)
        let expectedLow = plot.axis.time(atX: Double(plot.bounds.width) * from)
        let expectedHigh = plot.axis.time(atX: Double(plot.bounds.width) * to)
        if let selection = model.dataSelection {
            let lowError = abs(selection.lowerBound.timeIntervalSince1970 - expectedLow)
            let highError = abs(selection.upperBound.timeIntervalSince1970 - expectedHigh)
            let span = selection.upperBound.timeIntervalSince(selection.lowerBound)
            say(String(format: "selection binding: %@ .. %@ (%.1f min); error vs the dragged pixels %.3f s / %.3f s -> %@",
                       DataPlotView.timeString(selection.lowerBound.timeIntervalSince1970),
                       DataPlotView.timeString(selection.upperBound.timeIntervalSince1970),
                       span / 60, lowError, highError,
                       (lowError < 1 && highError < 1) ? "OK" : "MISMATCH"))
        } else {
            say("FAIL: the selection binding is still empty after a drag in Selection mode")
        }
        await shot("14-viewer-selection.png")

        // Drag the end marker, then clear with a right click, as `graphPanel_Click` does.
        drag(plot, from: to, to: 0.70)
        await pause(0.3)
        if let selection = model.dataSelection {
            say(String(format: "after dragging the end marker: %.1f min",
                       selection.upperBound.timeIntervalSince(selection.lowerBound) / 60))
        }
        click(plot, at: 0.5, type: .rightMouseDown)
        await pause(0.3)
        say("right-click in Selection mode cleared the selection: \(model.dataSelection == nil)")

        // --- Frame times --------------------------------------------------------------------
        var frames: [String] = []
        let origin = plot.axis.bounds.lowerBound
        let full = plot.axis.fullExtent()
        let cases: [(String, DataTimeAxis)] = [
            ("full extent", full),
            ("1 hour", full.zoomed(to: (origin + 3_600)...(origin + 7_200))),
            ("1 minute", full.zoomed(to: (origin + 3_600)...(origin + 3_660))),
        ]
        for (name, axis) in cases {
            plot.setAxis(axis)
            await pause(0.2)
            var worstFull = 0.0, totalFull = 0.0
            var worstBlit = 0.0, totalBlit = 0.0
            for _ in 0..<20 {
                let full = plot.measureRedraw()
                worstFull = max(worstFull, full)
                totalFull += full
                let blit = plot.measureRedraw(rebuilding: false)
                worstBlit = max(worstBlit, blit)
                totalBlit += blit
            }
            frames.append(String(format: "%@ %.1f/%.1f ms recompose, %.2f/%.2f ms cached",
                                 name, totalFull / 20 * 1000, worstFull * 1000,
                                 totalBlit / 20 * 1000, worstBlit * 1000))
        }
        say(String(format: "redraw (mean/worst of 20, plot %.0fx%.0f pt): ",
                   plot.bounds.width, plot.bounds.height)
            + frames.joined(separator: "; ") + " -- 60 fps is 16.7 ms")

        // The same plot with the preview pane dragged tall, which is the expensive case.
        let restore = plot.frame.size
        plot.setFrameSize(NSSize(width: restore.width, height: 460))
        plot.setAxis(full)
        var tall = 0.0
        for _ in 0..<10 { tall = max(tall, plot.measureRedraw()) }
        say(String(format: "redraw with the preview pane dragged to %.0fx460 pt: %.1f ms worst",
                   restore.width, tall * 1000))
        plot.setFrameSize(restore)

        // --- A device in the viewer ------------------------------------------------------------
        model.dataChannels = DataChannel.defaultChannels
        model.dataViewerMode = .zoom
        model.selectedFilePaths = []
        model.fileSelectionChanged()

        if let target = model.rows.first?.deviceId, let device = model.api.device(target) {
            // Every mock device was wiped by the Clear step above, so give this one two hours of
            // data to preview: `CWA-DATA.CWA` on the mock volume is a real file, which is exactly
            // what `OmDevice.dataFilePath` hands the reader on real hardware.
            let onDevice = SyntheticPreview.write(to: URL(fileURLWithPath: device.dataFilePath),
                                                  hours: 2,
                                                  deviceId: device.deviceId,
                                                  sessionId: device.sessionId)
            device.update(force: true)
            model.rebuildRows()
            model.selectedDeviceIds = [target]
            model.selectionChanged()
            say(String(format: "device %@: %.1f MB of data at %@",
                       FilenameTemplate.deviceIdString(target),
                       Double(onDevice.bytes) / 1_048_576, device.dataFilePath))

            if let deviceViewer = await waitForViewer(path: device.dataFilePath, say: say, pause: pause) {
                say(String(format: "device preview: %d blocks, %.1f h, opened %@",
                           deviceViewer.lod?.blocksRead ?? 0,
                           ((deviceViewer.lod?.bounds.upperBound ?? 0)
                            - (deviceViewer.lod?.bounds.lowerBound ?? 0)) / 3600,
                           deviceViewer.path == device.dataFilePath ? "the device's own file" : "the wrong file"))
            }
            await shot("14-viewer-device.png")

            await captureDownloadOverlay(model: model, plot: plot, device: device, say: say, pause: pause)

            model.selectedDeviceIds = []
            model.selectionChanged()
        }

        try? FileManager.default.removeItem(at: file)
        model.refreshFiles()
    }

    /// Waits for the plot's model to open `path` and finish its background load. The path matters:
    /// the model is still `.ready` on the *previous* source until SwiftUI hands it the new one.
    @MainActor
    private static func waitForViewer(path: String,
                                      say: @MainActor (String) -> Void,
                                      pause: @MainActor (Double) async -> Void) async -> DataViewerModel? {
        guard let model = DataViewerRegistry.shared.model else {
            say("WARNING: the data viewer has no model")
            return nil
        }
        for _ in 0..<400 {
            if model.path == path {
                if case .ready = model.state { return model }
                if case .failed(let message) = model.state {
                    say("the viewer could not open \(path): \(message)")
                    return nil
                }
            }
            await pause(0.05)
        }
        say("WARNING: the viewer did not open \(path) (path=\(model.path ?? "nil") state=\(model.state))")
        return nil
    }

    /// The download-progress wash, over a plot that has data in it.
    ///
    /// `AppModel.download()` clears `dataViewerSource`, so in this port a download closes the
    /// preview and the overlay cannot be reached by clicking (see `refs/06`). The overlay itself is
    /// real: the view reads `OmDevice.downloadValue` off a device that is genuinely downloading,
    /// and the capture below is taken without yielding to the run loop, so nothing repaints between
    /// the redraw and the screenshot.
    @MainActor
    private static func captureDownloadOverlay(model: AppModel,
                                               plot: DataPlotView,
                                               device: OmDevice,
                                               say: @MainActor (String) -> Void,
                                               pause: @MainActor (Double) async -> Void) async {
        guard let mock = model.api.backend as? MockBackend else { return }
        let steps = mock.downloadStepCount
        let delay = mock.downloadStepDelay
        mock.downloadStepCount = 40
        mock.downloadStepDelay = 0.05
        defer {
            mock.downloadStepCount = steps
            mock.downloadStepDelay = delay
        }

        model.selectedDeviceIds = [device.deviceId]
        model.selectionChanged()
        model.download()
        for _ in 0..<200 where !device.isDownloading { await pause(0.02) }
        guard device.isDownloading else {
            say("download overlay: the device never started downloading, no capture")
            return
        }
        // `download()` closed the preview, so put a file back in it — the overlay is drawn over
        // whatever the plot is showing.
        if let row = model.dataFiles.first(where: { $0.name == "viewer-preview.cwa" }) {
            model.selectedFilePaths = [row.location]
            model.fileSelectionChanged()
            _ = await waitForViewer(path: row.location, say: say, pause: pause)
        }
        for _ in 0..<200 where device.isDownloading && device.downloadValue < 35 { await pause(0.02) }

        plot.device = device
        _ = plot.measureRedraw()
        let url = SelfTest.screenshotFolder?.appendingPathComponent("14-viewer-download.png")
        let captured = url.map { SelfTest.capture(to: $0) } ?? false
        say("download overlay at \(device.downloadValue)% captured=\(captured) "
            + "(a self-test hook: AppModel closes the preview when a download starts)")
        plot.device = nil

        for _ in 0..<300 where device.isDownloading { await pause(0.05) }
        model.rebuildRows()
    }

    // MARK: - Real mouse events

    @MainActor
    private static func event(_ plot: DataPlotView,
                              _ type: NSEvent.EventType,
                              at fraction: Double,
                              clickCount: Int) -> NSEvent? {
        let point = NSPoint(x: plot.bounds.width * CGFloat(fraction), y: plot.bounds.midY)
        let inWindow = plot.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type,
                                  location: inWindow,
                                  modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: plot.window?.windowNumber ?? 0,
                                  context: nil,
                                  eventNumber: 0,
                                  clickCount: clickCount,
                                  pressure: 1)
    }

    @MainActor
    private static func click(_ plot: DataPlotView,
                              at fraction: Double,
                              type: NSEvent.EventType = .leftMouseDown) {
        guard let down = event(plot, type, at: fraction, clickCount: 1) else { return }
        if type == .rightMouseDown {
            plot.rightMouseDown(with: down)
            return
        }
        plot.mouseDown(with: down)
        if let up = event(plot, .leftMouseUp, at: fraction, clickCount: 1) { plot.mouseUp(with: up) }
    }

    @MainActor
    private static func doubleClick(_ plot: DataPlotView, at fraction: Double) {
        guard let down = event(plot, .leftMouseDown, at: fraction, clickCount: 2) else { return }
        plot.mouseDown(with: down)
        if let up = event(plot, .leftMouseUp, at: fraction, clickCount: 2) { plot.mouseUp(with: up) }
    }

    @MainActor
    private static func drag(_ plot: DataPlotView, from: Double, to: Double) {
        guard let down = event(plot, .leftMouseDown, at: from, clickCount: 1) else { return }
        plot.mouseDown(with: down)
        for step in 1...4 {
            let fraction = from + (to - from) * Double(step) / 4
            if let moved = event(plot, .leftMouseDragged, at: fraction, clickCount: 1) {
                plot.mouseDragged(with: moved)
            }
        }
        if let up = event(plot, .leftMouseUp, at: to, clickCount: 1) { plot.mouseUp(with: up) }
    }
}

/// A synthetic multi-day `.CWA`, so `--self-test` has something worth plotting: a day/night light
/// cycle, a slow temperature drift, a draining battery, quiet nights and busy days, and a hole in
/// the middle where a real device would have stopped.
enum SyntheticPreview {

    @discardableResult
    static func write(to url: URL,
                      days: Double = 0,
                      hours: Double = 0,
                      deviceId: UInt32 = 1234,
                      sessionId: UInt32 = 1) -> (bytes: Int, hours: Double) {
        // 25 Hz keeps a two-day file to ~27 MB while still being a rate the AX3 records at.
        let config = AccelConfig(rate: .hz25, range: .g8)
        var writer = CwaWriter(hardware: .ax3, deviceId: deviceId, sessionId: sessionId, config: config,
                               metadata: MetadataTools.create([.init("_s", "ARIA-IMPACT"),
                                                               .init("_sc", "P001")]))
        let perBlock = writer.samplesPerBlock
        let rate = config.rate.hz
        let blockSeconds = Double(perBlock) / rate
        let seconds = days * 86_400 + hours * 3_600
        let blocks = Int(seconds / blockSeconds)
        // Recording starts at 18:00, so the first screenshot spans an evening, a night and a day.
        let start = OmDateTime(year: 2026, month: 8, day: 30, hour: 18, minute: 0, second: 0)
        guard let base = start.date(in: .gmt) else { return (0, 0) }

        // A gap on the second evening: a device that stopped for twenty minutes.
        let gapFrom = seconds * 0.55
        let gapTo = gapFrom + 1_200

        var data = Data(writer.headerBlock())
        data.reserveCapacity(blocks * CwaWriter.blockSize + CwaWriter.headerSize)
        var samples = [Int16](repeating: 0, count: perBlock * 3)

        for block in 0..<blocks {
            let blockStart = Double(block) * blockSeconds
            if blockStart >= gapFrom && blockStart < gapTo { continue }

            let hour = (blockStart / 3600 + 18).truncatingRemainder(dividingBy: 24)
            let daylight = hour > 7 && hour < 21
            let activity = daylight ? 0.35 + 0.3 * sin(blockStart / 900) : 0.02

            for i in 0..<perBlock {
                let t = blockStart + Double(i) / rate
                // A slow posture component plus a burst of "movement" scaled by the time of day.
                let posture = sin(t / 3600)
                let motion = activity * sin(2 * .pi * 2.7 * t) * (0.5 + 0.5 * sin(t / 37))
                samples[i * 3 + 0] = clamp((0.15 * posture + motion) * 256)
                samples[i * 3 + 1] = clamp((0.30 * cos(t / 2700) + 0.7 * motion) * 256)
                samples[i * 3 + 2] = clamp((0.90 + 0.1 * posture + 0.5 * motion) * 256)
            }

            // Light: bright in the day, near dark at night. Temperature: a slow diurnal drift.
            // Battery: a steady drain across the recording.
            let light = daylight ? 300.0 + 500 * sin(.pi * (hour - 7) / 14) : 4
            writer.light = UInt16(max(0, min(1023, light)))
            let celsius = 26.5 + 3.5 * sin(2 * .pi * (hour - 9) / 24)
            writer.temperature = UInt16(max(0, min(1023, (celsius * 1000 + 50_000) * 256 / 75_000)))
            writer.battery = UInt8(max(0, min(255, 210 - 70 * blockStart / seconds)))

            let wholeSecond = blockStart.rounded(.up)
            let offset = Int16(clamping: Int(((wholeSecond - blockStart) * rate).rounded()))
            data.append(contentsOf: writer.dataBlock(
                sequenceId: UInt32(block),
                timestamp: OmDateTime(date: base.addingTimeInterval(wholeSecond), in: .gmt),
                timestampOffset: offset,
                samples: samples,
                events: block == 0 ? 0x01 : 0x00))
        }

        try? data.write(to: url)
        return (data.count, seconds / 3600)
    }

    private static func clamp(_ value: Double) -> Int16 {
        Int16(max(-32_768, min(32_767, value.rounded())))
    }
}
