import PhotosUI
import SwiftUI

/// The photo-recognition sheet (ticket #24, D3a/D4a): capture a
/// photo (camera or library), OCR it, edit the query, confirm a
/// candidate — or fall back to the manual form. Presented by
/// `QueueTabView` in a sheet.
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
                        model.searchQuery = "Balea MEN Golden Intense Deospray"
                        await model.search()
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
            TextField("Suchbegriff", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("Erneut suchen") {
                Task { await model.search() }
            }
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
            TextField("Suchbegriff", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("Erneut suchen") {
                Task { await model.search() }
            }
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
            Button("Erneut suchen") {
                Task { await model.search() }
            }
        }
        .padding()
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
