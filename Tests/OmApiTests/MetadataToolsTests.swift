import XCTest
@testable import OmApi

/// Expected strings were derived by hand-tracing `MetaDataTools.cs` (UrlEncode/UrlDecode/
/// CreateMetaData/ParseMetaData), not by running this implementation.
final class MetadataToolsTests: XCTestCase {

    // MARK: - URL encoding

    func testUrlEncodeRules() {
        // Unreserved set is exactly A-Z a-z 0-9 ~ _ . -
        XCTAssertEqual(MetadataTools.urlEncode("AZaz09~_.-"), "AZaz09~_.-")
        // Space becomes '+', not %20.
        XCTAssertEqual(MetadataTools.urlEncode("left wrist"), "left+wrist")
        // '&' and '=' must be escaped or they would break the pair syntax.
        XCTAssertEqual(MetadataTools.urlEncode("R&D"), "R%26D")
        XCTAssertEqual(MetadataTools.urlEncode("a=b"), "a%3Db")
        // '+' itself is escaped so it round-trips as a plus and not as a space.
        XCTAssertEqual(MetadataTools.urlEncode("+"), "%2B")
        // Apostrophe is not in the unreserved set.
        XCTAssertEqual(MetadataTools.urlEncode("Children's"), "Children%27s")
        // UTF-8, upper-case hex: U+00FC is C3 BC.
        XCTAssertEqual(MetadataTools.urlEncode("Müller"), "M%C3%BCller")
        // Multi-byte beyond Latin-1: U+00E9 is C3 A9; U+4E2D is E4 B8 AD.
        XCTAssertEqual(MetadataTools.urlEncode("é"), "%C3%A9")
        XCTAssertEqual(MetadataTools.urlEncode("中"), "%E4%B8%AD")
    }

    func testUrlDecodeRules() {
        XCTAssertEqual(MetadataTools.urlDecode("left+wrist"), "left wrist")
        XCTAssertEqual(MetadataTools.urlDecode("R%26D"), "R&D")
        XCTAssertEqual(MetadataTools.urlDecode("M%C3%BCller"), "Müller")
        XCTAssertEqual(MetadataTools.urlDecode("%2B"), "+")
        // Lower-case hex is accepted on decode.
        XCTAssertEqual(MetadataTools.urlDecode("M%c3%bcller"), "Müller")
        // A truncated escape is left alone (upstream needs both hex digits present).
        XCTAssertEqual(MetadataTools.urlDecode("a%4"), "a%4")
        XCTAssertEqual(MetadataTools.urlDecode("a%"), "a%")
        // Non-hex after '%' is literal.
        XCTAssertEqual(MetadataTools.urlDecode("a%zz"), "a%zz")
    }

    func testUrlEncodeDecodeRoundTrip() {
        for value in ["", "plain", "with space", "R&D", "a=b&c=d", "Ann Müller", "中文 test", "100%", "+plus+"] {
            XCTAssertEqual(MetadataTools.urlDecode(MetadataTools.urlEncode(value)), value, "round trip of \"\(value)\"")
        }
    }

    // MARK: - Pair list

    func testCreateMetaDataHandTracedVector() {
        var metadata = StudyMetadata()
        metadata.studyCentre = "Example Children's Hospital"   // apostrophe -> %27, space -> '+'
        metadata.studyCode = "R&D"                   // '&' -> %26
        metadata.subjectSite = "left wrist"          // space -> '+'
        metadata.subjectCode = "Ann Müller"          // UTF-8 -> %C3%BC
        // Everything else stays empty and must be omitted (built-in '_' keys).

        XCTAssertEqual(metadata.encoded,
                       "_c=Example+Children%27s+Hospital&_s=R%26D&_p=left+wrist&_sc=Ann+M%C3%BCller")
    }

    func testWhitespaceOnlyBuiltInValueIsOmitted() {
        var metadata = StudyMetadata()
        metadata.studyCode = "   "
        metadata.subjectCode = "X"
        XCTAssertEqual(metadata.encoded, "_sc=X")
    }

    func testCustomKeyWithEmptyValueIsKept() {
        // Upstream only drops a *built-in* ('_'-prefixed) key when its value is blank.
        XCTAssertEqual(MetadataTools.create([.init("site", "")]), "site=")
        XCTAssertEqual(MetadataTools.create([.init("_x", "")]), "")
    }

    func testEncodedOrderMatchesOMGUI() {
        var metadata = StudyMetadata()
        metadata.subjectNotes = "z"
        metadata.studyCentre = "a"
        metadata.subjectSite = "m"
        // DateRangeForm adds _c ... _n then _p, _sc ... _sn, so _c precedes _p precedes _sn.
        XCTAssertEqual(metadata.encoded, "_c=a&_p=m&_sn=z")
    }

