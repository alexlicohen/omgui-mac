import OmGuiCore
import SwiftUI

/// `propertyGridDevice` / `propertyGridFile` — a category-grouped, read-only name/value grid.
///
/// `ToolbarVisible = false` in the designer, so there is no sort/category bar; the header row is
/// kept because the AppKit grid needs one to show column separators.
struct PropertyGridView: View {

    let title: String
    let rows: [PropertyRow]
    @State private var selection: Set<String> = []

    private static let columns = [
        GridColumn("name", "Property", width: 140),
        GridColumn("value", "Value", width: 200),
    ]

    var body: some View {
        GroupedTableView(columns: PropertyGridView.columns,
                         sections: sections,
                         selection: $selection,
                         allowsMultipleSelection: false)
            .accessibilityIdentifier("PropertyGrid.\(title)")
    }

    private var sections: [GridSection] {
        var order: [String] = []
        var grouped: [String: [PropertyRow]] = [:]
        for row in rows {
            if grouped[row.category] == nil { order.append(row.category) }
            grouped[row.category, default: []].append(row)
        }
        return order.map { category in
            GridSection(id: category, title: category, rows: (grouped[category] ?? []).map {
                GridRow(id: $0.id, cells: [GridCell($0.name), GridCell($0.value)])
            })
        }
    }
}
