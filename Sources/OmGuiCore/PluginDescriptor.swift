import Foundation

/// A plugin, as described by its XML `*.plugin` file (`Plugin.cs`).
///
/// Every default here is `Plugin.CreatePlugin`'s: missing numbers fall back to 600x800, missing
/// strings to the literal `"none"` (which `PluginsForm` compares against), and the booleans are
/// only true for the exact text `"true"`.
public struct PluginDescriptor: Sendable, Equatable, Identifiable {

    public var height = 600
    public var width = 800
    public var runFilePath = "none"
    public var htmlFilePath = "none"
    public var savedValuesFilePath = "none"
    public var iconName = "none"
    public var description = "none"
    public var fileName = "none"
    public var readableName = "none"
    public var outputExtensions: [String] = []
    public var outputFile = "none"
    public var inputFile = "none"
    public var defaultValues: [String: String] = [:]
    public var wantMetadata = false
    public var numberOfInputFiles = 1
    public var requiresCWANames = false
    public var createsOutput = false

    /// `Plugin.FilePath` — the folder the descriptor was found in.
    public var folder: URL = URL(fileURLWithPath: "/")

    public var id: String { folder.path }

    /// The plugin's run file, resolved against its folder.
    ///
    /// Standardized, so a descriptor's `../../../../../usr/bin/osascript` is a path that visibly
    /// leaves the plugin folder rather than one that only leaves it once the OS resolves it;
    /// `runFileIssue` is what refuses to launch it (`refs/10-deep-review.md` C24).
    public var runFileURL: URL { folder.appendingPathComponent(runFilePath).standardizedFileURL }
    /// The HTML form, resolved against its folder.
    public var htmlFileURL: URL { folder.appendingPathComponent(htmlFilePath).standardizedFileURL }

    public init() {}

    /// Whether a file resolved against the plugin folder actually stays inside it.
    public func isInsideFolder(_ url: URL) -> Bool {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix)
    }

    /// Why this plugin's run file must not be launched, or `nil` when it is safe to run.
    ///
    /// `RunProcess2` hands the descriptor's run file straight to `Process`, which is not
    /// LaunchServices: Gatekeeper never sees it, the child inherits OmGui's TCC responsibility,
    /// and nothing but this check stands between an XML file and arbitrary execution.
    ///
    /// The quarantine flag is only consulted for a plugin outside the app's own bundle: a
    /// downloaded `.app` carries `com.apple.quarantine` on everything inside it, and the bundled
    /// plugin has already been through notarisation with the rest of the app.
    public func runFileIssue(fileManager: FileManager = .default,
                             bundle: Bundle = .main) -> PluginRunFileIssue? {
        guard runFilePath != "none", !runFilePath.isEmpty else { return .notSpecified }
        let url = runFileURL
        let path = url.path
        guard isInsideFolder(url) else { return .outsideFolder(path) }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing(path)
        }
        guard fileManager.isExecutableFile(atPath: path) else { return .notExecutable(path) }

        #if os(macOS)
        let bundleRoot = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let inBundle = path.hasPrefix(bundleRoot.hasSuffix("/") ? bundleRoot : bundleRoot + "/")
        if !inBundle,
           let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]),
           values.quarantineProperties != nil {
            return .quarantined(path)
        }
        #endif
        return nil
    }

    /// `Plugin.CreatePlugin` — parse one descriptor. Returns `nil` for anything that is not XML.
    public static func parse(xml: String, folder: URL) -> PluginDescriptor? {
        guard let elements = PluginXml.parse(xml) else { return nil }
        var plugin = PluginDescriptor()
        plugin.folder = folder

        if let text = elements.first("height"), let value = Int(text) { plugin.height = value }
        if let text = elements.first("width"), let value = Int(text) { plugin.width = value }
        if let text = elements.first("runFilePath") { plugin.runFilePath = text }
        if let text = elements.first("htmlFilePath") { plugin.htmlFilePath = text }
        if let text = elements.first("savedValuesFilePath") { plugin.savedValuesFilePath = text }
        if let text = elements.first("iconName") { plugin.iconName = text }
        if let text = elements.first("description") { plugin.description = text }
        if let text = elements.first("readableName") { plugin.readableName = text }
        if let text = elements.first("fileName") { plugin.fileName = text }
        if let text = elements.first("outputFile") { plugin.outputFile = text }
        if let text = elements.first("inputFile") { plugin.inputFile = text }
        if elements.firstNode("outputExtensions") != nil {
            plugin.outputExtensions = elements.children("outputExtensions").map(\.text)
        }
        for child in elements.children("defaultValues") {
            plugin.defaultValues[child.name] = child.text
        }
        // `wantMetaDataXML[0].InnerText.Equals("true")` — anything else is false.
        plugin.wantMetadata = elements.first("wantMetadata") == "true"
        plugin.requiresCWANames = elements.first("requiresCWANames") == "true"
        plugin.createsOutput = elements.first("createsOutput") == "true"
        // Upstream uses `Int32.Parse`, which throws for anything unparsable and loses the plugin;
        // the port keeps the documented default instead.
        if let text = elements.first("numberOfInputFiles"), let value = Int(text) {
            plugin.numberOfInputFiles = value
        }
        return plugin
    }

    /// Read the one `*.plugin` file in a folder.
    public static func load(from folder: URL, fileManager: FileManager = .default) -> PluginDescriptor? {
        let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".plugin") }
            .sorted()
        guard let name = names.first,
              let xml = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        else { return nil }
        return parse(xml: xml, folder: folder)
    }
}

