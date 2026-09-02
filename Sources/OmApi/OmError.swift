import Foundation

/// A failure returned by the Open Movement API.
///
/// Mirrors the `OM_E_*` return codes in `omapi.h`. Kept as a struct rather than an enum so an
/// unrecognised code from a future libomapi still round-trips instead of trapping.
public struct OmError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let code: Int32
    /// Name of the operation that failed, for diagnostics (e.g. `"OmSetSessionId"`).
    public let operation: String?

    public init(code: Int32, operation: String? = nil) {
        self.code = code
        self.operation = operation
    }

    public static let fail = OmError(code: -1)
    public static let unexpected = OmError(code: -2)
    public static let notValidState = OmError(code: -3)
    public static let outOfMemory = OmError(code: -4)
    public static let invalidArg = OmError(code: -5)
    public static let pointer = OmError(code: -6)
    public static let notImplemented = OmError(code: -7)
    public static let abort = OmError(code: -8)
    public static let accessDenied = OmError(code: -9)
    public static let invalidDevice = OmError(code: -10)
    public static let unexpectedResponse = OmError(code: -11)
    public static let locked = OmError(code: -12)

    /// Compares the code only, so `OmError(code: -5, operation: "x") == .invalidArg`.
    public static func == (lhs: OmError, rhs: OmError) -> Bool { lhs.code == rhs.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    /// The message text used by `OmErrorString()` in `omapi-main.c`.
    public var message: String {
        switch code {
        case 0: return "Success"
        case -1: return "Unspecified failure"
        case -2: return "Unexpected error"
        case -3: return "API not in a valid state"
        case -4: return "Out of memory"
        case -5: return "Invalid argument"
        case -6: return "Invalid pointer"
        case -7: return "Not implemented"
        case -8: return "Operation aborted"
        case -9: return "Access denied"
        case -10: return "Invalid device identifier"
        case -11: return "Unexpected device response"
        case -12: return "Device is locked"
        default: return "Unknown error \(code)"
        }
    }

    public var description: String {
        if let operation { return "\(operation): \(message) (\(code))" }
        return "\(message) (\(code))"
    }
}

/// Raised for problems that are not libomapi return codes (bad arguments, missing files, ...).
public struct OmApiError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// `OM_SUCCEEDED` / `OM_FAILED` from `omapi.h`: any non-negative value is success.
@inlinable public func omSucceeded(_ status: Int32) -> Bool { status >= 0 }
@inlinable public func omFailed(_ status: Int32) -> Bool { status < 0 }

/// Throws `OmError` for a negative status, otherwise returns it (some calls return a count).
@discardableResult
public func omCheck(_ status: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
    guard status >= 0 else { throw OmError(code: status, operation: operation()) }
    return status
}