    func testParseSeedsBasicSetAndDecodes() {
        let map = MetadataTools.parse("_c=Example+Children%27s+Hospital&_s=R%26D&_p=left+wrist&_sc=Ann+M%C3%BCller")
        XCTAssertEqual(map["_c"], "Example Children's Hospital")
        XCTAssertEqual(map["_s"], "R&D")
        XCTAssertEqual(map["_p"], "left wrist")
        XCTAssertEqual(map["_sc"], "Ann Müller")
        // Untouched built-in keys are still present, empty.
        XCTAssertEqual(map["_i"], "")
        XCTAssertEqual(map["_sn"], "")
        XCTAssertEqual(map.count, MetadataTools.entryKeys.count)
    }

    func testParseTreatsPaddingAsWhitespace() {
        // 0xFF padding (a never-written annotation block) and control characters become spaces,
        // then the whole string is trimmed.
        let padded = "_s=ABC" + String(repeating: "\u{00FF}", count: 10)
        XCTAssertEqual(MetadataTools.parse(padded)["_s"], "ABC")
        XCTAssertEqual(MetadataTools.parse("\u{0001}_s=ABC\u{0002}")["_s"], "ABC")
    }

    func testParsePairWithNoEqualsGivesEmptyValue() {
        let map = MetadataTools.parse("_s")
        XCTAssertEqual(map["_s"], "")
    }

    func testParseValueContainingEncodedEquals() {
        // Only the first '=' splits; an encoded one survives into the value.
        let map = MetadataTools.parse("_n=a%3Db")
        XCTAssertEqual(map["_n"], "a=b")
    }

    func testStudyMetadataRoundTrip() {
        var original = StudyMetadata()
        original.studyCentre = "Centre One"
        original.studyCode = "S&C"
        original.studyInvestigator = "Dr Müller"
        original.studyExerciseType = "free living"
        original.studyOperator = "op1"
        original.studyNotes = "note, with punctuation!"
        original.subjectSite = "left wrist"
        original.subjectCode = "P001"
        original.subjectSex = "female"
        original.subjectHeight = "170"
        original.subjectWeight = "65"
        original.subjectHandedness = "right"
        original.subjectNotes = "n/a"

        let decoded = StudyMetadata(decoding: original.encoded)
        XCTAssertEqual(decoded, original)
    }

    func testSetAcceptsShortAndDisplayNames() {
        var metadata = StudyMetadata()
        XCTAssertTrue(metadata.set("_sc", "short"))
        XCTAssertEqual(metadata.subjectCode, "short")
        XCTAssertTrue(metadata.set("SubjectCode", "display"))
        XCTAssertEqual(metadata.subjectCode, "display")
        XCTAssertTrue(metadata.set("custom", "value"))
        XCTAssertEqual(metadata.custom, [MetadataEntry("custom", "value")])
        XCTAssertFalse(metadata.set("", "x"))
    }

    // MARK: - Annotation block

    func testAnnotationBlockGeometry() {
        XCTAssertEqual(MetadataTools.annotationOffset, 64)
        XCTAssertEqual(MetadataTools.annotationSegmentCount, 14)
        XCTAssertEqual(MetadataTools.annotationSegmentLength, 32)
        XCTAssertEqual(MetadataTools.annotationTotalLength, 448)
    }

    func testAnnotationBlockIsSpacePadded() {
        let block = MetadataTools.annotationBlock(from: "_s=ABC")
        XCTAssertEqual(block.count, 448)
        XCTAssertEqual(Array(block.prefix(6)), Array("_s=ABC".utf8))
        XCTAssertTrue(block.dropFirst(6).allSatisfy { $0 == 0x20 })
    }

    func testAnnotationBlockTruncatesOverlongMetadata() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(MetadataTools.annotationBlock(from: long).count, 448)
    }

    func testAnnotationSegments() {
        let segments = MetadataTools.annotationSegments(from: "_s=ABC")
        XCTAssertEqual(segments.count, 14)
        XCTAssertTrue(segments.allSatisfy { $0.count == 32 })
        XCTAssertEqual(segments[0], "_s=ABC" + String(repeating: " ", count: 26))
        XCTAssertEqual(segments[13], String(repeating: " ", count: 32))
    }

    func testMetadataFromAnnotationStripsPadding() {
        var block = MetadataTools.annotationBlock(from: "_s=ABC")
        XCTAssertEqual(MetadataTools.metadata(fromAnnotation: block), "_s=ABC")
        // A never-written block is 0xFF filled.
        block = [UInt8](repeating: 0xFF, count: 448)
        XCTAssertEqual(MetadataTools.metadata(fromAnnotation: block), "")
    }
}
