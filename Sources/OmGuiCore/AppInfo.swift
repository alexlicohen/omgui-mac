import Foundation

/// `MainForm.defaultTitleText` and the version it is built from.
///
/// Upstream is
/// `"Open Movement " + " [V" + Assembly.GetName().Version + "]"` (`MainForm.cs:2318`) and the
/// window text is `defaultTitleText + " - " + Settings.Default.CurrentWorkingFolder`
/// (`MainForm.cs:2422`). The port keeps the structure and drops upstream's accidental double
/// space, which is how the MOP's v1.0.0.45 screenshot reads.
public enum AppInfo {

    /// The version used when the executable is not inside an app bundle (a `swift build` run, the
    /// tests, `--self-test`), or when the bundle carries a non-numeric marketing version.
    ///
    /// `scripts/build-app.sh` stamps `CFBundleShortVersionString` from `git describe`, which on an
    /// untagged checkout is a commit hash — not something a site should read as a version — so the
    /// title falls back to this. Tag the release (`git tag v1.0.0`) and the tag is used instead.
    public static let packageVersion = "1.0.0"

    /// True for `1`, `1.0`, `1.0.0.45` … — the shapes a marketing version may take.
    public static func isNumericVersion(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// `CFBundleShortVersionString` when it is a real version, else `packageVersion`.
    public static func version(bundle: Bundle = .main) -> String {
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return isNumericVersion(short) ? short : packageVersion
    }

    /// `defaultTitleText` — "Open Movement [V1.0.0]".
    public static func defaultTitleText(version: String) -> String {
        "Open Movement [V\(version)]"
    }

    public static func defaultTitleText(bundle: Bundle = .main) -> String {
        defaultTitleText(version: version(bundle: bundle))
    }

    /// The whole window title: `defaultTitleText + " - " + <workspace>`.
    ///
    /// Upstream prints `Settings.Default.CurrentWorkingFolder`; the port prints the *expanded*
    /// folder, because the stored value here is normally the `{MyDocuments}` template and the MOP
    /// screenshot shows a real path.
    public static func windowTitle(workspace: URL, version: String) -> String {
        defaultTitleText(version: version) + " - " + workspace.path
    }

    public static func windowTitle(workspace: URL, bundle: Bundle = .main) -> String {
        windowTitle(workspace: workspace, version: version(bundle: bundle))
    }
}
