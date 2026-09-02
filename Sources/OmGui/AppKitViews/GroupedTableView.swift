import AppKit
import OmGuiCore
import SwiftUI

/// One column of a `GroupedTableView`, mirroring a WinForms `ColumnHeader`.
struct GridColumn: Identifiable, Equatable {
    let id: String
    let title: String
    let width: CGFloat
    var alignment: NSTextAlignment = .left

    init(_ id: String, _ title: String, width: CGFloat, alignment: NSTextAlignment = .left) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

/// One cell: text, a `ListViewSubItem.ForeColor`, and optionally the device LED icon.
struct GridCell: Equatable {
    var text: String
    var color: CellColor = .normal
    /// 0…8 for the `Circle*.png` device LED icons; nil for no icon.
    var iconIndex: Int?

    init(_ text: String, color: CellColor = .normal, iconIndex: Int? = nil) {
        self.text = text
        self.color = color
        self.iconIndex = iconIndex
    }
}

struct GridRow: Identifiable, Equatable {
    let id: String
    var cells: [GridCell]
}

/// A `ListViewGroup`. An empty `title` means "no header row" (the flat file lists).
struct GridSection: Identifiable, Equatable {
    let id: String
    let title: String
    var rows: [GridRow]
}

/// The grouped, multi-select, grid-lined details list OMGUI uses for devices and files.
///
/// SwiftUI has no equivalent — `List` cannot do column headers plus grid lines plus WinForms-style
/// group rows — so this is an `NSOutlineView` in "plain" style with group items for the categories.
struct GroupedTableView: NSViewRepresentable {

    let columns: [GridColumn]
    let sections: [GridSection]
    @Binding var selection: Set<String>
    var allowsMultipleSelection = true
    var onDoubleClick: ((String) -> Void)?
    var rowHeight: CGFloat = 18

    static let groupCellIdentifier = "omgui.group"

    final class Node: NSObject {
        let id: String
        let title: String
        let row: GridRow?
        var children: [Node] = []
        var isGroup: Bool { row == nil }

        init(group id: String, title: String) {
            self.id = id
            self.title = title
            self.row = nil
        }

        init(row: GridRow) {
            self.id = row.id
            self.title = ""
            self.row = row
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: GroupedTableView
        var roots: [Node] = []
        var flatMode = false
        var applyingSelection = false
        var lastSections: [GridSection] = []

        init(_ parent: GroupedTableView) {
            self.parent = parent
        }

        func rebuild(_ sections: [GridSection]) {
            flatMode = sections.count <= 1 && (sections.first?.title.isEmpty ?? true)
            if flatMode {
                roots = (sections.first?.rows ?? []).map(Node.init(row:))
            } else {
                roots = sections.map { section in
                    let node = Node(group: section.id, title: section.title)
                    node.children = section.rows.map(Node.init(row:))
                    return node
                }
            }
            lastSections = sections
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.isGroup ?? false
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            !((item as? Node)?.isGroup ?? false)
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            parent.rowHeight
        }

        func outlineView(_ outlineView: NSOutlineView,
                         viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            // A full-width group row arrives with a nil column.
            let identifier = tableColumn?.identifier
                ?? NSUserInterfaceItemIdentifier(GroupedTableView.groupCellIdentifier)
            let cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? GridCellView
                ?? GridCellView(identifier: identifier)

            if node.isGroup {
                guard tableColumn == nil || identifier.rawValue == parent.columns.first?.id else {
                    cellView.apply(GridCell(""), alignment: .left)
                    return cellView
                }
                cellView.applyGroup(node.title)
                return cellView
            }

            guard let index = parent.columns.firstIndex(where: { $0.id == identifier.rawValue }),
                  let row = node.row, index < row.cells.count else { return cellView }
            cellView.apply(row.cells[index], alignment: parent.columns[index].alignment)
            return cellView
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection,
                  let outlineView = notification.object as? NSOutlineView else { return }
            var ids: Set<String> = []
            for index in outlineView.selectedRowIndexes {
                if let node = outlineView.item(atRow: index) as? Node, !node.isGroup {
                    ids.insert(node.id)
                }
            }
            if ids != parent.selection {
                parent.selection = ids
            }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0,
                  let node = sender.item(atRow: sender.clickedRow) as? Node,
                  !node.isGroup else { return }
            parent.onDoubleClick?(node.id)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.style = .plain
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = false
        // WinForms `GridLines = true`.
        outlineView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        outlineView.gridColor = NSColor.separatorColor
        outlineView.allowsMultipleSelection = allowsMultipleSelection
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = true       // `AllowColumnReorder = true`
        outlineView.allowsColumnResizing = true
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 0
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.selectionHighlightStyle = .regular
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = max(column.width, 1)
            tableColumn.minWidth = 1
            tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
            // OMGUI hides "File Location" by giving it width 0.
            tableColumn.isHidden = column.width == 0
            outlineView.addTableColumn(tableColumn)
        }
        if let first = outlineView.tableColumns.first {
            outlineView.outlineTableColumn = first
        }

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.parent = self

        if context.coordinator.lastSections != sections {
            context.coordinator.rebuild(sections)
            outlineView.reloadData()
            if !context.coordinator.flatMode {
                for node in context.coordinator.roots { outlineView.expandItem(node) }
            }
        }

        // Push the model's selection back into the view when they differ.
        var indexes = IndexSet()
        for index in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: index) as? Node, !node.isGroup,
               selection.contains(node.id) {
                indexes.insert(index)
            }
        }
        var current: Set<String> = []
        for index in outlineView.selectedRowIndexes {
            if let node = outlineView.item(atRow: index) as? Node { current.insert(node.id) }
        }
        if current != selection {
            context.coordinator.applyingSelection = true
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
            context.coordinator.applyingSelection = false
        }
    }
}

