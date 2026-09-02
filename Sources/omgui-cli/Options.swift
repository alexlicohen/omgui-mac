import Foundation
import OmApi

/// Minimal hand-rolled argument parsing — the package deliberately has no external dependencies.
struct Options {
    var command: String = ""
    var useMock = false
    var deviceIds: [UInt32] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    /// Bare `key=value` arguments (record metadata).
    var pairs: [(key: String, value: String)] = []

    static let knownValueOptions: Set<String> = [
        "--device", "--workspace", "--template", "--session", "--rate", "--range", "--gyro",
        "--start", "--stop", "--delay-days", "--duration-days", "--duration-hours",
        "--duration-minutes", "--led", "--mock-root",
    ]

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        guard !arguments.isEmpty else { throw CLIError.usage("No command given") }
        options.command = arguments[0]
        index = 1

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument.hasPrefix("--") {
                var name = argument
                var inlineValue: String?
                if let equals = argument.firstIndex(of: "=") {
                    name = String(argument[argument.startIndex..<equals])
                    inlineValue = String(argument[argument.index(after: equals)...])
                }
                if knownValueOptions.contains(name) {
                    let value: String
                    if let inlineValue { value = inlineValue }
                    else if index < arguments.count { value = arguments[index]; index += 1 }
                    else { throw CLIError.usage("\(name) needs a value") }
                    if name == "--device" {
                        guard let id = UInt32(value) else { throw CLIError.usage("--device needs a numeric device id") }
                        options.deviceIds.append(id)
                    } else {
                        options.values[name] = value
                    }
                } else {
                    options.flags.insert(name)
                    if name == "--mock" { options.useMock = true }
                }
            } else if let equals = argument.firstIndex(of: "="), !argument.hasPrefix("-") {
                options.pairs.append((key: String(argument[argument.startIndex..<equals]),
                                      value: String(argument[argument.index(after: equals)...])))
            } else {
                throw CLIError.usage("Unexpected argument: \(argument)")
            }
        }
        return options
    }

    func int(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw) else { throw CLIError.usage("\(name) needs an integer, got \"\(raw)\"") }
        return value
    }

    func uint32(_ name: String) throws -> UInt32? {
        guard let raw = values[name] else { return nil }
        guard let value = UInt32(raw) else { throw CLIError.usage("\(name) needs a number 0…4294967295, got \"\(raw)\"") }
        return value
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case noDevices
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .noDevices: return "No devices found"
        case .failed(let message): return message
        }
    }

    /// 1 usage, 2 no devices, 3 operation failed.
    var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .noDevices: return 2
        case .failed: return 3
        }
    }
}
