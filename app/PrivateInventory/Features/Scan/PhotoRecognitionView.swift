import PhotosUI
import SwiftUI

/// The photo-recognition sheet (ticket #24, D3a/D4a; ticket #26,
/// D1b): capture a photo (camera or library), OCR it, adjust the
/// query chips, confirm a candidate — or fall back to the manual
/// form. Presented by `QueueTabView` in a sheet.
struct PhotoRecognitionView: View {
    let scannedGTIN: String
    let recognizer: any TextRecognizer
    let search: any CatalogSearch
    let binding: ProductBinding
    /// Called after a successful booking so the queue reloads.
    let onCompleted: () -> Void

    @State private var model: PhotoRecognitionModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showManualForm = false
    /// Free-text term for the next custom chip (ticket #26, D4b).
    @State private var newTerm: String = ""

    @Environment(\.dismiss) private var dismiss

    init(
        scannedGTIN: String,
        recognizer: any TextRecognizer,
        search: any CatalogSearch,
        binding: ProductBinding,
        onCompleted: @escaping () -> Void
    ) {
        self.scannedGTIN = scannedGTIN
        self.recognizer = recognizer
        self.search = search
        self.binding = binding
        self.onCompleted = onCompleted
        _model = State(
            initialValue: PhotoRecognitionModel(
                scannedGTIN: scannedGTIN,
                search: search,
                binding: binding,
                recognizer: recognizer
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    idle
                case .recognizing:
                    recognizing
                case let .candidates(matches):
                    candidates(matches)
                case .noMatches:
                    noMatches
                case let .booked(product, bookedRows):
                    booked(product, bookedRows)
                case let .failed(message):
                    failed(message)
                }
            }
            .navigationTitle("Foto-Erkennung")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task {
                    // recognize() runs the first search itself.
                    await model.recognize(image: image)
                }
            }
        }
        .sheet(isPresented: $showManualForm) {
            ManualProductFormView(scannedGTIN: scannedGTIN, binding: binding) {
                onCompleted()
                dismiss()
            }
        }
    }

    // MARK: Phases

    private var idle: some View {
        VStack(spacing: 16) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Foto aufnehmen", systemImage: "camera.fill")
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Aus Fotos wählen", systemImage: "photo.on.rectangle.angled")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let image = data.flatMap(UIImage.init)
                    // recognize() runs the first search itself.
                    await model.recognize(image: image)
                }
            }
            #if targetEnvironment(simulator) && DEBUG
                Button("OCR simulieren") {
                    Task {
                        await model.applyRecognized(lines: [
                            RecognizedLine(text: "Balea MEN", confidence: 0.9),
                            RecognizedLine(
                                text: "Golden Intense Deospray", confidence: 0.9
                            ),
                            RecognizedLine(text: "200 ml", confidence: 0.9),
                            RecognizedLine(text: "1,95 €", confidence: 0.9)
                        ])
                    }
                }
            #endif
        }
        .padding()
    }

    private var recognizing: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Text wird erkannt …")
        }
    }

    private func candidates(_ matches: [ResolvedProduct]) -> some View {
        VStack(spacing: 12) {
            queryEditor
            List(matches, id: \.gtin) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name)
                        .font(.headline)
                    Text(candidate.brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Produkt bestätigen") {
                        try? model.confirm(candidate: candidate)
                        if case .booked = model.phase {
                            onCompleted()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
        .padding()
    }

    private var noMatches: some View {
        VStack(spacing: 12) {
            queryEditor
            Text("Keine Treffer. Produkt manuell anlegen?")
            Button("Manuell anlegen") {
                showManualForm = true
            }
        }
        .padding()
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
            Button("Suchen") {
                Task { await model.search() }
            }
        }
        .padding()
    }

    // MARK: Query editor (ticket #26, D1b/D4b)

    /// The shared query editor (ticket #26, D1b): the recognized
    /// lines (plus user-added terms) as toggle chips, the free-text
    /// entry (D4b) and the search button. Used in the candidates and
    /// the noMatches phase.
    private var queryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                FlowLayout(spacing: 8) {
                    ForEach(model.chips) { chip in
                        chipButton(chip)
                    }
                    if model.chips.isEmpty {
                        Text("Keine Zeilen erkannt.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 200)
            HStack(spacing: 8) {
                TextField("Begriff hinzufügen", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(addTerm)
                Button {
                    addTerm()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(
                    newTerm.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
                .accessibilityLabel("Begriff hinzufügen")
            }
            Button("Suchen") {
                Task { await model.search() }
            }
        }
    }

    private func addTerm() {
        model.addCustomTerm(newTerm)
        newTerm = ""
    }

    private func chipButton(_ chip: QueryChip) -> some View {
        let isSelected = model.selected.contains(chip.id)
        return Button {
            model.toggleChip(chip.id)
        } label: {
            HStack(spacing: 4) {
                if chip.isCustom {
                    Image(systemName: "pencil")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(chip.text)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color.accentColor.opacity(0.2)
                        : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    }

    private func booked(_ product: Product, _ bookedRows: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Produkt gebucht")
                .font(.headline)
            Text(product.name)
            Text(verbatim: product.gtin)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Zeilen gebucht")
                .foregroundStyle(.secondary)
            Text(bookedRows, format: .number)
                .font(.title2)
                .foregroundStyle(.secondary)
            Button("Fertig") {
                dismiss()
            }
        }
    }
}
