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

    /// `NewArgumentCreator` — `<parameters>?<output name>`, with the first CWA prepended, quoted.
    func testArgumentsFromTheFragment() throws {
        var plugin = PluginDescriptor()
        plugin.readableName = "OMConvert"
        let result = try XCTUnwrap(PluginHost.arguments(fromFragment: "\"\"?\"\"",
                                                        plugin: plugin,
                                                        inputs: ["/w/a.cwa"]))
        XCTAssertEqual(result.parameterString, "\"/w/a.cwa\" \"\"")
        XCTAssertEqual(result.outputName, "\"\"")
    }

    func testClimbAxIsTheOneNamePluginThatIsNotGivenItsInput() throws {
        var plugin = PluginDescriptor()
        plugin.readableName = "ClimbAx"
        let result = try XCTUnwrap(PluginHost.arguments(fromFragment: "-x 1?out.csv",
                                                        plugin: plugin, inputs: ["/w/a.cwa"]))
        XCTAssertEqual(result.parameterString, "-x 1")
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
                                               parameterString: "\"/w/a.cwa\" -o report.csv",
                                               outputName: "report.csv",
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: ["/w/a.cwa"])
        XCTAssertEqual(invocation.executable, .path("/plugins/Thing/run.sh"))
        XCTAssertEqual(invocation.arguments, ["/w/a.cwa", "-o", "/work/report.csv"])
        XCTAssertEqual(invocation.finalPath, "/work/report.csv")
        XCTAssertEqual(invocation.workingDirectory, "/plugins/Thing")
    }

    /// OMConvert asks for no output file; upstream's substitution would mangle the quoting, so the
    /// port leaves the command line alone and the source file stands as the job's output.
    func testInvocationWithNoOutputName() {
        var plugin = PluginDescriptor()
        plugin.runFilePath = "run-omconvert.sh"
        plugin.folder = URL(fileURLWithPath: "/plugins/OmConvertPlugin", isDirectory: true)
        let invocation = PluginHost.invocation(plugin: plugin,
                                               parameterString: "\"/w/a.cwa\" \"\"",
                                               outputName: "\"\"",
                                               workingFolder: URL(fileURLWithPath: "/work"),
                                               inputs: ["/w/a.cwa"])
        XCTAssertEqual(invocation.arguments, ["/w/a.cwa", ""])
        XCTAssertEqual(invocation.finalPath, "/w/a.cwa")
    }

    func testCommandLineSplitting() {
        XCTAssertEqual(PluginHost.splitCommandLine("\"/a b/c.cwa\" -x 1"), ["/a b/c.cwa", "-x", "1"])
        XCTAssertEqual(PluginHost.splitCommandLine("  a   b  "), ["a", "b"])
        XCTAssertEqual(PluginHost.splitCommandLine("\"\""), [""])
        XCTAssertEqual(PluginHost.splitCommandLine(""), [])
    }
}
