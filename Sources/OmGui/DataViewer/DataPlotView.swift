import AppKit
import OmApi
import OmGuiCore

/// OMGUI's `graphPanel`: the plot itself, drawn with CoreGraphics.
///
/// `DataViewer.OnPaint` walks one pixel column at a time, asks its cache for the aggregate over
/// that column, and draws each enabled channel as a 1 px rectangle spanning the column's min…max.
/// That is exactly what happens here, with the aggregate coming from `DataViewerModel`'s pyramid
/// instead of an LRU cache of decoded blocks, and the column loop rendered into a cached bitmap so
/// moving the cursor repaints only the strip under it.
final class DataPlotView: NSView {

    // MARK: - Inputs

    var model: DataViewerModel?

    var channels: Set<DataChannel> = DataChannel.defaultChannels {
        didSet { if channels != oldValue { invalidatePlot() } }
    }

    var mode: DataViewerMode = .zoom {
        didSet {
            if mode != oldValue {
                updateCursorShape()
                needsDisplay = true
            }
        }
    }

    /// The device being previewed, for the live refresh and the download-progress overlay.
    var device: OmDevice? {
        didSet { restartRefreshTimer() }
    }

    /// Reports the selected slice back to `AppModel.dataSelection`, which Export Raw CSV reads.
    var onSelectionChanged: ((ClosedRange<Date>?) -> Void)?

    // MARK: - State

