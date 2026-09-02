import Foundation
import OmApi

/// OMGUI's per-workspace record profile (`<workspace>/recordSetup.xml`).
///
/// Same file name, same root element and same child element names as `DateRangeForm`'s
/// `saveDictionaryToXML`, so a workspace stays readable by the Windows build.
public struct RecordingProfile: Sendable, Equatable {

    public static let fileName = "recordSetup.xml"
    public static let rootElement = "RecordProfile"

    /// `key` → `value`, in `saveDictionaryFromFields` order.
    public var values: [(key: String, value: String)] = []

    public init() {}

    public subscript(key: String) -> String? {
        get { values.first { $0.key == key }?.value }
        set {
            guard let newValue else {
                values.removeAll { $0.key == key }
                return
            }
            if let index = values.firstIndex(where: { $0.key == key }) { values[index].value = newValue }
            else { values.append((key, newValue)) }
        }
    }

    public static func == (lhs: RecordingProfile, rhs: RecordingProfile) -> Bool {
        lhs.values.map(\.key) == rhs.values.map(\.key) && lhs.values.map(\.value) == rhs.values.map(\.value)
    }

    // MARK: - Capture / restore

    /// `saveDictionaryFromFields`.
    public init(capturing settings: RecordingSettings, calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current
        let timeOfDay = settings.startDate.timeIntervalSince(cal.startOfDay(for: settings.startDate))

        values = [
            ("StudyCentre", settings.metadata.studyCentre),
            ("StudyCode", settings.metadata.studyCode),
            ("StudyInvestigator", settings.metadata.studyInvestigator),
            ("StudyExerciseType", settings.metadata.studyExerciseType),
            ("StudyOperator", settings.metadata.studyOperator),
            ("StudyNotes", settings.metadata.studyNotes),
            ("SubjectCode", settings.metadata.subjectCode),
            ("SubjectSex", settings.metadata.subjectSex),
            ("SubjectHeight", settings.metadata.subjectHeight),
            ("SubjectWeight", settings.metadata.subjectWeight),
            ("SubjectHandedness", settings.metadata.subjectHandedness),
            ("SubjectSite", settings.metadata.subjectSite),
            ("SubjectNotes", settings.metadata.subjectNotes),
            ("Frequency", RecordingSettings.frequencyLabels[settings.frequencyIndex]),
            ("LowPower", settings.lowPower ? "True" : "False"),
            ("Unpacked", settings.unpacked ? "True" : "False"),
            ("Range", RecordingSettings.rangeLabels[settings.rangeIndex]),
            ("GyroRange", String(settings.gyroRange.rawValue)),
            ("DelayDays", String(settings.delayDays)),
            ("TimeOfDay", RecordingProfile.numberText(timeOfDay)),
            ("Duration", RecordingProfile.numberText(settings.duration)),
            ("RecordingTime", settings.immediately ? "Immediately" : "Duration"),
            ("Flash", settings.flash ? "True" : "False"),
        ]
    }

    /// `resetFieldsToDictionary`.
    ///
    /// Upstream deliberately leaves the Subject fields out of the restore (they are per-participant
    /// and commented out in `DateRangeForm.cs`) even though it saves them; that is reproduced here.
    public func apply(to settings: inout RecordingSettings,
                      now: Date = Date(),
                      calendar: Calendar = .autoupdatingCurrent) {
        var cal = calendar
        cal.timeZone = TimeZone.current

        for (key, value) in values {
            switch key {
            case "StudyCentre": settings.metadata.studyCentre = value
            case "StudyCode": settings.metadata.studyCode = value
            case "StudyInvestigator": settings.metadata.studyInvestigator = value
            case "StudyExerciseType": settings.metadata.studyExerciseType = value
            case "StudyOperator": settings.metadata.studyOperator = value
            case "StudyNotes": settings.metadata.studyNotes = value
            case "LowPower":
                // AX6 has no low-power option, so upstream ignores a stored value there.
                if !settings.hasSyncGyro { settings.lowPower = (value == "True") }
            case "Unpacked":
                if !settings.hasSyncGyro { settings.unpacked = (value == "True") }
            case "Frequency":
                if let index = RecordingSettings.frequencyLabels.firstIndex(of: value) {
                    settings.frequencyIndex = index
                }
            case "Range":
                if let index = RecordingSettings.rangeLabels.firstIndex(of: value) {
                    settings.rangeIndex = index
                }
            case "GyroRange":
                let number = Int(value) ?? 0
                if number == 0 { settings.gyroIndex = 0 }
                else if let index = RecordingSettings.gyroRanges.firstIndex(where: { $0.rawValue == number }) {
                    settings.gyroIndex = index
                }
            case "DelayDays":
                settings.setDelayDays(Int(value) ?? 0, now: now, calendar: cal)
            case "TimeOfDay":
                let seconds = Double(value) ?? 0
                settings.startDate = cal.startOfDay(for: settings.startDate).addingTimeInterval(seconds)
            case "Duration":
                settings.setDuration(Double(value) ?? 0)
            case "RecordingTime":
                if value == "Immediately" { settings.immediately = true }
                else if value == "Duration" { settings.immediately = false }
            case "Flash":
                settings.flash = (value == "True")
            default:
                break
            }
        }
    }

    // MARK: - XML

    /// `double.ToString()` on an invariant-ish culture: no exponent, no trailing ".0".
    static func numberText(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public var xml: String {
        var out = "<\(RecordingProfile.rootElement)>"
        for (key, value) in values {
            out += "<\(key)>\(RecordingProfile.escape(value))</\(key)>"
        }
        out += "</\(RecordingProfile.rootElement)>"
        return out
    }

    public init?(xml: String) {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = ProfileParser()
        guard let values = parser.parse(data) else { return nil }
        self.values = values
    }

    // MARK: - Files

    public static func url(in workspace: URL) -> URL {
        workspace.appendingPathComponent(fileName)
    }

    public static func load(from workspace: URL) -> RecordingProfile? {
        guard let text = try? String(contentsOf: url(in: workspace), encoding: .utf8) else { return nil }
        return RecordingProfile(xml: text)
    }

    @discardableResult
    public func save(to workspace: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try xml.write(to: RecordingProfile.url(in: workspace), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

/// Minimal `<RecordProfile><Key>value</Key>…</RecordProfile>` reader.
private final class ProfileParser: NSObject, XMLParserDelegate {
    private var values: [(key: String, value: String)] = []
    private var currentKey: String?
    private var currentText = ""
    private var depth = 0
    private var failed = false

    func parse(_ data: Data) -> [(key: String, value: String)]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !failed else { return nil }
        return values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth == 2 {
            currentKey = elementName
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth == 2 { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if depth == 2, let key = currentKey {
            values.append((key, currentText))
            currentKey = nil
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }
}
