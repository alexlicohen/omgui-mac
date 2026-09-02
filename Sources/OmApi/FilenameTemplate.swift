import Foundation

/// Port of OMGUI's download-filename expansion (`MainForm.toolStripButtonDownload_Click`).
public enum FilenameTemplate {

    /// `Settings.Default.FilenameTemplate` default.
    public static let defaultTemplate = "{DeviceId}_{SessionId}"

    /// The named metadata placeholders OMGUI substitutes before any custom keys.
    public static let builtInKeys = [
        "StudyCentre", "StudyCode", "StudyInvestigator", "StudyExerciseType", "StudyOperator",
        "StudyNotes", "SubjectSite", "SubjectCode", "SubjectSex", "SubjectHeight",
        "SubjectWeight", "SubjectHandedness", "SubjectNotes",
    ]

    /// The hint shown in OMGUI's Options dialog.
    public static let placeholderHint = "Placeholders: {DeviceId}, {SessionId}, {StudyCode}, {SubjectCode}"

    /// `{DeviceId}` — `String.Format("{0:00000}", deviceId)`.
    public static func deviceIdString(_ deviceId: UInt32) -> String {
        String(format: "%05u", deviceId)
    }

    /// `{SessionId}` — `String.Format("{0:0000000000}", sessionId)`.
    public static func sessionIdString(_ sessionId: UInt32) -> String {
        String(format: "%010u", sessionId)
    }

    /// Whitelist sanitise: anything outside `[0-9A-Za-z_-]` becomes `_`; an empty result is `-`.
    public static func sanitise(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            switch scalar {
            case "0"..."9", "A"..."Z", "a"..."z", "-", "_":
                out.unicodeScalars.append(scalar)
            default:
                out.append("_")
            }
        }
        return out.isEmpty ? "-" : out
    }

    /// Expand a template to a *base name* (no directory, no `.cwa` extension).
    ///
    /// - Parameters:
    ///   - deviceId: the device's own identifier.
    ///   - sessionId: the device's session id. `UInt32.max` means "unknown", in which case OMGUI
    ///     falls back to the session id read from the data file, or `"0000000000"`.
    ///   - fileSessionId: pre-formatted session id from the file header, if known.
    ///   - metadata: display-named metadata (`MetadataTools.namedMap`), plus any of
    ///     `DeviceId`/`SessionId`/`SamplingRate`/`SamplingRange`/`StartTime`/`StartTimeNumeric`/
    ///     `EndTime`/`EndTimeNumeric` the caller has.
    public static func expand(_ template: String,
                              deviceId: UInt32,
                              sessionId: UInt32,
                              fileSessionId: String? = nil,
                              metadata: [String: String] = [:]) -> String {
        var name = template.isEmpty ? defaultTemplate : template

        let usedDeviceId = deviceIdString(deviceId)
        let usedSessionId = sessionId == UInt32.max
            ? (fileSessionId ?? "0000000000")
            : sessionIdString(sessionId)

        name = name.replacingOccurrences(of: "{DeviceId}", with: usedDeviceId)
        name = name.replacingOccurrences(of: "{SessionId}", with: usedSessionId)

        for key in builtInKeys {
            name = name.replacingOccurrences(of: "{\(key)}", with: metadata[key] ?? "")
        }
        // Custom keys (sorted so expansion is deterministic; upstream iterates a Dictionary).
        for key in metadata.keys.sorted() where !builtInKeys.contains(key) {
            name = name.replacingOccurrences(of: "{\(key)}", with: metadata[key] ?? "")
        }

        return sanitise(name)
    }

    /// The two paths OMGUI uses: it downloads to `<base>.cwa.part`, then renames to `<base>.cwa`.
    public static func downloadPaths(workspace: URL, baseName: String) -> (partial: URL, final: URL) {
        let final = workspace.appendingPathComponent(baseName + ".cwa")
        let partial = workspace.appendingPathComponent(baseName + ".cwa.part")
        return (partial, final)
    }
}
