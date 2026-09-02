import AppKit
import OmGuiCore
import SwiftUI

/// A WinForms `ComboBox` with the default `DropDown` style: the text is free, the list is a
/// shortcut. `ExportWavForm.comboBoxRate`, every `Epoch` box and `ExportPaeeForm.comboBox1` are
/// these, which is why upstream reads them with `int.TryParse(box.Text)`.
struct EditableCombo: View {
    @Binding var text: String
    let items: [String]
    var width: CGFloat = 90

    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $text)
                .textFieldStyle(.squareBorder)
                .frame(width: width)
            Menu("") {
                ForEach(items, id: \.self) { item in
                    Button(item) { text = item }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
        }
        .controlSize(.small)
    }
}

/// A `DropDownList` combo — `ExportSvmForm.comboBoxMode` / `comboBoxFilter`, whose value upstream
/// reads as `SelectedIndex`.
struct ListCombo: View {
    @Binding var index: Int
    let items: [String]
    var width: CGFloat = 220

    var body: some View {
        Picker("", selection: $index) {
            ForEach(items.indices, id: \.self) { position in
                Text(items[position]).tag(position)
            }
        }
        .labelsHidden()
        .frame(width: width)
        .controlSize(.small)
    }
}

/// `groupBox1` — "Options".
struct OptionsGroup<Content: View>: View {
    var title = "Options"
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }
}

/// Every `Export*Form`, in one sheet keyed by `ExportSheetContext.Kind`.
struct ExportSheet: View {

    @ObservedObject var context: ExportSheetContext
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            DialogTitleBar(title: context.kind.title)
            VStack(alignment: .leading, spacing: 12) {
                body(for: context.kind)
                if context.files.count > 1 {
                    Text("\(context.files.count) files selected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button(context.kind.acceptTitle) {
                        context.onRun?(context)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: context.kind == .rawCsv ? 560 : 420)
    }

    private func close() {
        let onClose = context.onClose
        dismiss()
        model.exportSheet = nil
        onClose?()
    }

    @ViewBuilder
    private func body(for kind: ExportSheetContext.Kind) -> some View {
        switch kind {
        case .wav: wavBody
        case .resampledCsv: resampledCsvBody
        case .svm: svmBody
        case .cutPoints: cutPointsBody
        case .wearTime: wearTimeBody
        case .sleep: sleepBody
        case .rawCsv: rawCsvBody
        }
    }

    // MARK: `ExportWavForm`

    private var wavBody: some View {
        OptionsGroup {
            HStack(spacing: 6) {
                Text("Resampling:")
                EditableCombo(text: $context.wav.rateText, items: WavExportOptions.rates)
                Text("Hz")
            }
            Toggle("Auto Calibrate", isOn: $context.wav.autoCalibrate)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: `ExportCsvForm`

    private var resampledCsvBody: some View {
        Text("Export accelerometer data to a comma-separated value file.")
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: `ExportSvmForm`

    private var svmBody: some View {
        OptionsGroup {
            HStack(spacing: 6) {
                Text("Epoch:")
                EditableCombo(text: $context.svm.epochText, items: SvmExportOptions.epochs)
                Text("s")
            }
            HStack(spacing: 6) {
                Text("Filter:")
                ListCombo(index: $context.svm.filter, items: SvmExportOptions.filters, width: 180)
            }
            HStack(spacing: 6) {
                Text("Mode:")
                ListCombo(index: $context.svm.mode, items: SvmExportOptions.modes, width: 220)
            }
        }
    }

    // MARK: `ExportPaeeForm`

    private var cutPointsBody: some View {
        OptionsGroup {
            HStack(spacing: 6) {
                Text("Epoch:")
                EditableCombo(text: $context.cutPoints.epochText, items: CutPointsOptions.epochs)
                Text("* 60 s")
            }
            HStack(spacing: 6) {
                Text("Model:")
                EditableCombo(text: $context.cutPoints.model, items: CutPointsOptions.models, width: 330)
            }
            HStack(spacing: 6) {
                Text("Filter:")
                ListCombo(index: $context.cutPoints.filter, items: CutPointsOptions.filters, width: 330)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    // MARK: `ExportWtvForm`

    private var wearTimeBody: some View {
        OptionsGroup {
            HStack(spacing: 6) {
                Text("Epoch:")
                EditableCombo(text: $context.wearTime.epochText, items: WearTimeOptions.epochs)
                Text("* 1800 s")
            }
        }
    }

    // MARK: `ExportSleepForm`

    private var sleepBody: some View {
        OptionsGroup {
            Text("'ESS' Sleep Analysis")
        }
    }

    // MARK: `ExportForm`

    private var rawCsvBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Source File:").frame(width: 78, alignment: .leading)
                TextField("", text: .constant(context.rawCsv.sourceFile))
                    .disabled(true)
            }
            HStack(spacing: 6) {
                Text("Output File:").frame(width: 78, alignment: .leading)
                TextField("", text: $context.rawCsv.outputFile)
                Button("Browse...") { browse() }
            }
            HStack(alignment: .top, spacing: 12) {
                OptionsGroup(title: "Stream") {
                    Picker("", selection: $context.rawCsv.stream) {
                        ForEach(RawCsvOptions.Stream.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                OptionsGroup(title: "Accelerometer Units") {
                    Picker("", selection: $context.rawCsv.values) {
                        ForEach(RawCsvOptions.Values.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            OptionsGroup(title: "Timestamp Estimation") {
                Picker("", selection: $context.rawCsv.timestamp) {
                    ForEach(RawCsvOptions.Timestamp.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            OptionsGroup(title: "Sub-Sample (skip)") {
                HStack(spacing: 6) {
                    Text("First:")
                    TextField("", text: $context.rawCsv.sampleStart).frame(width: 70)
                    Text("Count:")
                    TextField("", text: $context.rawCsv.sampleLength).frame(width: 70)
                    Text("Interval:")
                    TextField("", text: $context.rawCsv.sampleStep).frame(width: 70)
                }
            }
            if !context.rawCsv.blockDescription.isEmpty || !context.rawCsv.blockStart.isEmpty {
                OptionsGroup(title: "Selected Time Slice") {
                    HStack(spacing: 6) {
                        Text("Start:")
                        TextField("", text: $context.rawCsv.blockStart).frame(width: 80)
                        Text("Count:")
                        TextField("", text: $context.rawCsv.blockCount).frame(width: 80)
                    }
                    if !context.rawCsv.blockDescription.isEmpty {
                        Text(context.rawCsv.blockDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .textFieldStyle(.squareBorder)
        .controlSize(.small)
    }

    /// `ExportForm.Browse` — the `saveFileDialog` with `DefaultExt = "csv"`.
    private func browse() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = DotNetPath.fileName(context.rawCsv.outputFile)
        panel.directoryURL = URL(fileURLWithPath: context.rawCsv.outputFile).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            context.rawCsv.outputFile = url.path
        }
    }
}
