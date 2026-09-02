import AppKit
import OmGuiCore
import SwiftUI
import WebKit

/// `PluginsForm` — "Select a Plugin", its description, and Run.
struct PluginsSheet: View {

    @ObservedObject var context: PluginsSheetContext
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DialogTitleBar(title: "PluginsForm")
            VStack(alignment: .leading, spacing: 10) {
                Text("Select a Plugin").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $context.index) {
                    ForEach(context.plugins.indices, id: \.self) { position in
                        Text(context.plugins[position].readableName).tag(position)
                    }
                }
                .labelsHidden()

                grid("Description:", context.selected.description)
                // `inputFileContentsLabel` / `outputFileContentsLabel` show "not specified" for
                // the descriptor's `"none"` default.
                grid("Input File:", value(context.selected.inputFile))
                grid("Output File:", value(context.selected.outputFile))

                Text(context.files.map(DotNetPath.fileName).joined(separator: "  |  "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider()
                HStack {
                    Button("Refresh") { model.showPlugins() }
                    Spacer()
                    Button("Cancel") { model.pluginsSheet = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Run...") { model.runPlugin(context) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 420)
    }

    private func value(_ text: String) -> String { text == "none" ? "not specified" : text }

    private func grid(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).frame(width: 84, alignment: .leading)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
    }
}

/// `RunPluginForm` — the plugin's own HTML form in a web view, sized from the descriptor.
///
/// The contract is upstream's: the page sets `window.location.hash` to
/// `<parameters>?<output file name>`, and the host turns that into the plugin's command line
/// (`RunPluginForm.NewArgumentCreator`). Both a fragment navigation and a `hashchange` event are
/// picked up, so a page written for the Windows `WebBrowser` control needs no changes.
struct RunPluginSheet: View {

    @ObservedObject var context: RunPluginSheetContext
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DialogTitleBar(title: context.plugin.readableName)
            PluginWebView(url: context.formURL,
                          readAccess: context.plugin.folder) { fragment in
                model.pluginFormSubmitted(context, fragment: fragment)
            }
            Divider()
            HStack {
                Text(context.formURL.path)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Cancel") { model.runPluginSheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
        }
        .frame(width: CGFloat(context.plugin.width), height: CGFloat(context.plugin.height))
    }
}

/// The `webBrowser1` control.
struct PluginWebView: NSViewRepresentable {

    let url: URL
    let readAccess: URL
    let onFragment: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFragment: onFragment) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: PluginWebView.messageName)
        controller.addUserScript(WKUserScript(source: PluginWebView.hashBridge,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static let messageName = "omgui"

    /// Mirrors the fragment back to the host, for pages that set the hash without navigating.
    static let hashBridge = """
    (function () {
      function post() {
        try { window.webkit.messageHandlers.\(messageName).postMessage(String(window.location.hash || "")); }
        catch (error) { }
      }
      window.addEventListener("hashchange", post, false);
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let onFragment: (String) -> Void
        private var delivered = false

        init(onFragment: @escaping (String) -> Void) {
            self.onFragment = onFragment
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let fragment = navigationAction.request.url?.fragment, !fragment.isEmpty {
                decisionHandler(.cancel)
                deliver(fragment)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let raw = message.body as? String else { return }
            deliver(String(raw.drop(while: { $0 == "#" })))
        }

        private func deliver(_ fragment: String) {
            guard !delivered, !fragment.isEmpty else { return }
            delivered = true
            onFragment(fragment.removingPercentEncoding ?? fragment)
        }
    }
}
