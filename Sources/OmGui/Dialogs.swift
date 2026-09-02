import AppKit
import OmApi
import OmGuiCore
import SwiftUI

/// `OptionsDialog` — "Options".
struct OptionsView: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var filenameTemplate = ""
    @State private var pluginFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Filename:").frame(width: 84, alignment: .leading)
                TextField("", text: $filenameTemplate).frame(width: 260)
                Button("Default") { filenameTemplate = FilenameTemplate.defaultTemplate }
            }
            HStack(spacing: 6) {
                Text("Plugin Folder:").frame(width: 84, alignment: .leading)
                TextField("", text: $pluginFolder).frame(width: 260)
                Button("Browse...") { browse() }
            }
            Text(FilenameTemplate.placeholderHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.settings.filenameTemplate = filenameTemplate
                    model.settings.pluginFolder = pluginFolder
                    model.log("Options: filename template = \(filenameTemplate)")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            filenameTemplate = model.settings.filenameTemplate
            pluginFolder = model.settings.pluginFolder
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            pluginFolder = url.path
        }
    }
}

/// `AboutBox` — Help ▸ About.
struct AboutView: View {

    @Environment(\.dismiss) private var dismiss

    /// `AssemblyProduct` / `AssemblyDescription` / `AssemblyCopyright` from OMGUI's `AssemblyInfo`.
    static let productName = "OmGui"
    static let description = "Open Movement GUI Application"
    static let upstreamCopyright = "Copyright (c) 2009-2022, Newcastle University, UK."
    static let portNote = "Native macOS port of Axivity/Open Movement's OMGUI (v1.0.0.45), built on the vendored libomapi."

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (.some(short), .some(build)): return "\(short) (\(build))"
        case let (.some(short), .none): return short
        default: return "development build"
        }
    }

    /// The BSD-2 notice `AboutBox.resx` shows.
    static let licence = """
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AboutView.productName).font(.system(size: 16, weight: .semibold))
            Text(AboutView.description).font(.system(size: 12))
            Text("Version \(AboutView.version)").font(.system(size: 11))
            Text(AboutView.portNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                Text(AboutView.upstreamCopyright + "\n" + AboutView.licence)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

/// `ProgressBox` — the modal shown over a `BackgroundWorker`.
struct ProgressSheet: View {

    @ObservedObject var context: ProgressSheetContext
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(context.title).font(.system(size: 13, weight: .semibold))
            Text(context.message).font(.system(size: 11)).lineLimit(2)
            ProgressView(value: model.progress ?? 0)
                .progressViewStyle(.linear)
        }
        .padding(16)
        .frame(width: 360)
    }
}