    private(set) var axis = DataTimeAxis(bounds: 0...1, start: 0, span: 1, width: 1)
    private(set) var selection: DataViewerSelection?
    private var grip: DataViewerGrip = .none
    private var gripOffset: CGFloat = 0
    private var dragOrigin: CGFloat?
    private var dragCurrent: CGFloat?
    private var cursorX: CGFloat = -1
    private var cursorLabel = ""
    private var plotImage: CGImage?
    private var plotImageSize: CGSize = .zero
    private var columns: [ColumnAggregate] = []
    private var revision = -1
    private var loadedPath: String?
    private var refreshTimer: Timer?
    private var lastDownload = -1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The refresh timer lives only while the view is on screen — `deinit` is nonisolated and
    /// cannot touch it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            refreshTimer?.invalidate()
            refreshTimer = nil
        } else {
            restartRefreshTimer()
        }
    }

    // MARK: - Model plumbing

    /// Called on every model change; picks up new data, a grown recording, and load progress.
    func modelChanged() {
        guard let model else { return }
        if model.path != loadedPath {
            // A different file or device: `DataViewer.Reader`'s setter drops the selection and goes
            // back to the whole recording.
            loadedPath = model.path
            let hadSelection = selection != nil
            selection = nil
            grip = .none
            revision = -1
            if hadSelection {
                // Never write to the binding inside a SwiftUI update.
                let report = onSelectionChanged
                DispatchQueue.main.async { report?(nil) }
            }
        }
        guard let lod = model.lod else {
            if revision != -1 {
                revision = -1
                axis = DataTimeAxis(bounds: 0...1, start: 0, span: 1, width: max(bounds.width, 1))
                invalidatePlot()
            }
            return
        }
        guard model.revision != revision else { return }
        revision = model.revision
        let width = max(bounds.width, 1)
        if axis.bounds != lod.bounds || axis.width != width {
            // A recording that is still being written grows; a window the user zoomed into stays
            // where it is, a full-extent one keeps showing everything.
            axis = axis.rebound(to: lod.bounds, followingEnd: false).resized(width: width)
        }
        invalidatePlot()
    }

    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard device != nil else { return }
        // A device writes to `CWA-DATA.CWA` while it records, and its download percentage moves
        // under the plot; both want a slow tick rather than a redraw storm.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func tick() {
        guard window != nil else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        model?.refreshIfChanged()
        let progress = downloadProgress
        if progress != lastDownload {
            lastDownload = progress
            invalidatePlot()
        }
    }

    /// 0…100 while this device is downloading, else -1.
    private var downloadProgress: Int {
        guard let device, device.isDownloading else { return -1 }
        return max(0, min(100, device.downloadValue))
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        axis = axis.resized(width: max(newSize.width, 1))
        invalidatePlot()
    }

    private func invalidatePlot() {
        plotImage = nil
        requestDetailIfNeeded()
        needsDisplay = true
    }

    private func requestDetailIfNeeded() {
        guard let model, bounds.width >= 1 else { return }
        model.requestDetail(range: axis.range, columns: Int(bounds.width))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if plotImage == nil || plotImageSize != bounds.size { rebuildPlotImage() }
        if let plotImage {
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(plotImage, in: bounds)
            context.restoreGState()
        } else {
            Palette.lightGray.setFill()
            bounds.fill()
        }

        drawSelectionOverlay(in: context)
        drawCursorOverlay(in: context)
    }

    /// `DataViewer.OnPaint`'s bitmap, rebuilt only when the data, the window or the channels move.
    private func rebuildPlotImage() {
        plotImageSize = bounds.size
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { plotImage = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(data: nil,
                                      width: Int(size.width * scale),
                                      height: Int(size.height * scale),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)          // top-left origin, y downwards, as GDI+ has it
        context.interpolationQuality = .none
        drawPlot(in: context, size: size)
        plotImage = context.makeImage()
    }

    private func drawPlot(in context: CGContext, size: CGSize) {
        // `g.Clear(Color.LightGray)`.
        context.setFillColor(Palette.lightGray.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let width = Int(size.width)
        let height = size.height
        guard width > 0, let model, model.lod != nil else { return }

        if columns.count != width {
            columns = [ColumnAggregate](repeating: ColumnAggregate(), count: width)
        }
        model.columns(range: axis.range, into: &columns)

        let showTime = channels.contains(.time)
        let showOneG = channels.contains(.svm)
        let series = enabledSeries(hasGyro: model.hasGyro)

        // `OnPaint` issues one `DrawRectangle` per column per channel. Same rectangles, but
        // gathered per colour and filled in one call each: a thousand-column plot is then a dozen
        // CoreGraphics calls instead of several thousand.
        var bands: [(color: NSColor, rect: CGRect)] = []
        var bandStart = 0
        var bandColor: NSColor?
        var guides: [CGRect] = []
        var bars = [[CGRect]](repeating: [], count: series.count)
        for index in bars.indices { bars[index].reserveCapacity(width) }

        func flushBand(_ end: Int) {
            if let color = bandColor, end > bandStart {
                bands.append((color, CGRect(x: CGFloat(bandStart), y: 0,
                                            width: CGFloat(end - bandStart), height: height)))
            }
            bandColor = nil
        }

        for x in 0..<width {
            let column = columns[x]
            let px = CGFloat(x)

            // The background: an hour band, the missing-data hatch, or nothing.
            let background: NSColor?
            if !column.present {
                // `penMissing`/`penMissing2`, alternating every four pixels.
                background = ((x >> 2) & 1) == 0 ? Palette.lightGray : Palette.gray
            } else if showTime {
                background = Palette.hourBand(column.hourOfDay)
            } else {
                background = nil
            }
            if background !== bandColor {
                flushBand(x)
                bandColor = background
                bandStart = x
            }
            guard column.present else { continue }

            // The zero line, and the ±1 g guides — dotted by skipping columns.
            if (x & 3) < 2 {
                guides.append(CGRect(x: px, y: Plot.center * height, width: 1, height: 1))
            }
            if showOneG, (x & 7) < 1 {
                guides.append(CGRect(x: px, y: (Plot.center + Plot.accelScale) * height, width: 1, height: 1))
                guides.append(CGRect(x: px, y: (Plot.center - Plot.accelScale) * height, width: 1, height: 1))
            }

            for (index, entry) in series.enumerated() {
                let top = (1 - entry.map(column.maximum[entry.series])) * height
                let bottom = (1 - entry.map(column.minimum[entry.series])) * height
                bars[index].append(CGRect(x: px, y: top, width: 1, height: max(1, bottom - top + 1)))
            }
        }
        flushBand(width)

        for band in bands {
            context.setFillColor(band.color.cgColor)
            context.fill(band.rect)
        }
        if !guides.isEmpty {
            context.setFillColor(Palette.gray.cgColor)
            context.fill(guides)
        }
        for (index, entry) in series.enumerated() where !bars[index].isEmpty {
            context.setFillColor(entry.color.cgColor)
            context.fill(bars[index])
        }

        drawDownloadOverlay(in: context, size: size)
    }

    /// The green/white progress wash `DataViewer.OnPaint` carries commented out, over the plot of
    /// a device that is downloading (`refs/03 §6`).
    private func drawDownloadOverlay(in context: CGContext, size: CGSize) {
        let progress = downloadProgress
        guard progress >= 0 else { return }
        let split = CGFloat(progress) * size.width / 100

        func wash(_ colors: [NSColor], in rect: CGRect) {
            guard rect.width > 0,
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors.map(\.cgColor) as CFArray,
                                            locations: [0.0, 0.3, 1.0])
            else { return }
            context.saveGState()
            context.clip(to: rect)
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: size.height),
                                       options: [])
            context.restoreGState()
        }

        wash([Palette.progressGreen, Palette.progressWhite, Palette.progressGreen],
             in: CGRect(x: 0, y: 0, width: split, height: size.height))
        wash([Palette.progressDark, Palette.progressSmoke, Palette.progressDark],
             in: CGRect(x: split, y: 0, width: size.width - split, height: size.height))
    }

    /// `GraphPanel.OnPaint`'s selection: a translucent highlight, an outline, and a boxed label.
    private func drawSelectionOverlay(in context: CGContext) {
        _ = context
        var start: CGFloat
        var end: CGFloat
        var label: String

        if let origin = dragOrigin, let current = dragCurrent, mode == .zoom {
            // The rubber band a Zoom-mode drag paints before it commits.
            start = min(origin, current)
            end = max(origin, current)
            label = rangeDescription(axis.time(atX: Double(start))...axis.time(atX: Double(end)))
        } else if let selection, !selection.isEmpty {
            start = CGFloat(axis.x(forTime: selection.range.lowerBound))
            end = CGFloat(axis.x(forTime: selection.range.upperBound))
            label = rangeDescription(selection.range)
        } else {
            return
        }
        guard end > start else { return }

        let rect = CGRect(x: start, y: 0, width: end - start, height: bounds.height - 1)
        Palette.highlight.withAlphaComponent(0.25).setFill()
        rect.fill()
        Palette.highlight.setStroke()
        NSBezierPath(rect: rect).stroke()
        drawLabel(label, centeredAt: (start + end) / 2, top: 16)
    }

    /// `GraphPanel.OnPaint`'s cursor: a dotted line and the read-out box along the bottom.
    private func drawCursorOverlay(in context: CGContext) {
        guard cursorX >= 0 else { return }
        context.saveGState()
        context.setStrokeColor(Palette.darkGray.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [1, 2])
        context.move(to: CGPoint(x: cursorX + 0.5, y: 0))
        context.addLine(to: CGPoint(x: cursorX + 0.5, y: bounds.height))
        context.strokePath()
        context.restoreGState()

        guard !cursorLabel.isEmpty else { return }
        let size = Self.measure(cursorLabel)
        drawLabel(cursorLabel,
                  centeredAt: cursorX,
                  top: bounds.height - size.height - Plot.labelMargin - 1)
    }

    private func drawLabel(_ text: String, centeredAt centre: CGFloat, top: CGFloat) {
        let size = Self.measure(text)
        var x = centre - size.width / 2
        x = max(Plot.labelMargin, min(x, bounds.width - size.width - Plot.labelMargin - 1))
        if size.width + 2 * Plot.labelMargin >= bounds.width { x = (bounds.width - size.width) / 2 }
        let rect = CGRect(x: x, y: top, width: size.width, height: size.height)

        Palette.info.withAlphaComponent(0.4).setFill()
        rect.fill()
        NSColor.black.setStroke()
        NSBezierPath(rect: rect).stroke()
        NSAttributedString(string: text, attributes: Self.labelAttributes)
            .draw(with: rect.insetBy(dx: Plot.labelPadding, dy: Plot.labelPadding),
                  options: [.usesLineFragmentOrigin])
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.black,
    ]

    private static func measure(_ text: String) -> CGSize {
        // The read-out is multi-line once values are shown, so it has to be measured as a block.
        let attributed = NSAttributedString(string: text, attributes: labelAttributes)
        let bounds = attributed.boundingRect(with: CGSize(width: 400, height: 400),
                                             options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(bounds.width) + 2 * Plot.labelPadding,
                      height: ceil(bounds.height) + 2 * Plot.labelPadding)
    }

    // MARK: - Channels

    /// One drawing recipe per enabled channel: which series, what colour, and the mapping from the
    /// value to a fraction of the plot's height — `DataViewer.OnPaint`'s scale factors, exactly.
    struct SeriesPlot {
        let series: DataSeries
        let color: NSColor
        let map: (Float) -> CGFloat
    }

    private func enabledSeries(hasGyro: Bool) -> [SeriesPlot] {
        var result: [SeriesPlot] = []
        func accel(_ channel: DataChannel, _ series: DataSeries) {
            guard channels.contains(channel) else { return }
            result.append(SeriesPlot(series: series, color: channel.plotColor) { value in
                Plot.center + Plot.accelScale * CGFloat(value)
            })
        }
        func gyro(_ channel: DataChannel, _ series: DataSeries) {
            guard hasGyro, channels.contains(channel) else { return }
            result.append(SeriesPlot(series: series, color: channel.plotColor) { value in
                Plot.center + Plot.gyroScale * CGFloat(value)
            })
        }
        accel(.x, .x); accel(.y, .y); accel(.z, .z)
        gyro(.gyroX, .gyroX); gyro(.gyroY, .gyroY); gyro(.gyroZ, .gyroZ)
        if channels.contains(.light) {
            result.append(SeriesPlot(series: .light, color: DataChannel.light.plotColor) { value in
                CGFloat(value) / 1024
            })
        }
        if channels.contains(.temperature) {
            result.append(SeriesPlot(series: .temperature, color: DataChannel.temperature.plotColor) { value in
                Plot.temperatureScale * CGFloat(value)
            })
        }
        if channels.contains(.batteryPercent) {
            result.append(SeriesPlot(series: .batteryPercent,
                                     color: DataChannel.batteryPercent.plotColor) { value in
                (CGFloat(value) + 1) / 102
            })
        }
        if channels.contains(.batteryVolts) {
            result.append(SeriesPlot(series: .batteryMillivolts,
                                     color: DataChannel.batteryVolts.plotColor) { value in
                (CGFloat(value) + 1) / 4250
            })
        }
        return result
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: currentCursor)
    }

    private var currentCursor: NSCursor {
        let over = selection?.grip(atX: Double(cursorX), axis: axis) ?? .none
        switch over {
        case .begin, .end: return .resizeLeftRight
        case .move where mode == .selection: return .openHand
        default: return mode == .selection ? .iBeam : .crosshair
        }
    }

    private func updateCursorShape() {
        window?.invalidateCursorRects(for: self)
        currentCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard model?.lod != nil else { return }
        let x = convert(event.locationInWindow, from: nil).x
        cursorX = x
        if event.clickCount == 2 {
            // `graphPanel_DoubleClick`: over a selection, zoom to it. OMGUI has no reset gesture —
            // it zooms out by two, repeatedly — so a double-click anywhere else goes to the full
            // extent, which is what the phase-3 brief asks for.
            grip = .none
            dragOrigin = nil
            dragCurrent = nil
            if let selection, !selection.isEmpty,
               selection.grip(atX: Double(x), axis: axis) != DataViewerGrip.none {
                setAxis(axis.zoomed(to: selection.range))
            } else {
                setAxis(axis.fullExtent())
            }
            return
        }
        let over = selection?.grip(atX: Double(x), axis: axis) ?? .none

        if over == .none && mode == .selection {
            // `SelectionEnd` with both markers on the press point, then drag out the far end.
            selection = DataViewerSelection(begin: axis.time(atX: Double(x)),
                                            end: axis.time(atX: Double(x)))
            grip = .end
            gripOffset = 0
        } else if over == .begin || over == .end {
            grip = over
            let time = over == .begin ? selection!.begin : selection!.end
            gripOffset = x - CGFloat(axis.x(forTime: time))
        } else if over == .move && mode == .selection {
            grip = .move
            gripOffset = x - CGFloat(axis.x(forTime: selection!.begin))
        } else if mode == .zoom {
            dragOrigin = x
            dragCurrent = x
        }
        updateCursorShape()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        moveCursor(to: x, modifiers: event.modifierFlags)
        if grip != .none, var current = selection {
            grip = current.drag(grip, to: axis.time(atX: Double(x - gripOffset)))
            selection = current
            publishSelection()
            needsDisplay = true
        } else if dragOrigin != nil {
            dragCurrent = x
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if grip != .none {
            grip = .none
            if var current = selection {
                current.clamp(to: axis.bounds)      // `graphPanel_MouseUp`
                selection = current.isEmpty ? nil : current
            }
            publishSelection()
        } else if let origin = dragOrigin, mode == .zoom {
            dragOrigin = nil
            dragCurrent = nil
            if abs(x - origin) >= Plot.dragThreshold {
                // A rubber-band drag zooms to the band; a click zooms in by two, as `ZoomIn` does.
                let from = axis.time(atX: Double(min(origin, x)))
                let to = axis.time(atX: Double(max(origin, x)))
                setAxis(axis.zoomed(to: from...to))
            } else if model?.lod != nil {
                setAxis(axis.zoomedIn(at: axis.time(atX: Double(x))))
            }
        }
        dragOrigin = nil
        dragCurrent = nil
        moveCursor(to: x, modifiers: event.modifierFlags)
        updateCursorShape()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard model?.lod != nil else { return }
        let x = convert(event.locationInWindow, from: nil).x
        switch mode {
        case .zoom:
            setAxis(axis.zoomedOut(at: axis.time(atX: Double(x))))
        case .selection:
            // `graphPanel_Click`: a right click in Selection mode clears the selection.
            selection = nil
            publishSelection()
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        moveCursor(to: convert(event.locationInWindow, from: nil).x, modifiers: event.modifierFlags)
        updateCursorShape()
    }

    override func mouseExited(with event: NSEvent) {
        setCursor(x: -1, label: "")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self,
                                       userInfo: nil))
    }

    private func moveCursor(to x: CGFloat, modifiers: NSEvent.ModifierFlags) {
        setCursor(x: x, label: readout(atX: x, modifiers: modifiers))
    }

    private func setCursor(x: CGFloat, label: String) {
        guard x != cursorX || label != cursorLabel else { return }
        let old = cursorRect(cursorX, cursorLabel)
        cursorX = x
        cursorLabel = label
        // Only the strip under the cursor and its label box are stale.
        let new = cursorRect(x, label)
        setNeedsDisplay(old.isEmpty ? new : (new.isEmpty ? old : old.union(new)))
    }

    private func cursorRect(_ x: CGFloat, _ label: String) -> NSRect {
        guard x >= 0 else { return .zero }
        let size = Self.measure(label.isEmpty ? " " : label)
        return NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            .intersection(NSRect(x: x - size.width / 2 - 2, y: 0,
                                 width: size.width + 4, height: bounds.height))
    }

    private func publishSelection() {
        guard let selection, !selection.isEmpty else {
            onSelectionChanged?(nil)
            return
        }
        onSelectionChanged?(selection.dateRange)
    }

    func setAxis(_ newAxis: DataTimeAxis) {
        guard newAxis != axis else { return }
        axis = newAxis
        invalidatePlot()
    }

    /// `--self-test` hook: time a redraw, either a full recomposition of the plot bitmap or the
    /// cached-bitmap path a cursor move takes.
    func measureRedraw(rebuilding: Bool = true) -> TimeInterval {
        if rebuilding { plotImage = nil }
        let began = Date()
        display()
        return -began.timeIntervalSinceNow
    }

    // MARK: - Read-out

    /// `graphPanel_MouseMove`'s label. Upstream shows values on Ctrl and block detail on Shift;
    /// Ctrl-click is a right click on macOS, so values are on Option here.
    private func readout(atX x: CGFloat, modifiers: NSEvent.ModifierFlags) -> String {
        guard let model, model.lod != nil, x >= 0 else { return "" }
        let from = axis.time(atX: Double(x))
        let to = axis.time(atX: Double(x + 1))
        let column = model.aggregate(from: from, to: to)
        guard column.present else { return DataPlotView.timeString(from) }

        var lines = [DataPlotView.timeString(column.midTime)]
        let values = modifiers.contains(.option)
        func average(_ series: DataSeries) -> Float {
            (column.minimum[series] + column.maximum[series]) / 2
        }
        if values {
            if channels.contains(.x) { lines.append(String(format: "X: %+.2f g", average(.x))) }
            if channels.contains(.y) { lines.append(String(format: "Y: %+.2f g", average(.y))) }
            if channels.contains(.z) { lines.append(String(format: "Z: %+.2f g", average(.z))) }
            if model.hasGyro {
                if channels.contains(.gyroX) { lines.append(String(format: "GX: %+.2f dps", average(.gyroX))) }
                if channels.contains(.gyroY) { lines.append(String(format: "GY: %+.2f dps", average(.gyroY))) }
                if channels.contains(.gyroZ) { lines.append(String(format: "GZ: %+.2f dps", average(.gyroZ))) }
            }
        }
        if channels.contains(.light) { lines.append("Light: \(Int(average(.light)))") }
        if channels.contains(.temperature) { lines.append(String(format: "Temp: %.2f ^C", average(.temperature))) }
        if channels.contains(.batteryPercent) { lines.append("Batt: \(Int(average(.batteryPercent))) %") }
        if channels.contains(.batteryVolts) {
            lines.append(String(format: "Batt: %.3f V", average(.batteryMillivolts) / 1000))
        }
        if modifiers.contains(.shift) {
            lines.append("Count: \(column.count)")
            lines.append(String(format: "Span: %.3f s", to - from))
        }
        return lines.joined(separator: "\n")
    }

    /// `DataViewer.TimeString`. The clock is the device's own, which the CWA stores as wall time.
    static func timeString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func rangeDescription(_ range: ClosedRange<Double>) -> String {
        DataPlotView.timeString(range.lowerBound) + " - " + DataPlotView.timeString(range.upperBound)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Constants

/// `DataViewer.OnPaint`'s geometry.
enum Plot {
    /// `float center = 0.5f`.
    static let center: CGFloat = 0.5
    /// `float scale = 0.10f` — ±5 g fills the plot, whatever the recording's range.
    static let accelScale: CGFloat = 0.10
    /// `float gyroScale = 0.001f` — ±500 dps fills the plot.
    static let gyroScale: CGFloat = 0.001
    /// `0.02f * temp / 1000` with temperature in milli-centigrade, i.e. 0…50 °C over the height.
    static let temperatureScale: CGFloat = 0.02
    static let labelPadding: CGFloat = 3
    static let labelMargin: CGFloat = 2
    /// Below this a Zoom-mode press is a click (zoom in by two), above it a rubber band.
    static let dragThreshold: CGFloat = 3
}

/// The exact `System.Drawing` colours `DataViewer.cs` names, at the alpha it uses.
enum Palette {
    static func rgb(_ r: Int, _ g: Int, _ b: Int, alpha: Int = 255) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: CGFloat(alpha) / 255)
    }

    static let lightGray = rgb(211, 211, 211)       // Color.LightGray
    static let gray = rgb(128, 128, 128)            // Color.Gray
    static let darkGray = rgb(169, 169, 169)        // Color.DarkGray
    static let info = rgb(255, 255, 225)            // KnownColor.Info
    static let highlight = NSColor.selectedContentBackgroundColor

    static let progressGreen = rgb(0, 128, 0, alpha: 0x66)
    static let progressWhite = rgb(255, 255, 255, alpha: 0xCC)
    static let progressDark = rgb(169, 169, 169, alpha: 0x33)
    static let progressSmoke = rgb(245, 245, 245, alpha: 0x66)

    /// `penHours`: `v = 204 - hour`, ten lighter on even hours. Built once, so consecutive columns
    /// in the same hour compare equal by identity and collapse into a single fill.
    static let hourBands: [NSColor] = (0..<24).map { hour in
        var value = 204 - hour
        if (hour & 1) == 0 { value += 10 }
        return rgb(value, value, value)
    }

    static func hourBand(_ hour: Int) -> NSColor { hourBands[max(0, min(23, hour))] }
}