/// A cell: an optional LED circle plus a label.
final class GridCellView: NSTableCellView {

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown

        addSubview(icon)
        addSubview(label)
        self.textField = label

        iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.heightAnchor.constraint(equalToConstant: 10),
            iconWidth,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var iconWidth: NSLayoutConstraint!

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ cell: GridCell, alignment: NSTextAlignment) {
        label.stringValue = cell.text
        label.alignment = alignment
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = GridCellView.color(for: cell.color)
        if let index = cell.iconIndex {
            icon.image = LedCircle.image(index: index)
            iconWidth.constant = 10
        } else {
            icon.image = nil
            iconWidth.constant = 0
        }
    }

    func applyGroup(_ title: String) {
        label.stringValue = title
        label.alignment = .left
        label.font = NSFont.boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        icon.image = nil
        iconWidth.constant = 0
    }

    static func color(for color: CellColor) -> NSColor {
        switch color {
        case .normal: return .labelColor
        // WinForms `Color.Red` / `Color.Orange` / `Color.Green`, darkened just enough to stay
        // legible on a dark-mode background.
        case .red: return NSColor(calibratedRed: 0.85, green: 0.14, blue: 0.14, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.05, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.15, alpha: 1)
        }
    }
}

/// The `Circle0.png`…`Circle7.png` / `Circle.png` device LED icons, drawn rather than shipped.
enum LedCircle {

    /// `OM_LED_STATE` 0…7, then 8 for "unknown".
    static let colors: [NSColor] = [
        NSColor(calibratedWhite: 0.25, alpha: 1),                         // 0 off
        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.95, alpha: 1),  // 1 blue
        NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.20, alpha: 1),  // 2 green
        NSColor(calibratedRed: 0.10, green: 0.80, blue: 0.85, alpha: 1),  // 3 cyan
        NSColor(calibratedRed: 0.90, green: 0.12, blue: 0.12, alpha: 1),  // 4 red
        NSColor(calibratedRed: 0.90, green: 0.15, blue: 0.85, alpha: 1),  // 5 magenta
        NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.10, alpha: 1),  // 6 yellow
        NSColor(calibratedWhite: 0.98, alpha: 1),                         // 7 white
        NSColor(calibratedWhite: 0.65, alpha: 1),                         // 8 unknown
    ]

    private nonisolated(unsafe) static var cache: [Int: NSImage] = [:]

    static func image(index: Int) -> NSImage {
        let clamped = (0...8).contains(index) ? index : 8
        if let cached = cache[clamped] { return cached }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            colors[clamped].setFill()
            path.fill()
            NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            return true
        }
        cache[clamped] = image
        return image
    }
}
