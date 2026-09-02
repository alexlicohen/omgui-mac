import OmApi
import OmGuiCore
import SwiftUI

/// `DateRangeForm` — "Recording Settings" (ClientSize 485 x 617).
///
/// Field order, labels, defaults and enable/visible rules follow `DateRangeForm.Designer.cs`;
/// every value and warning comes from `RecordingSettings`.
struct RecordingSettingsView: View {

    @ObservedObject var context: RecordingSheetContext
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var settings: RecordingSettings { context.settings }

    private var validation: RecordingSettings.Validation { context.settings.validate() }

    var body: some View {
        VStack(spacing: 0) {
            // `DateRangeForm(title, devices)` is constructed with the title "Recording Settings".
            DialogTitleBar(title: "Recording Settings")
            form
        }
        .frame(width: RecordingSettingsView.dialogWidth)
    }

    /// `DateRangeForm.ClientSize` is 485 x 617; macOS controls need more room for the same fields.
    static let dialogWidth: CGFloat = 640

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            sessionRow
            samplingBox
            recordingTimeBox
            HStack(alignment: .top, spacing: 8) {
                studyBox
                subjectBox
            }
            Divider()
            bottomBar
        }
        .padding(12)
    }

    // MARK: - Session

    private var sessionRow: some View {
        HStack(spacing: 8) {
            Text("Recording Session ID")
            // `numericUpDownSessionID` is a whole number with no thousands separator: the site
            // types the participant number and reads it straight back.
            TextField("", value: Binding(get: { context.settings.sessionId },
                                         set: { context.settings.sessionId = min($0, RecordingSettings.sessionIdMaximum) }),
                      format: .number.grouping(.never))
                .frame(width: 120)
            Stepper("", value: Binding(get: { Int(context.settings.sessionId) },
                                       set: { context.settings.sessionId = UInt32(max(0, min($0, Int(RecordingSettings.sessionIdMaximum)))) }),
                    in: 0...Int(RecordingSettings.sessionIdMaximum))
                .labelsHidden()
            Spacer()
        }
    }

    // MARK: - Sampling

    private var samplingBox: some View {
        GroupBox("Sampling") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    // `labelRateRangeSetting`: blank at the standard 100 Hz / +-8 g setting.
                    Text(validation.rateRangeText)
                        .font(.system(size: 10))
                        .foregroundStyle(validation.invalid ? Color.red : Color.secondary)
                        .frame(height: 12)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("Freq. (Hz)").fixedSize()
                    Picker("", selection: $context.settings.frequencyIndex) {
                        ForEach(RecordingSettings.frequencyLabels.indices, id: \.self) { index in
                            Text(RecordingSettings.frequencyLabels[index]).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    Text("Range (\u{00B1}g)").fixedSize()
                    Picker("", selection: $context.settings.rangeIndex) {
                        ForEach(RecordingSettings.rangeLabels.indices, id: \.self) { index in
                            Text(RecordingSettings.rangeLabels[index]).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 64)

                    if settings.hasSyncGyro {
                        Text("Gyro (\u{00B1}dps)").fixedSize()
                        Picker("", selection: $context.settings.gyroIndex) {
                            ForEach(RecordingSettings.gyroLabels.indices, id: \.self) { index in
                                Text(RecordingSettings.gyroLabels[index]).tag(index)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 96)
                    }

                    Spacer()
                    Button("Defaults") { context.settings.applyDefaults() }.fixedSize()
                }
            }
            .padding(4)
        }
    }

    // MARK: - Recording time

    private var recordingTimeBox: some View {
        GroupBox("Recording Time") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: Binding(get: { context.settings.immediately },
                                              set: { context.settings.immediately = $0 })) {
                    Text("Immediately on Disconnect").tag(true)
                    Text("Interval").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                HStack(spacing: 6) {
                    Text("Start Date:")
                    DatePicker("", selection: startBinding, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Text("Start Time:")
                    DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Spacer()
                    Text("Delay:")
                    numberField(value: Binding(get: { context.settings.delayDays },
                                               set: { context.settings.setDelayDays($0) }),
                                range: RecordingSettings.delayDaysRange, width: 46)
                    Text("days")
                }
                .disabled(settings.immediately)

                HStack(spacing: 6) {
                    Text("Duration:")
                    numberField(value: durationBinding(\.durationDays),
                                range: RecordingSettings.durationDaysRange, width: 50)
                    Text("days")
                    numberField(value: durationBinding(\.durationHours),
                                range: RecordingSettings.durationHoursRange, width: 50)
                    Text("hours")
                    numberField(value: durationBinding(\.durationMinutes),
                                range: RecordingSettings.durationMinutesRange, width: 50)
                    Text("minutes")
                    Spacer()
                }
                .disabled(settings.immediately)

                HStack(spacing: 6) {
                    Text("End Date:")
                    DatePicker("", selection: endBinding, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Text("End Time:")
                    DatePicker("", selection: endBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Spacer()
                }
                .disabled(settings.immediately)
            }
            .padding(4)
        }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { context.settings.startDate },
                set: { context.settings.setStart($0) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { context.settings.endDate },
                set: { context.settings.setEnd($0) })
    }

    private func durationBinding(_ key: WritableKeyPath<RecordingSettings, Int>) -> Binding<Int> {
        Binding(get: { context.settings[keyPath: key] },
                set: { newValue in
                    var days = context.settings.durationDays
                    var hours = context.settings.durationHours
                    var minutes = context.settings.durationMinutes
                    switch key {
                    case \RecordingSettings.durationDays: days = newValue
                    case \RecordingSettings.durationHours: hours = newValue
                    default: minutes = newValue
                    }
                    context.settings.setDuration(days: days, hours: hours, minutes: minutes)
                })
    }

    private func numberField(value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            TextField("", value: value, format: .number)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    // MARK: - Study / Subject

    private var studyBox: some View {
        GroupBox("Study") {
            VStack(alignment: .leading, spacing: 4) {
                labelled("Study Centre", TextField("", text: $context.settings.metadata.studyCentre))
                labelled("Study Code", TextField("", text: $context.settings.metadata.studyCode))
                labelled("Study Investigator", TextField("", text: $context.settings.metadata.studyInvestigator))
                labelled("Exercise Type", TextField("", text: $context.settings.metadata.studyExerciseType))
                labelled("Operator", TextField("", text: $context.settings.metadata.studyOperator))
                labelled("Notes", TextField("", text: $context.settings.metadata.studyNotes))
            }
            .padding(4)
        }
    }

    private var subjectBox: some View {
        GroupBox("Subject") {
            VStack(alignment: .leading, spacing: 4) {
                labelled("Code", TextField("", text: $context.settings.metadata.subjectCode))
                labelled("Sex", combo($context.settings.metadata.subjectSex, MetadataTools.subjectSexes))
                labelled("Height", TextField("", text: $context.settings.metadata.subjectHeight))
                labelled("Weight", TextField("", text: $context.settings.metadata.subjectWeight))
                labelled("Handedness", combo($context.settings.metadata.subjectHandedness, MetadataTools.subjectHandednesses))
                labelled("Site", combo($context.settings.metadata.subjectSite, MetadataTools.subjectSites))
                labelled("Notes", TextField("", text: $context.settings.metadata.subjectNotes))
            }
            .padding(4)
        }
    }

    private func labelled(_ title: String, _ field: some View) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 110, alignment: .leading)
                .font(.system(size: 11))
            field.frame(width: 130)
        }
    }

    private func combo(_ binding: Binding<String>, _ values: [String]) -> some View {
        Picker("", selection: binding) {
            ForEach(values, id: \.self) { value in
                Text(value.isEmpty ? " " : value).tag(value)
            }
        }
        .labelsHidden()
    }

    // MARK: - Bottom bar

    /// `panelBottom` — `richTextBoxWarning` (292 x 94 at (6,5)) on the left and `panelButtons`
    /// (180 x 96 at (301,5): the check boxes, then OK and Cancel side by side at the bottom) on
    /// the right, exactly as `DateRangeForm.Designer.cs` docks them.
    private var bottomBar: some View {
        HStack(alignment: .top, spacing: 9) {
            warningsBox
            buttonsPanel
        }
        .frame(height: RecordingSettingsView.bottomPanelHeight)
    }

    /// `panelButtons.Size` / `richTextBoxWarning.Size`.
    static let bottomPanelHeight: CGFloat = 96
    static let buttonsPanelWidth: CGFloat = 180
    /// `SystemColors.Info` — the pale yellow WinForms paints a tooltip/notice box.
    static let warningBackground = Color(nsColor: NSColor(red: 1.0, green: 1.0, blue: 225.0 / 255.0, alpha: 1))
    /// `SystemColors.InfoText`.
    static let warningForeground = Color(nsColor: NSColor(red: 0, green: 0, blue: 0, alpha: 1))

    /// `richTextBoxWarning`: `Visible = false` while there is nothing to say, so the box does not
    /// draw -- but the space it occupies stays reserved, which is what docking it does upstream.
    @ViewBuilder private var warningsBox: some View {
        if let warning = validation.warningText {
            ScrollView {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(RecordingSettingsView.warningForeground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RecordingSettingsView.warningBackground)
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityIdentifier("recording.warnings")
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var buttonsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Flash during recording", isOn: $context.settings.flash)
            // `checkBoxLowPower` / `checkBoxUnpacked` are hidden on a gyro device
            // (`DateRangeForm.cs:103`/`:106`).
            if !settings.hasSyncGyro {
                Toggle("Lower Power (Noisier)", isOn: $context.settings.lowPower)
                Toggle("Unpacked data", isOn: $context.settings.unpacked)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button("OK") {
                    model.commitRecording(context.settings, devices: context.devices)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.okEnabled)
                .frame(width: 85)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 85)
            }
        }
        .toggleStyle(.checkbox)
        .frame(width: RecordingSettingsView.buttonsPanelWidth, alignment: .leading)
    }
}
