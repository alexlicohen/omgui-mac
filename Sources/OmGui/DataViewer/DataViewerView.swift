import Foundation
import OmApi
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

    /// The path a phase-3 plot would read.
    var path: String {
        switch self {
        case .file(let url): return url.path
        case .device(let device): return device.dataFilePath
        }
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

    /// The pen colours `DataViewer.cs` draws each channel with (alpha 0x60 in the plot itself).
    var penColor: Color {
        switch self {
        case .x: return .red
        case .y: return .green
        case .z: return .blue
        case .gyroX: return .cyan
        case .gyroY: return Color(red: 1, green: 0, blue: 1)
        case .gyroZ: return .yellow
        case .svm: return .black
        case .light: return Color(red: 0.65, green: 0.16, blue: 0.16)
        case .temperature: return Color(red: 0.55, green: 0, blue: 0.55)
        case .batteryPercent: return Color(red: 0, green: 0.55, blue: 0.55)
        case .batteryVolts: return Color(red: 0.88, green: 1, blue: 1)
        case .time: return .gray
        }
    }
}

/// `DataViewer.Mode`.
enum DataViewerMode: String, CaseIterable, Identifiable {
    case zoom = "Zoom"
    case selection = "Selection"
    var id: String { rawValue }
}

/// The preview pane.
///
/// Phase 2 owns the plumbing only: selecting a device or a file opens the source here exactly as
/// `dataViewer.Open` does, and the channel check boxes and Zoom/Selection buttons drive this view's
/// inputs. The plot itself is phase 3, so this renders the light-grey background OMGUI's viewer
/// uses plus the name of the open source.
struct DataViewerView: View {

    let source: DataViewerSource?
    let channels: Set<DataChannel>
    let mode: DataViewerMode
    @Binding var selection: ClosedRange<Date>?

    init(source: DataViewerSource?,
         channels: Set<DataChannel>,
         mode: DataViewerMode,
         selection: Binding<ClosedRange<Date>?>) {
        self.source = source
        self.channels = channels
        self.mode = mode
        self._selection = selection
    }

    /// `DataViewer` paints its background `Color.LightGray`.
    private static let background = Color(red: 0.827, green: 0.827, blue: 0.827)

    var body: some View {
        ZStack {
            Self.background
            if let source {
                VStack(spacing: 2) {
                    Text(source.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Text("Plot rendering arrives in phase 3 \u{2014} \(mode.rawValue) mode, \(channelSummary)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
        .accessibilityIdentifier("DataViewer")
    }

    private var channelSummary: String {
        let enabled = DataChannel.allCases.filter { channels.contains($0) }.map(\.title)
        return enabled.isEmpty ? "no channels" : enabled.joined(separator: " ")
    }
}