/// Why a plugin's run file cannot be launched.
public enum PluginRunFileIssue: Sendable, Equatable {
    /// The descriptor names no run file (`Plugin.CreatePlugin`'s `"none"` default).
    case notSpecified
    /// The run file resolves outside the plugin's own folder.
    case outsideFolder(String)
    case missing(String)
    case notExecutable(String)
    /// Downloaded from the internet and never released by Gatekeeper.
    case quarantined(String)

    /// What the user is told instead of a bare non-zero exit.
    public var message: String {
        switch self {
        case .notSpecified:
            return "This plugin does not name a program to run (its descriptor has no runFilePath)."
        case .outsideFolder(let path):
            return "Refusing to run \(path): a plugin may only run a program inside its own folder."
        case .missing(let path):
            return "The plugin's run file is missing: \(path)"
        case .notExecutable(let path):
            return "The plugin's run file is not executable: \(path)\n"
                + "Make it executable (chmod +x) and run the plugin again."
        case .quarantined(let path):
            return "Refusing to run \(path): the file is quarantined (it was downloaded from the "
                + "internet and macOS has not released it).\nCheck where the plugin came from, then "
                + "clear the flag with: xattr -d com.apple.quarantine \"\(path)\""
        }
    }
}

/// `PluginManager` — the plugins in the Options "Plugin Folder".
public enum PluginManager {

