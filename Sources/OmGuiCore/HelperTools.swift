import Foundation

/// The command-line helpers OMGUI shells out to.
///
/// Windows OMGUI resolves these relative to `Application.StartupPath`
/// (`Plugins\OmConvertPlugin\omconvert.exe`, `Plugins\Convert_CWA\cwa-convert.exe`). The Mac port
/// ships them in the app bundle instead, because a `.app` cannot execute a binary that lives in
/// `Resources` under a hardened runtime — see `refs/07-phase3b-notes.md`.
public enum HelperTool: String, Sendable, CaseIterable {
    case omconvert = "omconvert"
    case cwaConvert = "cwa-convert"

    public var executableName: String { rawValue }

    /// The path `ProcessingForm`/`ExportForm` print when the executable is missing, so the error
    /// text stays recognisable to someone who knows OMGUI.
    public var windowsRelativePath: String {
        switch self {
        case .omconvert: return #"Plugins\OmConvertPlugin\omconvert.exe"#
        case .cwaConvert: return #"Plugins\Convert_CWA\cwa-convert.exe"#
        }
    }
}

public struct HelperToolMissing: Error, CustomStringConvertible, Sendable {
    public let tool: HelperTool
    public let searched: [String]

    public init(tool: HelperTool, searched: [String]) {
        self.tool = tool
        self.searched = searched
    }

    /// `ProcessingForm.Execute`'s message, with the list of places actually searched.
    public var description: String {
        "This process requires the external executable \(tool.executableName).\n\n"
            + "The file was not found in:\n\n"
            + searched.joined(separator: "\n")
            + "\n\nRun scripts/build-helpers.sh, or reinstall the application."
    }
}

/// Finds `omconvert` / `cwa-convert`.
///
/// Order: `$OMGUI_HELPER_DIR`, the bundle's `Contents/Helpers`, `build/helpers` in any ancestor of
/// the running executable or the working directory (the development layout), then `PATH`.
public enum HelperTools {

    /// Where `scripts/build-app.sh` puts them inside `OmGui.app`.
    public static let bundleSubdirectory = "Contents/Helpers"
    /// Where `scripts/build-helpers.sh` puts them in a checkout.
    public static let developmentSubdirectory = "build/helpers"
    /// Overrides everything; used by the tests and by `--self-test`.
    public static let environmentOverride = "OMGUI_HELPER_DIR"

    /// Every directory that is looked in, most specific first.
    public static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL,
        bundle: URL? = Bundle.main.bundleURL,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [URL] {
        var directories: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL?) {
            guard let url else { return }
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { directories.append(URL(fileURLWithPath: path, isDirectory: true)) }
        }

        if let override = environment[environmentOverride], !override.isEmpty {
            add(URL(fileURLWithPath: override, isDirectory: true))
        }

        // Inside the .app: <OmGui.app>/Contents/Helpers, whether Bundle.main reports the bundle
        // or (for a bare SwiftPM build) the executable's own directory.
        if let bundle {
            add(bundle.appendingPathComponent(bundleSubdirectory, isDirectory: true))
        }
        if let executable {
            let macOS = executable.deletingLastPathComponent()          // Contents/MacOS
            add(macOS.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true))
            add(macOS)
        }

        // Development: walk up from the executable and from the working directory looking for
        // build/helpers. `.build/release/OmGui` and the test bundle both sit under the package root.
        for start in [executable?.deletingLastPathComponent(),
                      URL(fileURLWithPath: workingDirectory, isDirectory: true)] {
            guard var directory = start?.standardizedFileURL else { continue }
            for _ in 0..<8 {
                add(directory.appendingPathComponent(developmentSubdirectory, isDirectory: true))
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        for element in (environment["PATH"] ?? "").split(separator: ":") where !element.isEmpty {
            add(URL(fileURLWithPath: String(element), isDirectory: true))
        }

        return directories
    }

    /// The executable, or `HelperToolMissing` naming everywhere that was tried.
    public static func url(for tool: HelperTool,
                           in directories: [URL]? = nil) throws -> URL {
        let candidates = directories ?? searchDirectories()
        for directory in candidates {
            let candidate = directory.appendingPathComponent(tool.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw HelperToolMissing(tool: tool, searched: candidates.map(\.path))
    }
}
