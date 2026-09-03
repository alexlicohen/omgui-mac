import Foundation
import OmApi

/// Turns the data viewer's selected time slice into the block numbers OMGUI passes around.
///
/// `MainForm.ExportDataConstruct` reads `dataViewer.SelectionBeginBlock + dataViewer.OffsetBlocks`
/// and `SelectionEndBlock - SelectionBeginBlock`. The Mac data viewer publishes the selection as a
/// date range, so the blocks are recovered from the file itself — by reading the blocks' own
/// timestamps, not by assuming a constant block rate across the recording.
///
/// `blockStart` is absolute in the file (it includes the two header sectors), which is what
/// `cwa-convert -blockstart` counts and what upstream's `+ OffsetBlocks` produces.
public enum DataSelection {

    public struct Blocks: Sendable, Equatable {
        public var start: Double
        public var count: Double
        public init(start: Double, count: Double) {
            self.start = start
            self.count = count
        }
    }

    /// The block range for a time slice, estimated from the file's own data range.
    ///
    /// Linear in time between the first and last block, which is only true of a recording laid
    /// down at a constant rate: this is the fallback for a file whose blocks will not seek. The
    /// timestamp-driven path below is what the app uses.
    public static func blocks(for range: ClosedRange<Date>,
                              start: Date,
                              end: Date,
                              offsetBlocks: Int,
                              numBlocks: Int) -> Blocks? {
        let span = end.timeIntervalSince(start)
        guard span > 0, numBlocks > 0 else { return nil }
        func block(_ date: Date) -> Double {
            let fraction = date.timeIntervalSince(start) / span
            return min(max(fraction, 0), 1) * Double(numBlocks)
        }
        let first = block(range.lowerBound)
        let last = block(range.upperBound)
        guard last > first else { return nil }
        return Blocks(start: first + Double(offsetBlocks), count: last - first)
    }

    /// The same, reading the range straight out of the file.
    ///
    /// Each edge of the selection is resolved by bisecting the file's data blocks on their own
    /// timestamps (`refs/10-deep-review.md` C42): a recording with a battery gap in it is *not*
    /// laid down at a constant rate, and interpolating between the first and last block shifts
    /// `-blockstart` by the whole gap, so the exported CSV covers a different window than the one
    /// the user highlighted. A file whose blocks will not seek falls back to the estimate above.
    public static func blocks(for range: ClosedRange<Date>, path: String) -> Blocks? {
        guard let reader = try? OmReader(path: path) else { return nil }
        defer { reader.close() }
        return blocks(for: range, reader: reader)
    }

    static func blocks(for range: ClosedRange<Date>, reader: OmReader) -> Blocks? {
        let numBlocks = reader.dataNumBlocks
        guard numBlocks > 0 else { return nil }
        var seeker = BlockSeeker(reader: reader, count: numBlocks)
        guard let first = seeker.position(of: range.lowerBound.timeIntervalSince1970),
              let last = seeker.position(of: range.upperBound.timeIntervalSince1970) else {
            guard let start = reader.startTime.date(in: .gmt),
                  let end = reader.endTime.date(in: .gmt) else { return nil }
            return blocks(for: range, start: start, end: end,
                          offsetBlocks: reader.dataOffsetBlocks, numBlocks: numBlocks)
        }
        guard last > first else { return nil }
        return Blocks(start: first + Double(reader.dataOffsetBlocks), count: last - first)
    }

    /// A bisection over the data blocks' timestamps.
    ///
    /// One probe is a seek plus a block-header read (no sample decode), so an edge costs
    /// `log2(blocks)` reads — 19 for a week of 100 Hz data. Probes are cached because the two
    /// edges of a selection walk overlapping paths.
    struct BlockSeeker {
        let reader: OmReader
        let count: Int
        private var cache: [Int: OmReader.BlockSummary] = [:]

        init(reader: OmReader, count: Int) {
            self.reader = reader
            self.count = count
        }

        /// The block at `index`, or the first readable one after it — `nextSummary` skips sectors
        /// the parser rejects, so what comes back may be a later block than the one asked for.
        mutating func summary(at index: Int) -> OmReader.BlockSummary? {
            if let hit = cache[index] { return hit }
            guard index >= 0, index < count, reader.seek(toBlock: index) else { return nil }
            guard let summary = reader.nextSummary(), summary.start > 0 else { return nil }
            cache[index] = summary
            cache[summary.index] = summary
            return summary
        }

        /// The last readable block, tolerating a handful of unreadable trailing sectors.
        mutating func lastSummary() -> OmReader.BlockSummary? {
            var index = count - 1
            var attempts = 0
            while index >= 0, attempts < 8 {
                if let summary = summary(at: index) { return summary }
                index -= 1
                attempts += 1
            }
            return nil
        }

        /// Fractional block position of `time`: the index of the block covering it, plus how far
        /// into that block it falls. Clamped to `0...count`, `nil` when the file will not seek.
        mutating func position(of time: Double) -> Double? {
            guard let first = summary(at: 0) else { return nil }
            if time <= first.start { return 0 }
            guard let last = lastSummary() else { return nil }
            if time >= last.end { return Double(count) }

            // The last block that starts at or before `time`.
            var low = 0
            var high = count - 1
            var best = first
            while low <= high {
                let mid = low + (high - low) / 2
                guard let probe = summary(at: mid) else {
                    high = mid - 1
                    continue
                }
                if probe.start <= time {
                    best = probe
                    low = probe.index + 1
                } else {
                    high = mid - 1
                }
            }
            let span = best.end - best.start
            let fraction = span > 0 ? min(max((time - best.start) / span, 0), 1) : 0
            return min(Double(count), Double(best.index) + fraction)
        }
    }

    /// `dataViewer.SelectionDescription` — the label `ExportForm` shows above the block boxes.
    ///
    /// Formatted in UTC, because that is the clock the plot draws and the one the `.CWA` stores:
    /// libomapi reads the device's wall-clock stamps with `timegm`, so a recording made at 10:00
    /// local reads back as 10:00 UTC. Formatting the same instant in the machine's own zone would
    /// print a time four hours from the one the user dragged over while `-blockstart` (which does
    /// use UTC) exported the right window — see `refs/10-deep-review.md` C21.
    public static func description(for range: ClosedRange<Date>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: range.lowerBound) + " - " + formatter.string(from: range.upperBound)
    }
}
