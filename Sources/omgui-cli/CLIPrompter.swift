import Foundation
import OmApi
import OmGuiCore

/// The flows' `UserPrompting`, for a program with no message boxes.
///
/// Warnings go to stderr. A question is answered "yes" only when the operator said so up front
/// (`--yes`, or `--force` where that is the documented override) or answers it on a terminal: a CLI
/// run from a site script has no one to ask, and the questions the flows put up are all of the form
/// "this may cost you a recording -- carry on?".
@MainActor
final class CLIPrompter: UserPrompting {

    let assumeYes: Bool
    private(set) var warnings: [String] = []
    private(set) var questions: [String] = []

    init(assumeYes: Bool) {
        self.assumeYes = assumeYes
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func oneLine(_ message: String) -> String {
        message.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "    ", with: " ")
    }

    func warn(title: String, message: String) {
        warnings.append(message)
        CLIPrompter.write("WARNING [\(title)] \(CLIPrompter.oneLine(message))\n")
    }

    func confirm(title: String, message: String) -> Bool {
        questions.append(message)
        CLIPrompter.write("[\(title)] \(CLIPrompter.oneLine(message))\n")
        if assumeYes {
            CLIPrompter.write("  -> continuing (--yes)\n")
            return true
        }
        guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
            CLIPrompter.write("  -> refused (no terminal to ask on; pass --yes to continue)\n")
            return false
        }
        CLIPrompter.write("  Continue? [y/N] ")
        let answer = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// The damaged-device question. There is no "retry" worth offering without a dialog, and
    /// continuing silently is the one answer a CLI must not give itself.
    func abortRetryIgnore(title: String, message: String) -> AbortRetryIgnore {
        confirm(title: title, message: message) ? .ignore : .abort
    }
}
