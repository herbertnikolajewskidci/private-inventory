import Foundation

/// Parses the TOON tables the dm MCP server embeds in tool results
/// (Token-Oriented Object Notation, research doc section 4.5):
///
/// ```text
/// [1]{dan|gtin|productName|brand|found|...}:
///   1569035|4066447966008|Shampoo Ultra Sensitive, 250 ml|Balea med|true|...
/// ```
///
/// Columns are separated by pipes. Values may be wrapped in double
/// quotes (URLs, long texts); inside a quoted value, `\"` and `\\`
/// are escape sequences. Unquoted array values may contain raw quotes
/// (e.g. `keyBenefits`), so quote tracking is per-character, not per
/// field.
enum DmToonParser {
    /// One TOON table row as column name → value.
    typealias Record = [String: String]

    /// Parses the TOON table and returns the row for `gtin` (or the
    /// only row when the table has a single row).
    ///
    /// - Throws: `CatalogError.parse` when the table has no header,
    ///   no data row, or no row matching the requested GTIN.
    static func record(from toon: String, forGtin gtin: String) throws -> Record {
        let lines = toon.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerLine = lines.first(where: { $0.contains("{") && $0.contains("}") }) else {
            throw CatalogError.parse(reason: "no TOON header row in the dm result")
        }
        guard let open = headerLine.firstIndex(of: "{"),
              let close = headerLine.firstIndex(of: "}")
        else {
            throw CatalogError.parse(reason: "malformed TOON header row")
        }
        let headers = String(headerLine[headerLine.index(after: open) ..< close])
            .components(separatedBy: "|")

        let dataLines = lines
            .drop { !$0.contains("{") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let records: [Record] = dataLines.map { row in
            var record: Record = [:]
            let fields = splitRow(row.trimmingCharacters(in: .whitespaces))
            for (index, header) in headers.enumerated() where index < fields.count {
                record[header] = fields[index]
            }
            return record
        }
        guard !records.isEmpty else {
            throw CatalogError.parse(reason: "no data row in the TOON table")
        }

        // Prefer the row whose gtin column matches the requested GTIN;
        // fall back to the single row.
        if let match = records.first(where: { $0["gtin"] == gtin }) {
            return match
        }
        if records.count == 1 {
            return records[0]
        }
        throw CatalogError.parse(reason: "no TOON row matches GTIN \(gtin)")
    }

    /// Splits one TOON row on pipes that stand outside double quotes,
    /// then unquotes and unescapes each field.
    static func splitRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in row {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "|", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields.map(unquote)
    }

    /// Strips the surrounding quotes of a quoted field and restores
    /// the TOON escape sequences (`\"` → `"`, `\\` → `\`). Unquoted
    /// fields are only trimmed.
    private static func unquote(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        var value = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                value.append(character)
            }
        }
        return value
    }
}
