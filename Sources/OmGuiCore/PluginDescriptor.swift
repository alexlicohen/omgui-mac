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
    public var runFileURL: URL { folder.appendingPathComponent(runFilePath) }
    /// The HTML form, resolved against its folder.
    public var htmlFileURL: URL { folder.appendingPathComponent(htmlFilePath) }

    public init() {}

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

    public static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
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
    /// `<parameters>?<output file name>`; the first CWA is prepended, quoted.
    public static func arguments(fromFragment fragment: String,
                                 plugin: PluginDescriptor,
                                 inputs: [String]) -> (parameterString: String, outputName: String)? {
        let parts = fragment.components(separatedBy: "?")
        guard parts.count == 2 else { return nil }
        var parameters = parts[0]
        // Upstream's one hard-coded exception is the ClimbAx plugin.
        if plugin.readableName != "ClimbAx", let first = inputs.first {
            parameters = "\"\(first)\" " + parameters
        }
        return (parameters, parts[1])
    }

    /// `RunProcess2` — put the output file in the working folder, then split the command line the
    /// way Windows would before handing it to `Process`.
    ///
    /// Upstream substitutes even when the plugin asks for no output file, which for a name of `""`
    /// mangles the quoting; the port only substitutes a non-empty name.
    public static func invocation(plugin: PluginDescriptor,
                                  parameterString: String,
                                  outputName: String,
                                  workingFolder: URL,
                                  inputs: [String]) -> ToolInvocation {
        var parameters = parameterString
        var finalPath = inputs.first ?? ""
        let trimmed = outputName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !trimmed.isEmpty {
            let full = workingFolder.appendingPathComponent(trimmed).path
            parameters = parameters.replacingOccurrences(of: outputName, with: "\"\(full)\"")
            finalPath = full
        }
        return ToolInvocation(executable: .path(plugin.runFileURL.path),
                              argumentList: splitCommandLine(parameters).map(ToolArgument.quoted),
                              outputPath: nil,
                              finalPath: finalPath,
                              inputPath: inputs.first ?? "",
                              workingDirectory: plugin.folder.path)
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
