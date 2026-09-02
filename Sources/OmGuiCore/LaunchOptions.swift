import Foundation
import OmApi

/// The command line OMGUI accepts (`Program.cs`), plus `--mock` for the in-process fake devices.
///
/// Both the Windows `-flag` and a `--flag` spelling are accepted so the app is usable from a
/// macOS shell without quoting surprises.
public struct LaunchOptions: Sendable {

    /// `--mock` / `OMGUI_MOCK=1` — drive `MockBackend` instead of libomapi.
    public var useMock = false
    /// `--mock-root <dir>` / `OMGUI_MOCK_ROOT`.
    public var mockRoot: String?
    /// `-folder <path>` — start in this working folder.
    public var startupFolder: String?
    /// `-downloadlog <path>`.
    public var downloadLog: String?
    /// `-configlog <path>` / `-dump <path>`.
    public var configLog: String?
    /// `-log <path>` — mirror the log pane to a file.
    public var logFile: String?
    /// `-noreset` sets this to 0; OMGUI's default is 3.
    public var resetIfUnresponsive = 3
    /// `-notimecheck` disables the `DISCHARGED?`/`DAMAGED?` battery-column prefixes.
    public var timeCheck = true
    /// `--self-test <dir>` — drive the flows headlessly against the mock and write screenshots.
    public var selfTestDirectory: String?
    /// Unrecognised arguments, reported to the log exactly as OMGUI does.
    public var warnings: [String] = []

    public init() {}

    public init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init()

        let flag = (environment[OmApi.mockEnvironmentKey] ?? "").lowercased()
        if flag == "1" || flag == "true" || flag == "yes" { useMock = true }
        mockRoot = environment[OmApi.mockRootEnvironmentKey]

        var index = 0
        // arguments[0] is the executable path.
        var rest = Array(arguments.dropFirst())
        // Xcode/`swift run` sometimes inject `-NSDocumentRevisionsDebugMode YES`; ignore those.
        rest.removeAll { $0.hasPrefix("-NS") }

        func next() -> String? {
            guard index + 1 < rest.count else { return nil }
            index += 1
            return rest[index]
        }

        while index < rest.count {
            let raw = rest[index]
            let name = raw.hasPrefix("--") ? String(raw.dropFirst(2)) : (raw.hasPrefix("-") ? String(raw.dropFirst()) : raw)
            switch name.lowercased() {
            case "mock": useMock = true
            case "mock-root", "mockroot": mockRoot = next()
            case "folder": startupFolder = next()
            case "downloadlog", "download-log": downloadLog = next()
            case "configlog", "config-log", "dump": configLog = next()
            case "log": logFile = next()
            case "noreset": resetIfUnresponsive = 0
            case "timecheck": timeCheck = true
            case "notimecheck": timeCheck = false
            case "self-test", "selftest": selfTestDirectory = next()
            default:
                if raw.hasPrefix("-") || raw.hasPrefix("/") {
                    warnings.append("ERROR: Ignoring unknown option: \(raw)")
                } else {
                    warnings.append("ERROR: Ignoring positional parameter: \(raw)")
                }
            }
            index += 1
        }
    }

    /// The backend this launch asks for.
    public func makeBackend() -> DeviceBackend {
        var environment: [String: String] = [:]
        if useMock { environment[OmApi.mockEnvironmentKey] = "1" }
        if let mockRoot { environment[OmApi.mockRootEnvironmentKey] = mockRoot }
        return OmApi.defaultBackend(environment: environment)
    }
}