    /// The folder the app ships its own plugins in (`OmGui.app/Contents/Resources/Plugins`), and
    /// the checkout equivalent used while developing.
    public static func bundledPluginFolder(bundle: Bundle = .main,
                                           executable: URL? = Bundle.main.executableURL,
                                           fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Plugins", isDirectory: true))
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Resources/Plugins", isDirectory: true))
        if var directory = executable?.deletingLastPathComponent().standardizedFileURL {
            for _ in 0..<8 {
                candidates.append(directory.appendingPathComponent("Resources/Plugins", isDirectory: true))
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// `Properties.Settings.Default.CurrentPluginFolder`, defaulting to what the app ships.
    public static func effectiveFolder(setting: String,
                                       fileManager: FileManager = .default) -> URL? {
        if !setting.isEmpty {
            let url = URL(fileURLWithPath: WorkspacePath.expand(setting), isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return bundledPluginFolder(fileManager: fileManager)
    }

    /// `PluginManager.LoadPlugins` — every immediate subdirectory holding a `*.plugin` file.
    public static func load(from folder: URL, fileManager: FileManager = .default) -> [PluginDescriptor] {
        let entries = ((try? fileManager.contentsOfDirectory(at: folder,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return entries.compactMap { PluginDescriptor.load(from: $0, fileManager: fileManager) }
    }
}

// MARK: - The run dialog

/// The data viewer selection a plugin is told about (`PluginsForm`'s block/time arguments).
public struct PluginSelection: Sendable, Equatable {
    public var blockStart: Double
    public var blockCount: Double
    /// `dd/MM/yyyy/_HH:mm:ss`, the format `MainForm` formats the selection with.
    public var startTime: String
    public var endTime: String

    public init(blockStart: Double, blockCount: Double, startTime: String, endTime: String) {
        self.blockStart = blockStart
        self.blockCount = blockCount
        self.startTime = startTime
        self.endTime = endTime
    }

    public static let timeFormat = "dd/MM/yyyy/_HH:mm:ss"

    /// Formatted in UTC, the clock the plot draws and the one the `.CWA` stores: a plugin is given
    /// `startTime`/`endTime` beside `startBlock`/`blockCount`, and those two describe the same
    /// window only if both are read on the device's own clock (`refs/10-deep-review.md` C21).
    public static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = timeFormat
        return formatter.string(from: date)
    }
}

/// `RunPluginForm` — the query string the HTML form is loaded with, and the command line its
/// `window.location.hash` turns into.
public enum PluginHost {

    /// `RunPluginForm.Go` — `file:///<html>?` plus metadata, selection, inputs and saved values.
    ///
    /// Upstream appends `"?"` and then, because the URL is always longer than one character,
    /// prefixes every following group with `"&"`; the resulting `?&` is reproduced so a plugin
    /// page that splits on `&` sees exactly the fields OMGUI gives it.
    public static func formQuery(plugin: PluginDescriptor,
                                 inputs: [String],
                                 metadata: [(key: String, value: String)] = [],
                                 selection: PluginSelection? = nil,
                                 savedValues: [(key: String, value: String)] = []) -> String {
        var url = "?"

        if plugin.wantMetadata {
            var notFirst = false
            for pair in metadata {
                if notFirst { url += "&" } else { notFirst = true }
                url += "\(pair.key)=\(pair.value)"
            }
        }

        if let selection, selection.blockStart > -1, selection.blockCount > -1 {
            url += "&startBlock=\(format(selection.blockStart))&blockCount=\(format(selection.blockCount))"
        }
        if let selection, !selection.startTime.isEmpty, !selection.endTime.isEmpty {
            url += "&startTime=\(selection.startTime)&endTime=\(selection.endTime)"
        }
        if plugin.requiresCWANames, let first = inputs.first {
            url += "&input1=\(first)"
            for (index, input) in inputs.enumerated().dropFirst() {
                url += "&input\(index + 1)=\(input)"
            }
        }
        if !savedValues.isEmpty {
            url += "?" + savedValues.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        return url
    }

    /// .NET prints a `float` with the shortest round-trip form ("2" for 2.0, "2.5" for 2.5).
    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    /// `RunPluginForm.NewArgumentCreator` — the fragment the page sets is
    /// `<parameters>?<output file name>`.
    ///
    /// `parameterString` is the page's own text and nothing else. Upstream splices the first CWA
    /// into it as `"<path>" ` and re-splits the result, so a file name containing a `"` splices
    /// extra argv entries into the plugin's command line; here the input path never goes through
    /// the splitter at all — `invocation` puts it in front of the split parameters as its own argv
    /// entry (`refs/10-deep-review.md` C41).
    public static func arguments(fromFragment fragment: String,
                                 plugin: PluginDescriptor,
                                 inputs: [String]) -> (parameterString: String, outputName: String)? {
        let parts = fragment.components(separatedBy: "?")
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// `RunProcess2` — the plugin's argv: the first CWA, then the page's parameters split the way
    /// Windows would, with the output name resolved into the working folder.
    ///
    /// Every path that the *host* contributes (the input file, the output file) is placed as a
    /// finished argv entry. Upstream instead re-quotes the output path into the command line and
    /// splits it again, which loses a workspace name containing a `"` (`refs/10-deep-review.md`
    /// C25); only the plugin page's own text is ever parsed here.
    ///
    /// Upstream also substitutes when the plugin asks for no output file, which for a name of `""`
    /// mangles the quoting; the port only substitutes a non-empty name.
    public static func invocation(plugin: PluginDescriptor,
                                  parameterString: String,
                                  outputName: String,
                                  workingFolder: URL,
                                  inputs: [String]) -> ToolInvocation {
        var arguments = splitCommandLine(parameterString).map(ToolArgument.quoted)
        // Upstream's one hard-coded exception is the ClimbAx plugin.
        if plugin.readableName != "ClimbAx", let first = inputs.first {
            arguments.insert(.quoted(first), at: 0)
        }
        var finalPath = inputs.first ?? ""
        let trimmed = outputName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !trimmed.isEmpty {
            let full = workingFolder.appendingPathComponent(trimmed).path
            arguments = arguments.map { argument in
                guard argument.value.contains(trimmed) else { return argument }
                return .quoted(argument.value.replacingOccurrences(of: trimmed, with: full))
            }
            finalPath = full
        }
        return ToolInvocation(executable: .path(plugin.runFileURL.path),
                              argumentList: arguments,
                              outputPath: nil,
                              finalPath: finalPath,
                              inputPath: inputs.first ?? "",
                              workingDirectory: plugin.folder.path,
                              refusal: plugin.runFileIssue()?.message)
    }

    /// Windows-style argv splitting: whitespace separates, double quotes group.
    public static func splitCommandLine(_ line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        var started = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                started = true
            } else if !inQuotes, character == " " || character == "\t" {
                if started { arguments.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { arguments.append(current) }
        return arguments
    }
}

// MARK: - A very small XML reader

/// Just enough of `XmlDocument.GetElementsByTagName` for the `.plugin` schema: element names,
/// their text, and their direct element children.
struct PluginXml {

    struct Node {
        var name: String
        var text: String
        /// Document order, so lookups match `GetElementsByTagName`'s pre-order result.
        var order: Int = 0
        var children: [Node] = []
    }

    private var nodes: [Node] = []

    static func parse(_ xml: String) -> PluginXml? {
        let delegate = Builder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        var document = PluginXml()
        document.nodes = delegate.flattened.sorted { $0.order < $1.order }
        return document
    }

    /// `GetElementsByTagName(name)[0].InnerText`.
    func first(_ name: String) -> String? { firstNode(name)?.text }

    func firstNode(_ name: String) -> Node? { nodes.first { $0.name == name } }

    /// The element children of the first element with this name.
    func children(_ name: String) -> [Node] { firstNode(name)?.children ?? [] }

    private final class Builder: NSObject, XMLParserDelegate {
        var flattened: [Node] = []
        private var stack: [Node] = []
        private var counter = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            counter += 1
            stack.append(Node(name: elementName, text: "", order: counter))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            guard var node = stack.popLast() else { return }
            // `XmlDocument.PreserveWhitespace` is false by default: whitespace-only text between
            // elements never becomes a text node, so a container element reads as empty.
            if !node.children.isEmpty || node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !stack.isEmpty { stack[stack.count - 1].children.append(node) }
            flattened.append(node)
        }
    }
}
