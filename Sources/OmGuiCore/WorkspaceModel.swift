import Foundation
import OmApi

/// One row of the Data Files / Output Files lists.
public struct WorkspaceFile: Hashable, Sendable, Identifiable {
    public var url: URL
    /// "Name" / "File Name" column.
    public var name: String
    /// "File Location" column (width 0 in OMGUI, but present and used for drag-and-drop).
    public var location: String
    /// "Size (MB)" column — megabytes to two decimal places.
    public var sizeText: String
    /// "Date Modified" column — `dd/MM/yy HH:mm:ss`.
    public var dateText: String
    public var byteSize: Int64
    public var date: Date

    public var id: String { location }
}

/// A directory listing that failed, and why — what the Data Files tab shows instead of nothing.
public struct WorkspaceListingFailure: Sendable, Equatable {
    public var folder: String
    public var message: String

    public init(folder: String, message: String) {
        self.folder = folder
        self.message = message
    }
}

/// The one failure `WorkspaceListing` remembers. Listings run on whatever thread asked for them,
/// so it carries its own lock.
private let workspaceListingFailure = LockedFailure()

private final class LockedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WorkspaceListingFailure?

    func get() -> WorkspaceListingFailure? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ failure: WorkspaceListingFailure?) {
        lock.lock(); value = failure; lock.unlock()
    }
}

/// Listing and formatting for the workspace, split out of the views so it is testable.
///
/// Mirrors `MainForm.fileListViewRefreshList` / `fileListViewOutputRefreshList` / `UpdateFile`.
public enum WorkspaceListing {

    /// `info.Length / 1024 / 1024` formatted with .NET's `"F"` (two decimals, invariant).
    public static func sizeText(bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1024.0 / 1024.0)
    }

    /// `dd/MM/yy HH:mm:ss`, the format OMGUI uses for every file date.
    public static let dateFormat = "dd/MM/yy HH:mm:ss"

    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    static func attributes(_ url: URL) -> (size: Int64, modified: Date, created: Date)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                            .creationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast,
                values.creationDate ?? values.contentModificationDate ?? .distantPast)
    }

    static func makeFile(_ url: URL, useCreationDate: Bool) -> WorkspaceFile? {
        guard let a = attributes(url) else { return nil }
        let date = useCreationDate ? a.created : a.modified
        return WorkspaceFile(url: url,
                             name: url.lastPathComponent,
                             location: url.path,
                             sizeText: sizeText(bytes: a.size),
                             dateText: dateText(date),
                             byteSize: a.size,
                             date: date)
    }

    /// Why the last listing came back empty, when it was not simply an empty folder.
    ///
    /// Cleared by the next listing that succeeds, and set by every one that fails. A non-sandboxed
    /// hardened-runtime app defaults its working folder to `~/Documents`, which is TCC protected:
    /// on "Don't Allow" the listing raises `NSFileReadNoPermissionError`, and swallowing that made
    /// the Data Files tab indistinguishable from an empty folder with no way back except System
    /// Settings (`refs/10-deep-review.md` C28).
    public static var lastFailure: WorkspaceListingFailure? { workspaceListingFailure.get() }

    static func contents(of folder: URL) -> [URL] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder,
                                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                                   options: [])
            workspaceListingFailure.set(nil)
            return urls
        } catch {
            workspaceListingFailure.set(WorkspaceListingFailure(folder: folder.path,
                                                                message: failureMessage(for: error, folder: folder)))
            return []
        }
    }

    /// A message that says what to do about it, rather than the raw Cocoa error.
    static func failureMessage(for error: Error, folder: URL) -> String {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else {
            return "Could not list \(folder.path): \(error.localizedDescription)"
        }
        switch error.code {
        case NSFileReadNoPermissionError:
            return "OmGui is not allowed to read \(folder.path). "
                + "Grant access in System Settings > Privacy & Security > Files and Folders, "
                + "or choose a different working folder."
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return "The working folder no longer exists: \(folder.path)"
        default:
            return "Could not list \(folder.path): \(error.localizedDescription)"
        }
    }

    /// The Data Files tab. `showAll` is OMGUI's `*.*` filter; otherwise only `*.cwa`.
    ///
    /// OMGUI adds a row only when `OmReader.Open` succeeds, so a file the reader rejects never
    /// appears even with "Show All Files" on. `readableOnly` reproduces that; tests turn it off.
    public static func dataFiles(in folder: URL, showAll: Bool, readableOnly: Bool = true) -> [WorkspaceFile] {
        contents(of: folder)
            .filter { showAll || $0.pathExtension.lowercased() == "cwa" }
            .filter { url in
                guard readableOnly else { return true }
                guard let reader = try? OmReader(path: url.path) else { return false }
                reader.close()
                return true
            }
            .compactMap { makeFile($0, useCreationDate: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Output Files tab: everything that is not `.cwa`, not `.part` and not hidden.
    public static func outputFiles(in folder: URL) -> [WorkspaceFile] {
        contents(of: folder)
            .filter { url in
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent
                return ext != "cwa" && ext != "part" && !name.hasPrefix(".")
            }
            .compactMap { makeFile($0, useCreationDate: true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
