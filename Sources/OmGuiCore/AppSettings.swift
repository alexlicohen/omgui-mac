import Foundation
import OmApi

/// Expansion of the `{MyDocuments}`-style working-folder templates OMGUI stores in
/// `Settings.CurrentWorkingFolder` (`MainForm.GetPath`).
///
/// The .NET `SpecialFolder` names have no exact macOS equivalents, so each is mapped to the
/// closest native location (see `refs/05-phase2-notes.md`). `GetPath` also guarantees a trailing
/// separator; we return a directory `URL` instead.
public enum WorkspacePath {

    public static let templates = ["{MyDocuments}", "{Desktop}", "{LocalApplicationData}",
                                   "{ApplicationData}", "{CommonApplicationData}"]

    static func directory(_ search: FileManager.SearchPathDirectory,
                          _ domain: FileManager.SearchPathDomainMask = .userDomainMask) -> String {
        let urls = FileManager.default.urls(for: search, in: domain)
        return urls.first?.path ?? NSHomeDirectory()
    }

    /// The substitutions, in the order `MainForm.GetPath` applies them.
    public static func substitutions() -> [(String, String)] {
        [
            ("{MyDocuments}", directory(.documentDirectory)),
            ("{Desktop}", directory(.desktopDirectory)),
            ("{LocalApplicationData}", directory(.applicationSupportDirectory)),
            ("{ApplicationData}", directory(.applicationSupportDirectory)),
            ("{CommonApplicationData}", directory(.applicationSupportDirectory, .localDomainMask)),
        ]
    }

    /// `MainForm.GetPath` — expand the placeholders and return a directory path.
    public static func expand(_ template: String) -> String {
        var path = template
        for (key, value) in substitutions() {
            path = path.replacingOccurrences(of: key, with: value)
        }
        if path.isEmpty { path = directory(.documentDirectory) }
        // Windows appends a trailing "\\"; a URL carries the directory-ness instead.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public static func url(_ template: String) -> URL {
        URL(fileURLWithPath: expand(template), isDirectory: true)
    }
}

/// Everything OMGUI keeps in `Properties.Settings.Default`, plus the macOS view-state toggles,
/// backed by `UserDefaults` so tests can hand in an isolated suite.
public final class AppSettings: @unchecked Sendable {

    public enum Key {
        public static let filenameTemplate = "FilenameTemplate"
        public static let currentPluginFolder = "CurrentPluginFolder"
        public static let currentWorkingFolder = "CurrentWorkingFolder"
        public static let recentFolders = "RecentFolders"
        public static let cutPointSettings = "CutPointSettings"
        public static let downloadLogFile = "DownloadLogFile"
        public static let configLogFile = "ConfigLogFile"
        public static let showAllFiles = "ShowAllFiles"
        public static let viewToolbar = "ViewToolbar"
        public static let viewStatusBar = "ViewStatusBar"
        public static let viewPreview = "ViewPreview"
        public static let viewDeviceProperties = "ViewDeviceProperties"
        public static let viewFileProperties = "ViewFileProperties"
        public static let viewLog = "ViewLog"
    }

    /// OMGUI keeps five entries in its recent-folder list (`MainForm.SetWorkingFolder`).
    public static let recentFolderLimit = 5

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.filenameTemplate: FilenameTemplate.defaultTemplate,
            Key.currentPluginFolder: "",
            Key.cutPointSettings: "",
            Key.currentWorkingFolder: "{MyDocuments}",
            Key.showAllFiles: false,
            Key.viewToolbar: true,
            Key.viewStatusBar: true,
            Key.viewPreview: true,
            Key.viewDeviceProperties: true,
            Key.viewFileProperties: true,
            Key.viewLog: false,
        ])
    }

    private func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    private func set(_ value: String, _ key: String) { defaults.set(value, forKey: key) }

    public var filenameTemplate: String {
        get { string(Key.filenameTemplate) }
        set { set(newValue, Key.filenameTemplate) }
    }

    public var pluginFolder: String {
        get { string(Key.currentPluginFolder) }
        set { set(newValue, Key.currentPluginFolder) }
    }

    /// `Properties.Settings.Default.CutPointSettings` — the Cut Points dialog remembers its
    /// epoch/model/filter between runs.
    public var cutPointSettings: String {
        get { string(Key.cutPointSettings) }
        set { set(newValue, Key.cutPointSettings) }
    }

    /// The stored template (may still contain `{MyDocuments}` and friends).
    public var workingFolderTemplate: String {
        get { string(Key.currentWorkingFolder) }
        set { set(newValue, Key.currentWorkingFolder) }
    }

    /// The expanded working folder.
    public var workingFolder: URL { WorkspacePath.url(workingFolderTemplate) }

    public var recentFolders: [String] {
        get { defaults.stringArray(forKey: Key.recentFolders) ?? [] }
        set { defaults.set(Array(newValue.prefix(AppSettings.recentFolderLimit)), forKey: Key.recentFolders) }
    }

    /// `-downloadlog <path>`: append `yyyy-MM-dd HH:mm:ss,DOWNLOAD-OK,<name>` after each download.
    public var downloadLogFile: String? {
        get { let v = string(Key.downloadLogFile); return v.isEmpty ? nil : v }
        set { set(newValue ?? "", Key.downloadLogFile) }
    }

    /// `-configlog <path>` / `-dump <path>`: the `AX3-CONFIG-OK` record log.
    public var configLogFile: String? {
        get { let v = string(Key.configLogFile); return v.isEmpty ? nil : v }
        set { set(newValue ?? "", Key.configLogFile) }
    }

    public var showAllFiles: Bool {
        get { defaults.bool(forKey: Key.showAllFiles) }
        set { defaults.set(newValue, forKey: Key.showAllFiles) }
    }

    public func viewFlag(_ key: String) -> Bool { defaults.bool(forKey: key) }
    public func setViewFlag(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }

    /// `MainForm.SetWorkingFolder` — most-recent first, no duplicates, capped at five.
    @discardableResult
    public func setWorkingFolder(_ path: String) -> [String] {
        workingFolderTemplate = path
        var recent = recentFolders
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > AppSettings.recentFolderLimit {
            recent = Array(recent.prefix(AppSettings.recentFolderLimit))
        }
        recentFolders = recent
        return recent
    }

    /// Reset to the registered defaults (used by tests).
    public func removeAll() {
        for key in [Key.filenameTemplate, Key.currentPluginFolder, Key.cutPointSettings,
                    Key.currentWorkingFolder,
                    Key.recentFolders, Key.downloadLogFile, Key.configLogFile, Key.showAllFiles,
                    Key.viewToolbar, Key.viewStatusBar, Key.viewPreview,
                    Key.viewDeviceProperties, Key.viewFileProperties, Key.viewLog] {
            defaults.removeObject(forKey: key)
        }
    }
}
