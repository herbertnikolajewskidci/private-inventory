import SwiftUI

/// The manual product form (ticket #24, D6a): the user confirms a
/// name (and optionally a different GTIN/brand) for a scanned GTIN
/// the catalog could not resolve. Booking goes through
/// `ProductBinding` (alias + all queue rows).
struct ManualProductFormView: View {
    let scannedGTIN: String
    let binding: ProductBinding
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gtin: String
    @State private var name = ""
    @State private var brand = ""
    @State private var errorMessage: String?

    init(
        scannedGTIN: String,
        binding: ProductBinding,
        onCompleted: @escaping () -> Void
    ) {
        self.scannedGTIN = scannedGTIN
        self.binding = binding
        self.onCompleted = onCompleted
        _gtin = State(initialValue: scannedGTIN)
    }

    private var isValid: Bool {
        !gtin.isEmpty && gtin.allSatisfy { $0.isNumber && $0.isASCII }
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("GTIN") {
                    TextField("GTIN", text: $gtin)
                        .monospaced()
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                }
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Marke") {
                    TextField("Marke", text: $brand)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Manuell anlegen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        do {
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                errorMessage = String(localized: "Bitte einen Namen eingeben.")
                return
            }
            try binding.bind(
                scannedGTIN: scannedGTIN,
                productGTIN: gtin.isEmpty ? nil : gtin,
                name: name.trimmingCharacters(in: .whitespaces),
                brand: brand.trimmingCharacters(in: .whitespaces),
                imageURL: nil
            )
            NotificationCenter.default.post(name: .queueDidChange, object: nil)
            onCompleted()
            // Close the form after a successful save (CodeRabbit):
            // the sheet must not stay open over an empty queue.
            dismiss()
        } catch InventoryError.duplicateGTIN {
            errorMessage = String(localized: "Diese GTIN gehört zu einem anderen Produkt.")
        } catch {
            errorMessage = String(localized: "Fehler beim Buchen.")
        }
    }
}
