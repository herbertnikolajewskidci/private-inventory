import SwiftUI

/// Wrapping row layout for the OCR query chips (ticket #26, D1b):
/// chips flow left to right and wrap to the next row, like text.
/// Pure SwiftUI `Layout` protocol (single-target app, iOS 26,
/// ADR-0007).
struct FlowLayout: Layout {
    /// Gap between chips, horizontally and vertically.
    var spacing: CGFloat = 8

    /// One wrapped row: its subviews plus measured dimensions.
    private struct Row {
        var subviews: [LayoutSubview] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !row.subviews.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.subviews.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.subviews.append(subview)
        }
        if !row.subviews.isEmpty {
            rows.append(row)
        }
        return rows
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let rows = rows(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let rows = rows(proposal: proposal, subviews: subviews)
        var cursorY = bounds.minY
        for row in rows {
            var cursorX = bounds.minX
            for subview in row.subviews {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(
                        x: cursorX,
                        y: cursorY + (row.height - size.height) / 2
                    ),
                    proposal: .unspecified
                )
                cursorX += size.width + spacing
            }
            cursorY += row.height + spacing
        }
    }
}
