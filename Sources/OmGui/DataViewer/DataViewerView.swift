import AppKit
import Foundation
import OmApi
import OmGuiCore
import SwiftUI

/// What the preview is showing (`DataViewer.Open(filename)` / `DataViewer.Open(deviceId)`).
enum DataViewerSource: Identifiable {
    case file(URL)
    case device(OmDevice)

    var id: String {
        switch self {
        case .file(let url): return "file:" + url.path
        case .device(let device): return "device:\(device.deviceId)"
        }
    }

    /// The name shown in the preview area.
    var displayName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .device(let device):
            let id = FilenameTemplate.deviceIdString(device.deviceId)
            return device.serialId.isEmpty ? id : "\(id) (\(device.serialId))"
        }
    }

    /// The file the plot reads.
    ///
    /// Upstream's `OmReader.Open(deviceId)` calls `OmReaderOpenDeviceData`, which this build of
    /// libomapi does not export; the device's mounted `CWA-DATA.CWA` is the same bytes, and is
    /// what `OmDevice.dataFilePath` already points at.
    var path: String {
        switch self {
        case .file(let url): return url.path
        case .device(let device): return device.dataFilePath
        }
    }

    var device: OmDevice? {
        if case .device(let device) = self { return device }
        return nil
    }
}

/// The `groupBoxOptions` check boxes, in the order the table-layout panel lists them.
enum DataChannel: String, CaseIterable, Identifiable, Hashable {
    case x = "X-Axis"
    case y = "Y-Axis"
    case z = "Z-Axis"
    case gyroX = "Gyro-X"
    case gyroY = "Gyro-Y"
    case gyroZ = "Gyro-Z"
    case svm = "\u{00B1}1g"
    case light = "Light"
    case temperature = "Temp."
    case batteryPercent = "Batt.%"
    case batteryVolts = "Batt.V"
    case time = "Time"

    var id: String { rawValue }
    var title: String { rawValue }

    /// X, Y and Z start checked (`DataViewer.Designer.cs`).
    static let defaultChannels: Set<DataChannel> = [.x, .y, .z]

    /// The pen `DataViewer.OnPaint` draws this channel with: the `System.Drawing` colour named in
    /// `refs/03 §6` at alpha 96, which is what makes overlapping channels read as a blend.
    ///
    /// `±1g` and `Time` are not data channels — `±1g` adds the two dotted guide lines at ±1 g and
    /// `Time` switches on the per-hour background banding — so their colours are the ones those
    /// decorations use.
    var plotColor: NSColor {
        switch self {
        case .x: return Palette.rgb(255, 0, 0, alpha: 96)                 // Red
        case .y: return Palette.rgb(0, 128, 0, alpha: 96)                 // Green
        case .z: return Palette.rgb(0, 0, 255, alpha: 96)                 // Blue
        case .gyroX: return Palette.rgb(0, 255, 255, alpha: 96)           // Cyan
        case .gyroY: return Palette.rgb(255, 0, 255, alpha: 96)           // Magenta
        case .gyroZ: return Palette.rgb(255, 255, 0, alpha: 96)           // Yellow
        case .svm: return Palette.rgb(0, 0, 0, alpha: 96)                 // Black
        case .light: return Palette.rgb(165, 42, 42, alpha: 96)           // Brown
        case .temperature: return Palette.rgb(139, 0, 139, alpha: 96)     // DarkMagenta
        case .batteryPercent: return Palette.rgb(0, 139, 139, alpha: 96)  // DarkCyan
        case .batteryVolts: return Palette.rgb(224, 255, 255, alpha: 96)  // LightCyan
        case .time: return Palette.gray
        }
    }

    /// The same colours for SwiftUI.
    var penColor: Color { Color(nsColor: plotColor.withAlphaComponent(1)) }
}

/// `DataViewer.Mode`.
enum DataViewerMode: String, CaseIterable, Identifiable {
    case zoom = "Zoom"
    case selection = "Selection"
    var id: String { rawValue }
}

/// The preview pane — `DataViewer` minus the options box, which the main window owns in this port.
///
/// The signature is the one phase 2 agreed on: the host passes the open source, the channel check
/// boxes, the Zoom/Selection mode and a binding for the selected slice, and everything else lives
/// in here.
struct DataViewerView: View {

    let source: DataViewerSource?
    let channels: Set<DataChannel>
    let mode: DataViewerMode
    @Binding var selection: ClosedRange<Date>?

    @StateObject private var model = DataViewerModel()

    init(source: DataViewerSource?,
         channels: Set<DataChannel>,
         mode: DataViewerMode,
         selection: Binding<ClosedRange<Date>?>) {
        self.source = source
        self.channels = channels
        self.mode = mode
        self._selection = selection
    }

    var body: some View {
        DataPlot(model: model,
                 channels: channels,
                 mode: mode,
                 device: source?.device,
                 selection: $selection)
            .accessibilityIdentifier("DataViewer")
            .onAppear { sync() }
            .onChange(of: source?.id) { _, _ in sync() }
    }

    /// `dataViewer.Open(...)` / `Close()`.
    private func sync() {
        DataViewerRegistry.shared.model = model
        guard let source else {
            model.close()
            return
        }
        model.open(path: source.path)
    }
}

/// Hosts the AppKit plot. `@ObservedObject` is what drives the redraw: the model bumps `revision`
/// every time a batch of blocks lands, so the picture fills in while the file is still loading.
private struct DataPlot: NSViewRepresentable {

    @ObservedObject var model: DataViewerModel
    let channels: Set<DataChannel>
    let mode: DataViewerMode
    let device: OmDevice?
    @Binding var selection: ClosedRange<Date>?

    func makeNSView(context: Context) -> DataPlotView {
        let view = DataPlotView(frame: .zero)
        DataViewerRegistry.shared.plot = view
        return view
    }

    func updateNSView(_ view: DataPlotView, context: Context) {
        view.model = model
        view.channels = channels
        view.mode = mode
        view.device = device
        view.onSelectionChanged = { range in
            // A user gesture, not a view update: safe to write straight back to the binding.
            selection = range
        }
        view.modelChanged()
    }
}

/// The running plot and its model, so `--self-test` can drive the real view rather than a copy of
/// its logic. Nothing else reads this.
@MainActor
final class DataViewerRegistry {
    static let shared = DataViewerRegistry()
    weak var plot: DataPlotView?
    weak var model: DataViewerModel?
}
