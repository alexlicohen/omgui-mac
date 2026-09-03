import Foundation
import OmGuiCore
import XCTest

/// `Plugin.cs` / `PluginManager.cs` / `RunPluginForm.cs`.
final class PluginHostTests: XCTestCase {

    /// The repository this test was compiled from, so the real descriptors can be read.
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/OmGuiTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo>

    static var upstreamPluginFolder: URL {
        repository
            .appendingPathComponent("upstream/openmovement/Software/OM/Plugins for release/Plugins/OmConvertPlugin",
                                    isDirectory: true)
    }

    static var portedPluginFolder: URL {
        repository.appendingPathComponent("Resources/Plugins/OmConvertPlugin", isDirectory: true)
    }

    // MARK: - Descriptor parsing

    /// The real `AX_OMConvert.plugin` that ships with OMGUI.
    func testParsesTheUpstreamOmConvertDescriptor() throws {
        let folder = PluginHostTests.upstreamPluginFolder
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path),
                          "upstream/ is not checked out")
        let plugin = try XCTUnwrap(PluginDescriptor.load(from: folder))

        XCTAssertEqual(plugin.height, 500)
        XCTAssertEqual(plugin.width, 700)
        XCTAssertEqual(plugin.runFilePath, "run-omconvert.cmd")
        XCTAssertEqual(plugin.htmlFilePath, "AX_OMConvert.html")
        XCTAssertEqual(plugin.savedValuesFilePath, "saved.xml")
        XCTAssertEqual(plugin.iconName, "64x64 converter.ico")
        XCTAssertEqual(plugin.description, "OMConvert")
        XCTAssertEqual(plugin.fileName, "OMConvert")
        XCTAssertEqual(plugin.readableName, "OMConvert")
        XCTAssertEqual(plugin.outputExtensions, [""], "one empty <extension> child")
        XCTAssertEqual(plugin.numberOfInputFiles, 1)
        XCTAssertFalse(plugin.wantMetadata)
        XCTAssertTrue(plugin.requiresCWANames)
        // Absent from the file, so `Plugin.CreatePlugin`'s defaults stand.
        XCTAssertFalse(plugin.createsOutput)
        XCTAssertEqual(plugin.outputFile, "none")
        XCTAssertEqual(plugin.inputFile, "none")
        XCTAssertTrue(plugin.defaultValues.isEmpty)
    }

    /// The descriptor this port ships: identical but for the run file.
    func testParsesThePortedOmConvertDescriptor() throws {
        let plugin = try XCTUnwrap(PluginDescriptor.load(from: PluginHostTests.portedPluginFolder))
        XCTAssertEqual(plugin.readableName, "OMConvert")
        XCTAssertEqual(plugin.runFilePath, "run-omconvert.sh")
        XCTAssertEqual(plugin.width, 700)
        XCTAssertEqual(plugin.height, 500)
        XCTAssertTrue(plugin.requiresCWANames)
        XCTAssertEqual(plugin.runFileURL.lastPathComponent, "run-omconvert.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: plugin.runFileURL.path),
                      "the shipped run file must be executable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.htmlFileURL.path))
    }

    func testMissingFieldsFallBackToPluginCreatePluginDefaults() throws {
        let plugin = try XCTUnwrap(PluginDescriptor.parse(xml: "<Plugin></Plugin>",
                                                          folder: URL(fileURLWithPath: "/p")))
        XCTAssertEqual(plugin.height, 600)
        XCTAssertEqual(plugin.width, 800)
        XCTAssertEqual(plugin.runFilePath, "none")
        XCTAssertEqual(plugin.htmlFilePath, "none")
        XCTAssertEqual(plugin.readableName, "none")
        XCTAssertEqual(plugin.numberOfInputFiles, 1)
        XCTAssertTrue(plugin.outputExtensions.isEmpty)
    }

    func testBooleansAreOnlyTrueForTheExactWordTrue() throws {
        let xml = """
        <Plugin><wantMetadata>True</wantMetadata><requiresCWANames>true</requiresCWANames>
        <createsOutput>1</createsOutput></Plugin>
        """
        let plugin = try XCTUnwrap(PluginDescriptor.parse(xml: xml, folder: URL(fileURLWithPath: "/p")))
        XCTAssertFalse(plugin.wantMetadata, "InnerText.Equals(\"true\") is case-sensitive")
        XCTAssertTrue(plugin.requiresCWANames)
        XCTAssertFalse(plugin.createsOutput)
    }

    func testDefaultValuesAndOutputExtensions() throws {
        let xml = """
        <Plugin>
          <outputExtensions><extension>csv</extension><extension>wav</extension></outputExtensions>
          <defaultValues><epoch>60</epoch><model>wrist</model></defaultValues>
        </Plugin>
        """
        let plugin = try XCTUnwrap(PluginDescriptor.parse(xml: xml, folder: URL(fileURLWithPath: "/p")))
        XCTAssertEqual(plugin.outputExtensions, ["csv", "wav"])
        XCTAssertEqual(plugin.defaultValues, ["epoch": "60", "model": "wrist"])
    }

    func testInvalidXmlIsRejected() {
        XCTAssertNil(PluginDescriptor.parse(xml: "<Plugin>", folder: URL(fileURLWithPath: "/p")))
    }

    // MARK: - PluginManager

    func testLoadsEveryFolderWithADescriptor() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, name) in [("Zed", "Zed"), ("Alpha", "Alpha")] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "<Plugin><readableName>\(name)</readableName></Plugin>"
                .write(to: directory.appendingPathComponent("\(name).plugin"), atomically: true, encoding: .utf8)
        }
        // A folder with no descriptor is skipped.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"),
                                                withIntermediateDirectories: true)

        let plugins = PluginManager.load(from: root)
        XCTAssertEqual(plugins.map(\.readableName), ["Alpha", "Zed"])
    }

    func testTheShippedPluginFolderIsFound() throws {
        let plugins = PluginManager.load(from: PluginHostTests.portedPluginFolder.deletingLastPathComponent())
        XCTAssertEqual(plugins.map(\.readableName), ["OMConvert"])
    }

    // MARK: - RunPluginForm

    /// `RunPluginForm.Go` — the query the HTML form is loaded with.
    func testFormQueryCarriesTheInputsAndSelection() throws {
        var plugin = PluginDescriptor()
        plugin.requiresCWANames = true
        let selection = PluginSelection(blockStart: 12, blockCount: 30,
                                        startTime: "01/02/2026/_10:00:00",
                                        endTime: "01/02/2026/_11:00:00")
        let query = PluginHost.formQuery(plugin: plugin,
                                         inputs: ["/w/a.cwa", "/w/b.cwa"],
                                         selection: selection)
        XCTAssertEqual(query,
                       "?&startBlock=12&blockCount=30"
                       + "&startTime=01/02/2026/_10:00:00&endTime=01/02/2026/_11:00:00"
                       + "&input1=/w/a.cwa&input2=/w/b.cwa")
    }

    func testFormQueryOmitsInputsWhenTheDescriptorDoesNotAskForThem() {
        let query = PluginHost.formQuery(plugin: PluginDescriptor(), inputs: ["/w/a.cwa"])
        XCTAssertEqual(query, "?")
    }

    func testFormQueryIncludesMetadataOnlyWhenRequested() {
        var plugin = PluginDescriptor()
        plugin.wantMetadata = true
        XCTAssertEqual(PluginHost.formQuery(plugin: plugin, inputs: [],
                                            metadata: [("meta_weight", "70"), ("meta_site", "left+wrist")]),
                       "?meta_weight=70&meta_site=left+wrist")
    }

    /// `NewArgumentCreator` — `<parameters>?<output name>`. The page's own text and nothing else:
    /// the input path is an argv entry `invocation` prepends, never text to be re-split (C41).
    func testArgumentsFromTheFragment() throws {
        var plugin = PluginDescriptor()
        plugin.readableName = "OMConvert"
        let result = try XCTUnwrap(PluginHost.arguments(fromFragment: "\"\"?\"\"",
                                                        plugin: plugin,
                                                        inputs: ["/w/a.cwa"]))
        XCTAssertEqual(result.parameterString, "\"\"")
        XCTAssertEqual(result.outputName, "\"\"")
    }

    func testAFragmentWithoutTheOutputSeparatorIsRejected() {
        XCTAssertNil(PluginHost.arguments(fromFragment: "no-separator",
                                          plugin: PluginDescriptor(), inputs: ["/w/a.cwa"]))
    }

    /// `RunProcess2` — the output name becomes a full path in the working folder, and the command
    /// line is split into argv the way Windows would.
    func testInvocationPutsTheOutputInTheWorkingFolder() {
        var plugin = PluginDescriptor()
        plugin.readableName = "Thing"
        plugin.runFilePath = "run.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/Thing", isDirectory: true)
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "-o report.csv",
                                               outputName: "report.csv",
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: ["/w/a.cwa"])
        XCTAssertEqual(invocation.executable, .path("/plugins/Thing/run.sh"))
        XCTAssertEqual(invocation.arguments, ["/w/a.cwa", "-o", "/work/report.csv"])
        XCTAssertEqual(invocation.finalPath, "/work/report.csv")
        XCTAssertEqual(invocation.workingDirectory, "/plugins/Thing")
    }

    /// ClimbAx is upstream's one hard-coded exception: it is not handed its input file.
    func testClimbAxIsTheOnePluginThatIsNotGivenItsInput() {
        var plugin = PluginDescriptor()
        plugin.readableName = "ClimbAx"
        plugin.runFilePath = "run.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/ClimbAx", isDirectory: true)
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "-x 1",
                                               outputName: "out.csv",
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: ["/w/a.cwa"])
        XCTAssertEqual(invocation.arguments, ["-x", "1"])
        XCTAssertEqual(invocation.finalPath, "/work/out.csv")
    }

    /// OMConvert asks for no output file; upstream's substitution would mangle the quoting, so the
    /// port leaves the command line alone and the source file stands as the job's output.
    func testInvocationWithNoOutputName() {
        var plugin = PluginDescriptor()
        plugin.runFilePath = "run-omconvert.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/OmConvertPlugin", isDirectory: true)
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "\"\"",
                                               outputName: "\"\"",
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: ["/w/a.cwa"])
        XCTAssertEqual(invocation.arguments, ["/w/a.cwa", ""])
        XCTAssertEqual(invocation.finalPath, "/w/a.cwa")
    }

    // MARK: - Paths the host contributes are argv entries, never text (C25/C41)

    /// A `.cwa` whose name contains a quote (a Finder rename; download names are sanitised) used to
    /// splice extra argv entries into the plugin's command line.
    func testAFileNameContainingAQuoteIsOneArgument() throws {
        var plugin = PluginDescriptor()
        plugin.readableName = "Thing"
        plugin.runFilePath = "run.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/Thing", isDirectory: true)
        let input = "/w/pilot \"2\" data.cwa"

        let fragment = try XCTUnwrap(PluginHost.arguments(fromFragment: "-x 1 -o out.csv?out.csv",
                                                          plugin: plugin, inputs: [input]))
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: fragment.parameterString,
                                               outputName: fragment.outputName,
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: [input])
        XCTAssertEqual(invocation.arguments, [input, "-x", "1", "-o", "/work/out.csv"],
                       "the path is one argv entry, quotes and all")
        XCTAssertEqual(invocation.inputPath, input)
    }

    /// The same for the output side: a workspace folder containing a quote used to be re-quoted
    /// into the command line and split again, which dropped the quotes and lost the directory.
    func testAWorkingFolderContainingAQuoteKeepsTheOutputPath() {
        var plugin = PluginDescriptor()
        plugin.readableName = "Thing"
        plugin.runFilePath = "run.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/Thing", isDirectory: true)
        let workingFolder = URL(fileURLWithPath: "/Users/x/my \"pilot\" data", isDirectory: true)

        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "-o out.csv",
                                               outputName: "out.csv",
                                               workingFolder: workingFolder,
                                               inputs: ["/w/a.cwa"])
        let expected = "/Users/x/my \"pilot\" data/out.csv"
        XCTAssertEqual(invocation.arguments, ["/w/a.cwa", "-o", expected])
        XCTAssertEqual(invocation.finalPath, expected,
                       "the file the job looks for is the one the helper was told to write")
    }

    // MARK: - The run file (C24)

    private func makePlugin(in folder: URL, runFilePath: String) -> PluginDescriptor {
        var plugin = PluginDescriptor()
        plugin.readableName = "Thing"
        plugin.runFilePath = runFilePath
        plugin.folder = folder
        return plugin
    }

    private func scratchFolder() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testARunFileOutsideThePluginFolderIsRefused() throws {
        let folder = try scratchFolder()
        let plugin = makePlugin(in: folder, runFilePath: "../../../../../usr/bin/osascript")
        XCTAssertFalse(plugin.isInsideFolder(plugin.runFileURL))
        guard case .outsideFolder = try XCTUnwrap(plugin.runFileIssue()) else {
            return XCTFail("expected an escape to be refused, got \(String(describing: plugin.runFileIssue()))")
        }
        // And the refusal reaches the process runner rather than spawning osascript.
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "tell application \"Finder\"",
                                               outputName: "",
                                               workingFolder: folder,
                                               inputs: ["/w/a.cwa"])
        let refusal = try XCTUnwrap(invocation.refusal)
        XCTAssertTrue(refusal.contains("only run a program inside its own folder"), refusal)

        let log = ProgressCollector.Lines()
        let result = ToolProcess().run(invocation,
                                       executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                       onOutput: { line in log.append(line) })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errorMessage, refusal)
        XCTAssertTrue(log.all.contains { $0.hasPrefix("<<<ERROR:") }, log.all.joined(separator: "\n"))
    }

    func testAMissingOrUnexecutableRunFileIsRefused() throws {
        let folder = try scratchFolder()
        let missing = makePlugin(in: folder, runFilePath: "run.sh")
        guard case .missing = try XCTUnwrap(missing.runFileIssue()) else {
            return XCTFail("expected a missing run file to be refused")
        }

        let script = folder.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        guard case .notExecutable = try XCTUnwrap(missing.runFileIssue()) else {
            return XCTFail("expected a non-executable run file to be refused")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertNil(missing.runFileIssue(), "an executable file inside the folder is fine")
        XCTAssertNil(PluginHost.invocation(plugin: missing, parameterString: "", outputName: "",
                                           workingFolder: folder, inputs: []).refusal)
    }

    func testADescriptorWithNoRunFileIsRefused() throws {
        let folder = try scratchFolder()
        XCTAssertEqual(makePlugin(in: folder, runFilePath: "none").runFileIssue(), .notSpecified)
    }

    func testAQuarantinedRunFileIsRefusedOutsideTheAppBundle() throws {
        let folder = try scratchFolder()
        let script = folder.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let plugin = makePlugin(in: folder, runFilePath: "run.sh")
        XCTAssertNil(plugin.runFileIssue())

        // What LaunchServices would have stopped, had the child been launched through it.
        let quarantine = Process()
        quarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        quarantine.arguments = ["-w", "com.apple.quarantine",
                                "0081;00000000;OmGuiTests;", script.path]
        try quarantine.run()
        quarantine.waitUntilExit()
        try XCTSkipUnless(quarantine.terminationStatus == 0, "could not set com.apple.quarantine")

        guard case .quarantined = try XCTUnwrap(plugin.runFileIssue()) else {
            return XCTFail("expected a quarantined run file to be refused")
        }
        // A plugin shipped inside the app bundle is exempt: the whole bundle carries the flag once
        // it has been downloaded, and it has already been through notarisation.
        let ownBundle = Bundle(url: folder) ?? Bundle.main
        if ownBundle.bundleURL == folder {
            XCTAssertNil(plugin.runFileIssue(bundle: ownBundle))
        }
    }

    func testTheShippedPluginIsRunnable() throws {
        let plugin = try XCTUnwrap(PluginDescriptor.load(from: PluginHostTests.portedPluginFolder))
        XCTAssertNil(plugin.runFileIssue(), "the plugin the app ships must pass its own check")
    }

    func testCommandLineSplitting() {
        XCTAssertEqual(PluginHost.splitCommandLine("\"/a b/c.cwa\" -x 1"), ["/a b/c.cwa", "-x", "1"])
        XCTAssertEqual(PluginHost.splitCommandLine("  a   b  "), ["a", "b"])
        XCTAssertEqual(PluginHost.splitCommandLine("\"\""), [""])
        XCTAssertEqual(PluginHost.splitCommandLine(""), [])
    }
}

extension ProgressCollector {
    /// A thread-safe line sink for the helper transcript, which arrives on a pipe queue.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock(); storage.append(line); lock.unlock()
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
