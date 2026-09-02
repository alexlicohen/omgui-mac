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
    /// `--self-test [dir]` — drive the flows headlessly against the mock and write screenshots.
    public var selfTestDirectory: String?
    /// True when `--self-test` was given without a directory, so the run defaulted everything: the
    /// screenshots go to a temporary folder and so does the working folder, which keeps a bare
    /// `OmGui --mock --self-test` from writing test data into whatever workspace was last used.
    public var selfTestUsedDefaults = false
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
            case "self-test", "selftest":
                // The directory is optional: a bare `--self-test` runs in a temporary folder.
                if index + 1 < rest.count, !rest[index + 1].hasPrefix("-") {
                    selfTestDirectory = next()
                } else {
                    selfTestDirectory = LaunchOptions.defaultSelfTestDirectory
                    selfTestUsedDefaults = true
                }
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

    /// Where a bare `--self-test` puts its screenshots and its working folder.
    public static let defaultSelfTestDirectory =
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("omgui-self-test", isDirectory: true).path

    /// Where a bare `--self-test` puts its mock devices.
    public static let defaultSelfTestMockRoot =
        URL(fileURLWithPath: defaultSelfTestDirectory, isDirectory: true)
            .appendingPathComponent("mock", isDirectory: true).path

    /// The backend this launch asks for.
    ///
    /// The mock is always built with `MockDeviceCatalog.specs` (the MOP's 7-digit device IDs), not
    /// with `MockBackend.Spec.defaults`, so `--mock` screenshots read like the MOP's.
    public func makeBackend() -> DeviceBackend {
        if useMock, selfTestUsedDefaults {
            // A bare `--self-test` gets a fresh set of mock devices every run: the state a previous
            // run persisted would leave them cleared, and the Download leg would find no data.
            return MockBackend(root: URL(fileURLWithPath: mockRoot ?? LaunchOptions.defaultSelfTestMockRoot,
                                         isDirectory: true),
                               specs: MockDeviceCatalog.specs,
                               resetVolumes: true,
                               persistState: false)
        }
        if useMock {
            let root = (mockRoot ?? ProcessInfo.processInfo.environment[OmApi.mockRootEnvironmentKey])
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            return MockBackend(root: root, specs: MockDeviceCatalog.specs)
        }
        var environment: [String: String] = [:]
        if let mockRoot { environment[OmApi.mockRootEnvironmentKey] = mockRoot }
        return OmApi.defaultBackend(environment: environment)
    }
}
