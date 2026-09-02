import Foundation

/// Port of OMGUI's `MetaDataTools.cs`.
///
/// Metadata is `key=value` pairs joined by `&`, each side URL-encoded, stored in the CWA header's
/// 448-byte annotation block at offset 64 (14 segments x 32 bytes, space padded) and written to a
/// device with `OmSetMetadata` / `ANNOTATE00..13`.
public enum MetadataTools {

    // MARK: - Annotation block geometry (MetaDataTools.cs)

    public static let annotationOffset = 64
    public static let annotationSegmentCount = 14
    public static let annotationSegmentLength = 32
    /// `OM_METADATA_SIZE` — 448.
    public static let annotationTotalLength = annotationSegmentCount * annotationSegmentLength
    public static let annotationPadding: UInt8 = 0x20

    // MARK: - Keys

    /// The built-in keys, in the order `DateRangeForm.cs` adds them (this order is what ends up
    /// in the encoded string, so it is load-bearing).
    public static let entryKeys = ["_c", "_s", "_i", "_x", "_so", "_n",
                                  "_p", "_sc", "_se", "_h", "_w", "_ha", "_sn"]

    /// `MetaDataTools.metaDataMappingDictionary`.
    public static let keyToName: [String: String] = [
        "_c": "StudyCentre",
        "_s": "StudyCode",
        "_i": "StudyInvestigator",
        "_x": "StudyExerciseType",
        "_so": "StudyOperator",
        "_n": "StudyNotes",
        "_p": "SubjectSite",
        "_sc": "SubjectCode",
        "_se": "SubjectSex",
        "_h": "SubjectHeight",
        "_w": "SubjectWeight",
        "_ha": "SubjectHandedness",
        "_sn": "SubjectNotes",
    ]

    public static let nameToKey: [String: String] =
        Dictionary(uniqueKeysWithValues: keyToName.map { ($0.value, $0.key) })

    /// `DateRangeForm` site list (index 0 is the blank entry).
    public static let subjectSites = ["", "left wrist", "right wrist", "waist", "left ankle",
                                     "right ankle", "left thigh", "right thigh", "left hip",
                                     "right hip", "left upper-arm", "right upper-arm", "chest",
                                     "sacrum", "neck", "head"]
    public static let subjectSexes = ["", "male", "female"]
    public static let subjectHandednesses = ["", "left", "right"]

    // MARK: - URL encoding

    /// `MetaDataTools.UrlEncode`: UTF-8 bytes; space becomes `+`; `A-Za-z0-9~_.-` pass through;
    /// everything else becomes `%XX` with upper-case hex.
    public static func urlEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in Array(s.utf8) {
            switch b {
            case 0x20:
                out.append("+")
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "~"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
                out.append(Character(UnicodeScalar(b)))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// `MetaDataTools.UrlDecode`. Upstream truncates each `char` to a byte before testing, so this
    /// operates on the low byte of each unit; the encoded form is always ASCII in practice.
    public static func urlDecode(_ s: String) -> String {
        let chars = s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "+") {
                buffer.append(0x20)
            } else if c == UInt8(ascii: "%"), i + 2 < chars.count,
                      let h = hexValue(chars[i + 1]), let l = hexValue(chars[i + 2]) {
                buffer.append((h << 4) | l)
                i += 2
            } else {
                buffer.append(c)
            }
            i += 1
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - Encode / decode the pair list

    /// `MetaDataTools.CreateMetaData(IList<MetaDataEntry>)`.
    ///
    /// A built-in (`_`-prefixed) key whose value is empty or whitespace is omitted entirely; any
    /// other pair is emitted when either side has non-whitespace content.
    public static func create(_ entries: [MetadataEntry]) -> String {
        var out = ""
        for entry in entries {
            let trimmedValue = entry.value.trimmingCharacters(in: .whitespaces)
            if entry.key.hasPrefix("_") && trimmedValue.isEmpty { continue }
            if entry.key.trimmingCharacters(in: .whitespaces).isEmpty && trimmedValue.isEmpty { continue }
            if !out.isEmpty { out += "&" }
            out += urlEncode(entry.key) + "=" + urlEncode(entry.value)
        }
        return out
    }

    /// `MetaDataTools.ParseMetaData`.
    ///
    /// Control characters and anything at or above U+00FF are replaced with a space first (that is
    /// how the 0xFF padding of a never-written annotation block disappears), then the whole string
    /// is trimmed before splitting.
    public static func parse(_ source: String?, basicSet: [String] = entryKeys) -> [String: String] {
        var result: [String: String] = [:]
        for key in basicSet { result[key] = "" }
        guard var text = source else { return result }

        text = String(String.UnicodeScalarView(text.unicodeScalars.map {
            ($0.value < 0x20 || $0.value >= 0xFF) ? UnicodeScalar(0x20)! : $0
        }))
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return result }

        for pair in text.components(separatedBy: "&") {
            let name: String
            let value: String
            if let eq = pair.firstIndex(of: "=") {
                name = String(pair[pair.startIndex..<eq])
                value = String(pair[pair.index(after: eq)...])
            } else {
                name = pair
                value = ""
            }
            let decodedName = urlDecode(name)
            let decodedValue = urlDecode(value)
            if !decodedName.trimmingCharacters(in: .whitespaces).isEmpty
                || !decodedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                result[decodedName] = decodedValue
            }
        }
        return result
    }

