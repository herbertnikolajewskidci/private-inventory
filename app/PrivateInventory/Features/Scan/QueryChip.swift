import Foundation

/// One selectable chip of the OCR query editor (ticket #26, D1b):
/// a recognized OCR line or a user-added free-text term. The search
/// query is the concatenation of the SELECTED chips (single source
/// of truth, D1b/D4b).
struct QueryChip: Identifiable, Equatable {
    /// Stable identity for selection toggling.
    let id: UUID
    /// The chip text (an OCR line or a user-typed term).
    let text: String
    /// True for a chip the user typed themselves (D4b); rendered
    /// with a pencil icon to distinguish it from OCR lines.
    let isCustom: Bool

    init(id: UUID = UUID(), text: String, isCustom: Bool = false) {
        self.id = id
        self.text = text
        self.isCustom = isCustom
    }
}
