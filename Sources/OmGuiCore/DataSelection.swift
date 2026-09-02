import Foundation
import OmApi

/// Turns the data viewer's selected time slice into the block numbers OMGUI passes around.
///
/// `MainForm.ExportDataConstruct` reads `dataViewer.SelectionBeginBlock + dataViewer.OffsetBlocks`
/// and `SelectionEndBlock - SelectionBeginBlock`. The Mac data viewer publishes the selection as a
/// date range, so the blocks are recovered from the file's own data range: a `.CWA` stores its
/// samples in fixed-size sectors laid down at a constant rate, so block number is linear in time
/// between `OmReaderDataRange`'s start and end.
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

    /// The block range for a time slice of an open reader.
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
    public static func blocks(for range: ClosedRange<Date>, path: String) -> Blocks? {
        guard let reader = try? OmReader(path: path) else { return nil }
        defer { reader.close() }
        guard let start = reader.startTime.date(in: .gmt),
              let end = reader.endTime.date(in: .gmt) else { return nil }
        return blocks(for: range, start: start, end: end,
                      offsetBlocks: reader.dataOffsetBlocks, numBlocks: reader.dataNumBlocks)
    }

    /// `dataViewer.SelectionDescription` — the label `ExportForm` shows above the block boxes.
    public static func description(for range: ClosedRange<Date>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: range.lowerBound) + " - " + formatter.string(from: range.upperBound)
    }
}