    /// Parse, then rename known `_`-keys to their OMGUI display names (`MetadataFromFile`).
    /// Unknown keys keep their raw name.
    public static func namedMap(_ source: String?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in parse(source) {
            out[keyToName[key] ?? key] = value
        }
        return out
    }

    // MARK: - Annotation block

    /// The 448 bytes to store at header offset 64: truncated if too long, space padded if short.
    public static func annotationBlock(from metadata: String) -> [UInt8] {
        var bytes = Array(metadata.utf8)
        if bytes.count > annotationTotalLength { bytes = Array(bytes.prefix(annotationTotalLength)) }
        bytes.append(contentsOf: repeatElement(annotationPadding, count: annotationTotalLength - bytes.count))
        return bytes
    }

    /// The 14 x 32-character `ANNOTATEnn=` payloads, in order.
    public static func annotationSegments(from metadata: String) -> [String] {
        let block = annotationBlock(from: metadata)
        return (0..<annotationSegmentCount).map { i in
            let slice = block[(i * annotationSegmentLength)..<((i + 1) * annotationSegmentLength)]
            // OmSetMetadata replaces control characters with '|' on the wire.
            return String(decoding: slice.map { $0 < 0x20 ? UInt8(ascii: "|") : $0 }, as: UTF8.self)
        }
    }

    /// Recover the metadata string from a raw annotation block, dropping the 0x20/0x00/0xFF
    /// padding that a device or a freshly formatted file leaves behind.
    public static func metadata(fromAnnotation bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x00 || bytes[end - 1] == 0xFF {
            end -= 1
        }
        let scalars = bytes[0..<end].map { UnicodeScalar($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// One `key=value` metadata pair (upstream `MetaDataEntry.cs`).
public struct MetadataEntry: Hashable, Sendable {
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

/// The Study/Subject fields of OMGUI's Recording Settings dialog.
public struct StudyMetadata: Hashable, Sendable {
    public var studyCentre = ""
    public var studyCode = ""
    public var studyInvestigator = ""
    public var studyExerciseType = ""
    public var studyOperator = ""
    public var studyNotes = ""
    public var subjectSite = ""
    public var subjectCode = ""
    public var subjectSex = ""
    public var subjectHeight = ""
    public var subjectWeight = ""
    public var subjectHandedness = ""
    public var subjectNotes = ""
    /// Extra `key=value` pairs beyond the built-in set, kept in insertion order.
    public var custom: [MetadataEntry] = []

    public init() {}

    /// The entries in OMGUI's order, ready for `MetadataTools.create`.
    public var entries: [MetadataEntry] {
        var list: [MetadataEntry] = [
            .init("_c", studyCentre), .init("_s", studyCode), .init("_i", studyInvestigator),
            .init("_x", studyExerciseType), .init("_so", studyOperator), .init("_n", studyNotes),
            .init("_p", subjectSite), .init("_sc", subjectCode), .init("_se", subjectSex),
            .init("_h", subjectHeight), .init("_w", subjectWeight), .init("_ha", subjectHandedness),
            .init("_sn", subjectNotes),
        ]
        list.append(contentsOf: custom)
        return list
    }

    public var encoded: String { MetadataTools.create(entries) }

    public init(decoding metadata: String?) {
        let map = MetadataTools.parse(metadata)
        studyCentre = map["_c"] ?? ""
        studyCode = map["_s"] ?? ""
        studyInvestigator = map["_i"] ?? ""
        studyExerciseType = map["_x"] ?? ""
        studyOperator = map["_so"] ?? ""
        studyNotes = map["_n"] ?? ""
        subjectSite = map["_p"] ?? ""
        subjectCode = map["_sc"] ?? ""
        subjectSex = map["_se"] ?? ""
        subjectHeight = map["_h"] ?? ""
        subjectWeight = map["_w"] ?? ""
        subjectHandedness = map["_ha"] ?? ""
        subjectNotes = map["_sn"] ?? ""
        custom = map.filter { !MetadataTools.entryKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { MetadataEntry($0.key, $0.value) }
    }

    /// Set a field by built-in key (`_sc`) or display name (`SubjectCode`); unknown keys become
    /// custom entries. Returns false only for an empty key.
    @discardableResult
    public mutating func set(_ key: String, _ value: String) -> Bool {
        guard !key.isEmpty else { return false }
        let normalised = MetadataTools.nameToKey[key] ?? key
        switch normalised {
        case "_c": studyCentre = value
        case "_s": studyCode = value
        case "_i": studyInvestigator = value
        case "_x": studyExerciseType = value
        case "_so": studyOperator = value
        case "_n": studyNotes = value
        case "_p": subjectSite = value
        case "_sc": subjectCode = value
        case "_se": subjectSex = value
        case "_h": subjectHeight = value
        case "_w": subjectWeight = value
        case "_ha": subjectHandedness = value
        case "_sn": subjectNotes = value
        default:
            if let i = custom.firstIndex(where: { $0.key == normalised }) { custom[i].value = value }
            else { custom.append(MetadataEntry(normalised, value)) }
        }
        return true
    }
}
