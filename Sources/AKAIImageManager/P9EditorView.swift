import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class P9EditorDocument: ObservableObject, Identifiable {
    enum Source {
        case local(URL)
        case image(filename: String, imageURL: URL)
        case newImageProgram(
            filename: String,
            imageURL: URL,
            volumePath: String
        )

        var filename: String {
            switch self {
            case .local(let url): return url.lastPathComponent
            case .image(let filename, _),
                 .newImageProgram(let filename, _, _):
                return filename
            }
        }

        var imageURL: URL? {
            switch self {
            case .local: return nil
            case .image(_, let imageURL),
                 .newImageProgram(_, let imageURL, _):
                return imageURL
            }
        }

        var volumePath: String? {
            if case .newImageProgram(_, _, let volumePath) = self {
                return volumePath
            }
            return nil
        }

        var isExistingImageProgram: Bool {
            if case .image = self { return true }
            return false
        }

        var isNewImageProgram: Bool {
            if case .newImageProgram = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case .local(let url):
                return url.deletingLastPathComponent().path
            case .image(_, let imageURL):
                return "From \(imageURL.lastPathComponent); edits remain in memory until saved or overwritten"
            case .newImageProgram(_, let imageURL, _):
                return "New program for \(imageURL.lastPathComponent); create it in the IMG when ready"
            }
        }
    }

    let id = UUID()
    @Published private(set) var source: Source
    @Published private(set) var originalData: Data
    @Published var program: P9Program
    @Published var lastSavedURL: URL?
    @Published private(set) var lastSavedData: Data?
    @Published private(set) var pendingKeygroupPaste: P9PendingKeygroupPaste?
    @Published var isPreparingKeygroupPaste = false
    @Published var isOverwritingInImage = false
    @Published var overwriteMessage: String?
    @Published var overwriteErrorMessage: String?
    @Published var isCreatingInImage = false
    @Published var createMessage: String?
    @Published var createErrorMessage: String?
    @Published var abletonImportDraft: AbletonDrumRackImportDraft?
    @Published var isImportingDrumRack = false
    @Published var drumRackImportMessage: String?
    @Published var drumRackImportErrorMessage: String?
    @Published private(set) var editorRevision = 0

    init(data: Data, source: Source) throws {
        originalData = data
        program = try P9Program(data: data)
        self.source = source
    }

    var hasChanges: Bool {
        guard let data = try? program.encoded() else { return true }
        return data != originalData
    }

    var hasUnwrittenChanges: Bool {
        guard let data = try? program.encoded() else { return true }
        if data == originalData, !source.isNewImageProgram {
            return false
        }
        if let lastSavedData, data == lastSavedData {
            return false
        }
        return source.isNewImageProgram || data != originalData
    }

    func replaceProgram(
        with updatedProgram: P9Program,
        refreshEditor: Bool = false
    ) {
        let structureChanged =
            updatedProgram.keygroups.count != program.keygroups.count
        program = updatedProgram
        if refreshEditor || structureChanged {
            editorRevision &+= 1
        }
    }

    @discardableResult
    func applyKeygroupDraft(
        _ draft: P9Keygroup,
        baseline: P9Keygroup,
        at index: Int
    ) -> Bool {
        guard program.keygroups.indices.contains(index),
              draft.id == index,
              baseline.id == index,
              program.keygroups[index] == baseline,
              draft != baseline
        else { return false }
        var updatedProgram = program
        updatedProgram.keygroups[index] = draft
        replaceProgram(with: updatedProgram)
        return true
    }

    func markOverwritten(with data: Data) throws {
        guard case .image = source else {
            throw AppError.verificationFailed(
                "Only a P9 opened from an IMG can be marked as overwritten."
            )
        }
        replaceProgram(
            with: try P9Program(data: data),
            refreshEditor: true
        )
        originalData = data
        lastSavedData = nil
        overwriteMessage = "\(source.filename) overwritten and byte-verified."
    }

    func markCreatedInImage(with data: Data) throws {
        guard case .newImageProgram(let filename, let imageURL, _) = source else {
            throw AppError.verificationFailed(
                "Only a new P9 can be marked as created in an IMG."
            )
        }
        replaceProgram(
            with: try P9Program(data: data),
            refreshEditor: true
        )
        originalData = data
        lastSavedData = nil
        source = .image(filename: filename, imageURL: imageURL)
        createMessage = "\(filename) created and byte-verified in the IMG."
    }

    func stageKeygroupPaste(
        records: [Data],
        sampleNameMapping: [String: String],
        statusLines: [String]
    ) throws {
        guard pendingKeygroupPaste == nil else {
            throw AppError.verificationFailed(
                "Apply the current pasted keygroups before pasting another set."
            )
        }
        var validationProgram = program
        try validationProgram.appendKeygroups(
            records: records,
            sampleNameMapping: sampleNameMapping
        )
        pendingKeygroupPaste = P9PendingKeygroupPaste(
            records: records,
            sampleNameMapping: sampleNameMapping,
            statusLines: statusLines
        )
    }

    @discardableResult
    func applyPendingKeygroupPaste() throws -> Range<Int>? {
        guard let pendingKeygroupPaste else { return nil }
        let firstIndex = program.keygroups.count
        var updatedProgram = program
        try updatedProgram.appendKeygroups(
            records: pendingKeygroupPaste.records,
            sampleNameMapping: pendingKeygroupPaste.sampleNameMapping
        )
        replaceProgram(with: updatedProgram)
        self.pendingKeygroupPaste = nil
        return firstIndex..<updatedProgram.keygroups.count
    }

    func saveCopy() throws -> URL? {
        guard pendingKeygroupPaste == nil else {
            throw AppError.verificationFailed(
                "Apply the pasted keygroups before saving the edited P9 copy."
            )
        }
        let panel = NSSavePanel()
        panel.title = "Save Edited P9 Copy"
        panel.prompt = "Save Copy"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p9") ?? .data]
        let stem = (source.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem)-EDITED.P9"
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        let destination = selectedURL.pathExtension.caseInsensitiveCompare("p9") == .orderedSame
            ? selectedURL
            : selectedURL.appendingPathExtension("P9")
        let data = try program.encoded()
        try data.write(to: destination, options: .atomic)
        lastSavedURL = destination
        lastSavedData = data
        return destination
    }
}

struct P9EditorSheet: View {
    @ObservedObject var document: P9EditorDocument
    let keygroupTransfer: P9KeygroupTransfer?
    let onCopyKeygroups: ((P9Program, Set<Int>, P9EditorDocument.Source) -> Void)?
    let onPasteKeygroups: ((P9EditorDocument) -> Void)?
    let onOverwriteP9: ((P9EditorDocument, Bool) -> Void)?
    let onCreateP9InImage: ((P9EditorDocument) -> Void)?
    let onChooseAbletonDrumRack: ((P9EditorDocument) -> Void)?
    let onImportAbletonDrumRack:
        ((AbletonDrumRackImportDraft, P9EditorDocument) -> Void)?
    let availableSampleNames: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int>
    @State private var bulkEdits = P9BulkEdits()
    @State private var individualDraft: P9Keygroup?
    @State private var individualDraftBaseline: P9Keygroup?
    @State private var loudSampleExpanded = false
    @State private var showSpreadSheet = false
    @State private var showOverwriteConfirmation = false
    @State private var createBackupBeforeOverwrite = true
    @State private var showCloseConfirmation = false
    @State private var spreadSettings = P9SpreadSettings()
    @State private var message: String?
    @State private var errorMessage: String?

    init(
        document: P9EditorDocument,
        initialSelection: Set<Int>? = nil,
        showSpreadInitially: Bool = false,
        showOverwriteConfirmationInitially: Bool = false,
        keygroupTransfer: P9KeygroupTransfer? = nil,
        availableSampleNames: [String] = [],
        onCopyKeygroups: ((P9Program, Set<Int>, P9EditorDocument.Source) -> Void)? = nil,
        onPasteKeygroups: ((P9EditorDocument) -> Void)? = nil,
        onOverwriteP9: ((P9EditorDocument, Bool) -> Void)? = nil,
        onCreateP9InImage: ((P9EditorDocument) -> Void)? = nil,
        onChooseAbletonDrumRack: ((P9EditorDocument) -> Void)? = nil,
        onImportAbletonDrumRack:
            ((AbletonDrumRackImportDraft, P9EditorDocument) -> Void)? = nil
    ) {
        self.document = document
        self.keygroupTransfer = keygroupTransfer
        self.onCopyKeygroups = onCopyKeygroups
        self.onPasteKeygroups = onPasteKeygroups
        self.onOverwriteP9 = onOverwriteP9
        self.onCreateP9InImage = onCreateP9InImage
        self.onChooseAbletonDrumRack = onChooseAbletonDrumRack
        self.onImportAbletonDrumRack = onImportAbletonDrumRack
        self.availableSampleNames = availableSampleNames
        let first = document.program.keygroups.first?.id
        let startingSelection = initialSelection ?? first.map { Set([$0]) } ?? []
        _selection = State(initialValue: startingSelection)
        _showSpreadSheet = State(
            initialValue: showSpreadInitially && startingSelection.count > 1
        )
        _showOverwriteConfirmation = State(
            initialValue: showOverwriteConfirmationInitially
        )
        let firstNote = startingSelection.sorted().first
            .flatMap { index in
                document.program.keygroups.indices.contains(index)
                    ? document.program.keygroups[index].lowKey
                    : nil
            } ?? 60
        _spreadSettings = State(
            initialValue: P9SpreadSettings(
                startNote: firstNote,
                rootNote: firstNote,
                automaticallyTranspose: true
            )
        )
        if startingSelection.count == 1,
           let index = startingSelection.first,
           document.program.keygroups.indices.contains(index) {
            _individualDraft = State(initialValue: document.program.keygroups[index])
            _individualDraftBaseline = State(
                initialValue: document.program.keygroups[index]
            )
        } else {
            _individualDraft = State(initialValue: nil)
            _individualDraftBaseline = State(initialValue: nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .disabled(
                document.isOverwritingInImage
                        || document.isCreatingInImage
                        || document.isImportingDrumRack
                )
            Divider()
            HStack(spacing: 0) {
                keygroupList
                    .frame(width: 240)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(
                document.isOverwritingInImage
                    || document.isCreatingInImage
                    || document.isImportingDrumRack
            )
            Divider()
            footer
        }
        .frame(width: 1240, height: 800)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selection) { oldSelection, newSelection in
            applyIndividualDraft(for: oldSelection, announce: false)
            bulkEdits = P9BulkEdits()
            loadIndividualDraft(for: newSelection)
            message = nil
        }
        .onChange(of: document.editorRevision) { _, _ in
            bulkEdits = P9BulkEdits()
            loadIndividualDraft(for: selection)
        }
        .alert("P9 Editor", isPresented: Binding(
            get: {
                errorMessage != nil
                    || document.overwriteErrorMessage != nil
                    || document.createErrorMessage != nil
                    || document.drumRackImportErrorMessage != nil
            },
            set: {
                if !$0 {
                    errorMessage = nil
                    document.overwriteErrorMessage = nil
                    document.createErrorMessage = nil
                    document.drumRackImportErrorMessage = nil
                }
            }
        )) {
            Button("OK") {
                errorMessage = nil
                document.overwriteErrorMessage = nil
                document.createErrorMessage = nil
                document.drumRackImportErrorMessage = nil
            }
        } message: {
            Text(
                errorMessage
                    ?? document.overwriteErrorMessage
                    ?? document.createErrorMessage
                    ?? document.drumRackImportErrorMessage
                    ?? ""
            )
        }
        .alert(
            "Close Program Without Saving?",
            isPresented: $showCloseConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Close Without Saving", role: .destructive) {
                dismiss()
            }
        } message: {
            Text(
                "This version of the program has not been written to its IMG "
                    + "or saved as an edited P9 copy. Closing now will discard it."
            )
        }
        .sheet(isPresented: $showSpreadSheet) {
            P9SpreadSheet(
                keygroupCount: selection.count,
                settings: $spreadSettings,
                onSpread: performSpread
            )
        }
        .sheet(isPresented: $showOverwriteConfirmation) {
            P9OverwriteConfirmationSheet(
                filename: document.source.filename,
                createBackup: $createBackupBeforeOverwrite
            ) { createBackup in
                overwriteInImage(createBackup: createBackup)
            }
        }
        .sheet(item: $document.abletonImportDraft) { draft in
            AbletonDrumRackImportSheet(draft: draft) { finalized in
                onImportAbletonDrumRack?(finalized, document)
            }
        }
        .interactiveDismissDisabled(
            document.hasUnwrittenChanges
                || document.isPreparingKeygroupPaste
                || document.isOverwritingInImage
                || document.isCreatingInImage
                || document.isImportingDrumRack
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "pianokeys")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.source.filename)
                    .font(.title2.weight(.semibold))
                Text(document.source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Program")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(document.program.name)
                    .font(.headline)
                    .monospaced()
            }
            Toggle("Positional crossfade", isOn: positionalCrossfadeBinding)
        }
        .padding(12)
    }

    private var keygroupList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Keygroups")
                    .font(.headline)
                Spacer()
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            List(document.program.keygroups, selection: $selection) { keygroup in
                let displayedKeygroup =
                    selection == [keygroup.id]
                        && individualDraft?.id == keygroup.id
                    ? individualDraft ?? keygroup
                    : keygroup
                HStack {
                    Text("\(keygroup.id + 1)")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            displayedKeygroup.softSampleName.isEmpty
                                ? "No soft sample"
                                : displayedKeygroup.softSampleName
                        )
                            .lineLimit(1)
                        Text(displayedKeygroup.noteRangeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(keygroup.id)
            }
            .id(document.editorRevision)

            HStack {
                Button {
                    addKeygroup()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Keygroup")
                .disabled(
                    document.program.keygroups.count >= 99
                        || document.pendingKeygroupPaste != nil
                        || document.isPreparingKeygroupPaste
                )
                .help("Add a keygroup by duplicating the selected keygroup")
                Button(role: .destructive) {
                    deleteSelectedKeygroups()
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Delete Keygroups")
                .disabled(
                    selection.isEmpty
                        || selection.count >= document.program.keygroups.count
                        || document.pendingKeygroupPaste != nil
                        || document.isPreparingKeygroupPaste
                )
                .help("Delete the selected keygroups; at least one must remain")
                Spacer()
                Menu("Select") {
                    Button("Select All Keygroups") {
                        selection = Set(document.program.keygroups.indices)
                    }
                    Button("Keep First Selected Only") {
                        if let first =
                            selection.sorted().first
                            ?? document.program.keygroups.first?.id {
                            selection = [first]
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if selection.count == 1, let index = selection.first,
           document.program.keygroups.indices.contains(index) {
            IndividualP9KeygroupEditor(
                keygroup: individualDraftBinding(index),
                loudSampleExpanded: $loudSampleExpanded,
                availableSampleNames: availableSampleNames
            )
        } else if !selection.isEmpty {
            BulkP9KeygroupEditor(
                edits: $bulkEdits,
                loudSampleExpanded: $loudSampleExpanded,
                availableSampleNames: availableSampleNames
            )
        } else {
            ContentUnavailableView(
                "Select a Keygroup",
                systemImage: "pianokeys",
                description: Text("Select one keygroup to edit it, or select several for bulk editing.")
            )
        }
    }

    private var footer: some View {
        HStack {
            Label(
                document.source.isExistingImageProgram
                    ? "Edits remain in memory until saved or safely overwritten"
                    : document.source.isNewImageProgram
                        ? "Create in IMG when ready, or save a local P9 copy"
                        : "Save Copy only — the source P9 remains unchanged",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if document.isPreparingKeygroupPaste {
                ProgressView()
                    .controlSize(.small)
                Text("Transferring associated samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let pending = document.pendingKeygroupPaste {
                Text(
                    "\(pending.count) pasted keygroup\(pending.count == 1 ? "" : "s") ready — click Apply."
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .lineLimit(1)
            } else if document.isOverwritingInImage {
                ProgressView()
                    .controlSize(.small)
                Text("Backing up, overwriting and verifying…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if document.isCreatingInImage {
                ProgressView()
                    .controlSize(.small)
                Text("Creating and verifying the new P9…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if document.isImportingDrumRack {
                ProgressView()
                    .controlSize(.small)
                Text("Converting WAV files and importing S9 samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let overwriteMessage = document.overwriteMessage {
                Text(overwriteMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let createMessage = document.createMessage {
                Text(createMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let drumRackImportMessage =
                        document.drumRackImportMessage {
                Text(drumRackImportMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                chooseAbletonDrumRack()
            } label: {
                Label("Import ADG…", systemImage: "square.grid.3x3")
            }
            .disabled(
                document.source.imageURL == nil
                    || onChooseAbletonDrumRack == nil
                    || onImportAbletonDrumRack == nil
                    || document.pendingKeygroupPaste != nil
                    || document.isPreparingKeygroupPaste
                    || document.isOverwritingInImage
                    || document.isCreatingInImage
                    || document.isImportingDrumRack
                    || document.program.keygroups.count >= 99
            )
            .help(
                document.source.imageURL == nil
                    ? "Open this P9 from a writable S950 IMG to import its samples"
                    : "Convert an Ableton Drum Rack ADG into S9 samples and appended keygroups"
            )
            Button {
                prepareSpread()
            } label: {
                Label("Spread…", systemImage: "pianokeys")
            }
            .disabled(
                selection.count < 2
                    || bulkEdits.hasChanges
                    || document.pendingKeygroupPaste != nil
                    || document.isPreparingKeygroupPaste
                    || document.isOverwritingInImage
                    || document.isCreatingInImage
                    || document.isImportingDrumRack
            )
            .help(
                document.pendingKeygroupPaste != nil
                    ? "Apply the pasted keygroups before spreading"
                    : bulkEdits.hasChanges
                    ? "Apply the current bulk edits before spreading keygroups"
                    : "Map selected keygroups chromatically across single notes"
            )
            Menu {
                Button("Copy Selected Keygroups and Samples") {
                    copyCurrentKeygroups()
                }
                .disabled(
                    selection.isEmpty
                        || onCopyKeygroups == nil
                        || document.pendingKeygroupPaste != nil
                        || document.isPreparingKeygroupPaste
                        || document.isOverwritingInImage
                        || document.isCreatingInImage
                        || document.isImportingDrumRack
                )
                Divider()
                if let keygroupTransfer {
                    Text(keygroupTransfer.summary)
                    Button(
                        "Paste \(keygroupTransfer.records.count) at End"
                    ) {
                        pasteCopiedKeygroups()
                    }
                    .disabled(
                        onPasteKeygroups == nil
                            || document.pendingKeygroupPaste != nil
                            || document.isPreparingKeygroupPaste
                            || document.isOverwritingInImage
                            || document.isCreatingInImage
                            || document.isImportingDrumRack
                            || document.program.keygroups.count
                                + keygroupTransfer.records.count > 99
                    )
                } else {
                    Button("Paste Keygroups at End") {}
                        .disabled(true)
                }
            } label: {
                Label("Transfer", systemImage: "doc.on.doc")
            }
            .help(
                keygroupTransfer?.summary
                    ?? "Copy selected keygroups and their associated S9 samples"
            )
            Button("Close") { requestClose() }
                .keyboardShortcut(.cancelAction)
                .disabled(
                    document.isPreparingKeygroupPaste
                        || document.isOverwritingInImage
                        || document.isCreatingInImage
                        || document.isImportingDrumRack
                )
            Button(applyButtonTitle) { applyCurrentEdits() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            Button("Save Edited Copy…") { saveCopy() }
                .disabled(
                    document.pendingKeygroupPaste != nil
                        || document.isPreparingKeygroupPaste
                        || document.isOverwritingInImage
                        || document.isCreatingInImage
                        || document.isImportingDrumRack
                )
                .help(
                    document.pendingKeygroupPaste != nil
                        ? "Click Apply Pasted Keygroups before saving"
                        : "Save the edited program as a new P9 file"
                )
            if document.source.isNewImageProgram {
                Button("Create in IMG…") {
                    createInImage()
                }
                .disabled(!canCreateInImage)
                .help(
                    "Import this new program into its source IMG and verify every P9 byte"
                )
            }
            if document.source.isExistingImageProgram {
                Button("Overwrite in IMG…") {
                    showOverwriteConfirmation = true
                }
                .disabled(!canOverwriteInImage)
                .help(
                    document.pendingKeygroupPaste != nil
                        ? "Apply the pasted keygroups before overwriting"
                        : "Create a verified IMG backup, replace this P9 and byte-verify it"
                )
            }
        }
        .padding(12)
    }

    private var positionalCrossfadeBinding: Binding<Bool> {
        Binding(
            get: { document.program.positionalCrossfade },
            set: { value in
                var program = document.program
                program.positionalCrossfade = value
                document.replaceProgram(with: program)
            }
        )
    }

    private func individualDraftBinding(_ index: Int) -> Binding<P9Keygroup> {
        Binding(
            get: {
                if let individualDraft, individualDraft.id == index {
                    return individualDraft
                }
                return document.program.keygroups[index]
            },
            set: { individualDraft = $0 }
        )
    }

    private var canApply: Bool {
        if document.isPreparingKeygroupPaste
            || document.isOverwritingInImage
            || document.isCreatingInImage
            || document.isImportingDrumRack {
            return false
        }
        if document.pendingKeygroupPaste != nil {
            return true
        }
        if selection.count == 1,
           let index = selection.first,
           document.program.keygroups.indices.contains(index),
           let individualDraft,
           individualDraft.id == index {
            return individualDraft != document.program.keygroups[index]
        }
        return selection.count > 1 && bulkEdits.hasChanges
    }

    private var canOverwriteInImage: Bool {
        guard onOverwriteP9 != nil,
              document.source.isExistingImageProgram,
              document.pendingKeygroupPaste == nil,
              !document.isPreparingKeygroupPaste,
              !document.isOverwritingInImage,
              !document.isCreatingInImage,
              !document.isImportingDrumRack
        else { return false }
        return document.hasChanges || canApply
    }

    private var canCreateInImage: Bool {
        onCreateP9InImage != nil
            && document.source.isNewImageProgram
            && !document.program.keygroups.isEmpty
            && document.pendingKeygroupPaste == nil
            && !document.isPreparingKeygroupPaste
            && !document.isOverwritingInImage
            && !document.isCreatingInImage
            && !document.isImportingDrumRack
    }

    private var applyButtonTitle: String {
        if let pending = document.pendingKeygroupPaste {
            return "Apply \(pending.count) Pasted Keygroup\(pending.count == 1 ? "" : "s")"
        }
        if selection.count == 1, let index = selection.first {
            return "Apply to Keygroup \(index + 1)"
        }
        if selection.count > 1 {
            return "Apply to \(selection.count) Keygroups"
        }
        return "Apply"
    }

    private func loadIndividualDraft(for target: Set<Int>) {
        guard target.count == 1,
              let index = target.first,
              document.program.keygroups.indices.contains(index)
        else {
            individualDraft = nil
            individualDraftBaseline = nil
            return
        }
        let current = document.program.keygroups[index]
        individualDraft = current
        individualDraftBaseline = current
    }

    private func applyIndividualDraft(for target: Set<Int>, announce: Bool) {
        guard target.count == 1,
              let index = target.first,
              document.program.keygroups.indices.contains(index),
              let draft = individualDraft,
              let baseline = individualDraftBaseline,
              draft.id == index,
              baseline.id == index
        else { return }
        if document.applyKeygroupDraft(
            draft,
            baseline: baseline,
            at: index
        ) {
            individualDraft = draft
            individualDraftBaseline = draft
        } else if document.program.keygroups[index] != baseline {
            loadIndividualDraft(for: target)
            return
        } else {
            return
        }
        if announce {
            message = "Applied changes to keygroup \(index + 1)."
        }
    }

    private func applyCurrentEdits(announce: Bool = true) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let pending = document.pendingKeygroupPaste {
            if selection.count == 1 {
                applyIndividualDraft(for: selection, announce: false)
            } else if selection.count > 1, bulkEdits.hasChanges {
                var program = document.program
                program.apply(bulkEdits, to: selection)
                document.replaceProgram(with: program)
                bulkEdits = P9BulkEdits()
            }
            do {
                if let appendedRange = try document.applyPendingKeygroupPaste() {
                    selection = Set(appendedRange)
                    bulkEdits = P9BulkEdits()
                    individualDraft = nil
                    individualDraftBaseline = nil
                }
                if announce {
                    message =
                        "Applied \(pending.count) pasted keygroup"
                        + "\(pending.count == 1 ? "" : "s"). Save Edited Copy when ready."
                }
            } catch {
                errorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            return
        }
        if selection.count == 1 {
            applyIndividualDraft(for: selection, announce: announce)
        } else if selection.count > 1, bulkEdits.hasChanges {
            var program = document.program
            program.apply(bulkEdits, to: selection)
            document.replaceProgram(with: program)
            if announce {
                message = "Applied changes to \(selection.count) keygroups."
            }
            bulkEdits = P9BulkEdits()
        }
    }

    private func prepareSpread() {
        guard selection.count > 1,
              let firstIndex = selection.sorted().first,
              document.program.keygroups.indices.contains(firstIndex)
        else { return }
        let firstNote = document.program.keygroups[firstIndex].lowKey
        spreadSettings = P9SpreadSettings(
            startNote: firstNote,
            rootNote: firstNote,
            automaticallyTranspose: true
        )
        showSpreadSheet = true
    }

    private func addKeygroup() {
        applyCurrentEdits(announce: false)
        do {
            var program = document.program
            let newIndex = try program.appendKeygroup(
                copying: selection.sorted().first
            )
            document.replaceProgram(with: program)
            bulkEdits = P9BulkEdits()
            selection = [newIndex]
            message = "Added keygroup \(newIndex + 1)."
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func deleteSelectedKeygroups() {
        applyCurrentEdits(announce: false)
        guard let firstDeleted = selection.sorted().first else { return }
        let deletedCount = selection.count
        do {
            var program = document.program
            try program.deleteKeygroups(at: selection)
            document.replaceProgram(with: program)
            bulkEdits = P9BulkEdits()
            selection = [min(firstDeleted, program.keygroups.count - 1)]
            message =
                deletedCount == 1
                    ? "Deleted the selected keygroup."
                    : "Deleted \(deletedCount) selected keygroups."
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func performSpread(_ settings: P9SpreadSettings) {
        do {
            var program = document.program
            try program.spread(settings, to: selection)
            document.replaceProgram(with: program)
            bulkEdits = P9BulkEdits()
            let endNote = settings.startNote + selection.count - 1
            message = "Spread \(selection.count) keygroups from \(P9Keygroup.noteName(settings.startNote)) to \(P9Keygroup.noteName(endNote))."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func copyCurrentKeygroups() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        onCopyKeygroups?(document.program, selection, document.source)
    }

    private func pasteCopiedKeygroups() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        onPasteKeygroups?(document)
    }

    private func saveCopy() {
        do {
            applyCurrentEdits(announce: false)
            if let saved = try document.saveCopy() {
                message = "Saved \(saved.lastPathComponent)"
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func overwriteInImage(createBackup: Bool) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        document.overwriteMessage = nil
        onOverwriteP9?(document, createBackup)
    }

    private func createInImage() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        document.createMessage = nil
        onCreateP9InImage?(document)
    }

    private func requestClose() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        if document.hasUnwrittenChanges {
            showCloseConfirmation = true
        } else {
            dismiss()
        }
    }

    private func chooseAbletonDrumRack() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        applyCurrentEdits(announce: false)
        document.drumRackImportMessage = nil
        document.drumRackImportErrorMessage = nil
        onChooseAbletonDrumRack?(document)
    }
}

private struct P9OverwriteConfirmationSheet: View {
    let filename: String
    @Binding var createBackup: Bool
    let onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                "Overwrite \(filename) in the IMG?",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.title2.weight(.semibold))

            Text(
                "The P9 will be replaced, exported again and compared byte-for-byte."
            )

            Toggle(
                "Create and verify a complete IMG backup first",
                isOn: $createBackup
            )

            if createBackup {
                Text(
                    "If replacement or verification fails, the backup will be restored automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Automatic rollback is unavailable without a backup.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(
                    createBackup
                        ? "Back Up and Overwrite"
                        : "Overwrite Without Backup",
                    role: .destructive
                ) {
                    let shouldBackUp = createBackup
                    dismiss()
                    onConfirm(shouldBackUp)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct P9SpreadSheet: View {
    let keygroupCount: Int
    @Binding var settings: P9SpreadSettings
    let onSpread: (P9SpreadSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spread Across Keys")
                        .font(.title2.weight(.semibold))
                    Text("\(keygroupCount) selected keygroups")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Chromatic mapping") {
                VStack(spacing: 10) {
                    noteRow("Starting note", value: $settings.startNote)
                    noteRow("Sample root note", value: $settings.rootNote)
                        .disabled(!settings.automaticallyTranspose)
                    Toggle(
                        "Automatically transpose to preserve original playback speed",
                        isOn: $settings.automaticallyTranspose
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(previewText, systemImage: "arrow.left.and.right")
                    .font(.headline)
                if settings.automaticallyTranspose {
                    Text(transposePreviewText)
                        .foregroundStyle(.secondary)
                }
                Text("Soft and Loud Transpose are set together. Existing Fine tuning and all other parameters remain unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Spread Keygroups") {
                    onSpread(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil)
            }
        }
        .controlSize(.small)
        .padding(20)
        .frame(width: 520)
    }

    private func noteRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(P9Keygroup.noteName(value.wrappedValue))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            P9BoundedNumberField(value: value, range: 0...127)
            Stepper("", value: value, in: 0...127)
                .labelsHidden()
        }
    }

    private var endingNote: Int {
        settings.startNote + max(0, keygroupCount - 1)
    }

    private var previewText: String {
        "\(P9Keygroup.noteName(settings.startNote))–\(P9Keygroup.noteName(min(127, endingNote))) on single notes"
    }

    private var transposePreviewText: String {
        let first = settings.rootNote - settings.startNote
        let last = settings.rootNote - endingNote
        if first == last {
            return "Transpose: \(signed(first)) semitones"
        }
        return "Transpose: \(signed(first)) to \(signed(last)) semitones"
    }

    private var validationError: String? {
        do {
            try settings.validate(keygroupCount: keygroupCount)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

private struct IndividualP9KeygroupEditor: View {
    @Binding var keygroup: P9Keygroup
    @Binding var loudSampleExpanded: Bool
    let availableSampleNames: [String]

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    mappingSection
                    softSampleSection
                    playbackSection
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 12) {
                    vcfSection
                    amplitudeSection
                    velocitySection
                    loudSampleSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .controlSize(.small)
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mappingSection: some View {
        GroupBox("Mapping") {
            VStack(spacing: 7) {
                numberRow("Low key", value: int(\.lowKey, 0...127), range: 0...127) {
                    P9Keygroup.noteName(keygroup.lowKey)
                }
                numberRow("High key", value: int(\.highKey, 0...127), range: 0...127) {
                    P9Keygroup.noteName(keygroup.highKey)
                }
                numberRow(
                    "Velocity switch threshold",
                    value: int(\.velocityThreshold, 0...128),
                    range: 0...128
                )
                Toggle("Velocity crossfade", isOn: bool(\.velocityCrossfade))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(
                    "Custom crossfade midpoint",
                    isOn: bool(\.customVelocityCrossfadePoint)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!keygroup.velocityCrossfade)
                numberRow(
                    "Velocity crossfade midpoint",
                    value: int(\.velocityCrossfadePoint, 0...127),
                    range: 0...127
                )
                .disabled(
                    !keygroup.velocityCrossfade
                        || !keygroup.customVelocityCrossfadePoint
                )
            }
            .padding(6)
        }
    }

    private var softSampleSection: some View {
        sampleSection(
            title: "Soft Sample",
            name: string(\.softSampleName),
            loudness: int(\.softLoudness, -50...50),
            filter: int(\.softFilter, 0...99),
            transpose: int(\.softTuning.transpose, P9Tuning.transposeRange),
            fine: int(\.softTuning.fine, P9Tuning.fineRange)
        )
    }

    private var loudSampleSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $loudSampleExpanded) {
                sampleFields(
                    name: string(\.loudSampleName),
                    loudness: int(\.loudLoudness, -50...50),
                    filter: int(\.loudFilter, 0...99),
                    transpose: int(\.loudTuning.transpose, P9Tuning.transposeRange),
                    fine: int(\.loudTuning.fine, P9Tuning.fineRange)
                )
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Loud Sample")
                        .fontWeight(.semibold)
                    Spacer()
                    if !loudSampleExpanded {
                        Text(keygroup.loudSampleName.isEmpty ? "Hidden" : keygroup.loudSampleName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(6)
        }
    }

    private var vcfSection: some View {
        GroupBox("VCF Envelope") {
            VStack(spacing: 7) {
                envelopeRows(
                    attack: int(\.vcfEnvelope.attack, 0...99),
                    decay: int(\.vcfEnvelope.decay, 0...99),
                    sustain: int(\.vcfEnvelope.sustain, 0...99),
                    release: int(\.vcfEnvelope.release, 0...99)
                )
                numberRow("Amount", value: int(\.vcfAmount, -50...50), range: -50...50)
            }
            .padding(6)
        }
    }

    private var amplitudeSection: some View {
        GroupBox("Amplitude ENV") {
            VStack(spacing: 7) {
                envelopeRows(
                    attack: int(\.envelope.attack, 0...99),
                    decay: int(\.envelope.decay, 0...99),
                    sustain: int(\.envelope.sustain, 0...99),
                    release: int(\.envelope.release, 0...99)
                )
            }
            .padding(6)
        }
    }

    private var velocitySection: some View {
        GroupBox("Velocity Sensitivity") {
            VStack(spacing: 7) {
                numberRow(
                    "Loudness",
                    value: int(\.velocitySensitivity.loudness, 0...99),
                    range: 0...99
                )
                numberRow(
                    "Attack",
                    value: int(\.velocitySensitivity.attack, 0...99),
                    range: 0...99
                )
                numberRow(
                    "Filter",
                    value: int(\.velocitySensitivity.filter, 0...99),
                    range: 0...99
                )
                numberRow(
                    "Release",
                    value: int(\.velocitySensitivity.release, -50...50),
                    range: -50...50
                )
                Picker(
                    "Release velocity source",
                    selection: bool(\.releaseVelocityFromNoteOn)
                ) {
                    Text("Note Off").tag(false)
                    Text("Note On").tag(true)
                }
            }
            .padding(6)
        }
    }

    private var playbackSection: some View {
        GroupBox("Playback and Routing") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Toggle("Constant pitch", isOn: bool(\.constantPitch))
                    Spacer()
                    Toggle("One-shot", isOn: bool(\.oneShot))
                }
                Picker("MIDI channel", selection: midiChannelBinding) {
                    ForEach(1...16, id: \.self) { channel in
                        Text("\(channel)").tag(channel)
                    }
                }
                .help("Displayed as channels 1–16; the P9 stores offsets 00–15")
                Picker("Output", selection: outputBinding) {
                    ForEach(outputChoices) { output in
                        Text(output.displayName).tag(output)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func sampleFields(
        name: Binding<String>,
        loudness: Binding<Int>,
        filter: Binding<Int>,
        transpose: Binding<Int>,
        fine: Binding<Int>
    ) -> some View {
        VStack(spacing: 7) {
            Picker("Sample", selection: name) {
                Text("No sample").tag("")
                ForEach(sampleChoices(current: name.wrappedValue), id: \.self) {
                    sampleName in
                    Text(sampleName).tag(sampleName)
                }
            }
            .help("Choose from the S9 samples available in the open S950 volume")
            numberRow("Loudness", value: loudness, range: -50...50)
            numberRow("Filter", value: filter, range: 0...99)
            numberRow("Transpose", value: transpose, range: P9Tuning.transposeRange)
            numberRow("Fine", value: fine, range: P9Tuning.fineRange)
                .help(
                    "S950 fine tuning in 1/16-semitone steps "
                        + "(\(P9Tuning.fineRange.lowerBound)…\(P9Tuning.fineRange.upperBound))"
                )
        }
    }

    @ViewBuilder
    private func sampleSection(
        title: String,
        name: Binding<String>,
        loudness: Binding<Int>,
        filter: Binding<Int>,
        transpose: Binding<Int>,
        fine: Binding<Int>
    ) -> some View {
        GroupBox(title) {
            sampleFields(
                name: name,
                loudness: loudness,
                filter: filter,
                transpose: transpose,
                fine: fine
            )
            .padding(6)
        }
    }

    @ViewBuilder
    private func envelopeRows(
        attack: Binding<Int>,
        decay: Binding<Int>,
        sustain: Binding<Int>,
        release: Binding<Int>
    ) -> some View {
        numberRow("Attack", value: attack, range: 0...99)
        numberRow("Decay", value: decay, range: 0...99)
        numberRow("Sustain", value: sustain, range: 0...99)
        numberRow("Release", value: release, range: 0...99)
    }

    private func numberRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        detail: (() -> String)? = nil
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let detail {
                Text(detail())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            P9BoundedNumberField(value: value, range: range)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
    }

    private func int(_ keyPath: WritableKeyPath<P9Keygroup, Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { keygroup[keyPath: keyPath] },
            set: { value in
                keygroup[keyPath: keyPath] = max(range.lowerBound, min(range.upperBound, value))
            }
        )
    }

    private func bool(_ keyPath: WritableKeyPath<P9Keygroup, Bool>) -> Binding<Bool> {
        Binding(
            get: { keygroup[keyPath: keyPath] },
            set: { keygroup[keyPath: keyPath] = $0 }
        )
    }

    private func string(_ keyPath: WritableKeyPath<P9Keygroup, String>) -> Binding<String> {
        Binding(
            get: { keygroup[keyPath: keyPath] },
            set: { keygroup[keyPath: keyPath] = String($0.uppercased().prefix(10)) }
        )
    }

    private func sampleChoices(current: String) -> [String] {
        var names = availableSampleNames
        if !current.isEmpty,
           !names.contains(where: {
               $0.caseInsensitiveCompare(current) == .orderedSame
           }) {
            names.append(current)
        }
        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var midiChannelBinding: Binding<Int> {
        Binding(
            get: { max(1, min(16, keygroup.midiChannelOffset + 1)) },
            set: { keygroup.midiChannelOffset = $0 - 1 }
        )
    }

    private var outputBinding: Binding<P9Output> {
        Binding(
            get: { keygroup.output },
            set: { keygroup.output = $0 }
        )
    }

    private var outputChoices: [P9Output] {
        if case .unknown = keygroup.output {
            return [keygroup.output] + P9Output.standardChoices
        }
        return P9Output.standardChoices
    }
}

private struct P9BoundedNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text: String

    init(value: Binding<Int>, range: ClosedRange<Int>) {
        _value = value
        self.range = range
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 58)
            .onChange(of: text) { _, newText in
                guard let bounded = P9NumericInput.boundedValue(newText, range: range) else { return }
                if value != bounded {
                    value = bounded
                }
            }
            .onChange(of: value) { _, newValue in
                let normalized = String(newValue)
                if text != normalized {
                    text = normalized
                }
            }
            .onSubmit {
                text = String(value)
            }
    }
}

private struct BulkP9KeygroupEditor: View {
    @Binding var edits: P9BulkEdits
    @Binding var loudSampleExpanded: Bool
    let availableSampleNames: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only checked fields will change. “Adjust” adds or subtracts the value from every selected keygroup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        bulkGroup("Mapping") {
                            bulkRow("Low key", \.lowKey, range: 0...127)
                            bulkRow("High key", \.highKey, range: 0...127)
                            bulkRow("Velocity threshold", \.velocityThreshold, range: 0...128)
                            bulkRow(
                                "Crossfade midpoint",
                                \.velocityCrossfadePoint,
                                range: 0...127
                            )
                            optionalChoicePicker(
                                "Custom midpoint",
                                trueLabel: "Enable",
                                falseLabel: "Disable",
                                value: binding(\.customVelocityCrossfadePoint)
                            )
                        }
                        bulkGroup("Soft Sample") {
                            bulkSamplePicker(
                                "Sample",
                                value: binding(\.softSampleName)
                            )
                            bulkRow("Loudness", \.softLoudness, range: -50...50)
                            bulkRow("Filter", \.softFilter, range: 0...99)
                            bulkRow("Transpose", \.softTranspose, range: P9Tuning.transposeRange)
                            bulkRow("Fine", \.softFine, range: P9Tuning.fineRange)
                        }
                        bulkGroup("VCF Envelope") {
                            bulkRow("Attack", \.vcfAttack, range: 0...99)
                            bulkRow("Decay", \.vcfDecay, range: 0...99)
                            bulkRow("Sustain", \.vcfSustain, range: 0...99)
                            bulkRow("Release", \.vcfRelease, range: 0...99)
                            bulkRow("Amount", \.vcfAmount, range: -50...50)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(alignment: .leading, spacing: 12) {
                        bulkGroup("Amplitude ENV") {
                            bulkRow("Attack", \.envAttack, range: 0...99)
                            bulkRow("Decay", \.envDecay, range: 0...99)
                            bulkRow("Sustain", \.envSustain, range: 0...99)
                            bulkRow("Release", \.envRelease, range: 0...99)
                        }
                        bulkGroup("Velocity Sensitivity") {
                            bulkRow("Loudness", \.velocityLoudness, range: 0...99)
                            bulkRow("Attack", \.velocityAttack, range: 0...99)
                            bulkRow("Filter", \.velocityFilter, range: 0...99)
                            bulkRow("Release", \.velocityRelease, range: -50...50)
                            optionalChoicePicker(
                                "Release source",
                                trueLabel: "Note On",
                                falseLabel: "Note Off",
                                value: binding(\.releaseVelocityFromNoteOn)
                            )
                        }
                        playbackAndRouting
                        loudSampleSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .controlSize(.small)
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var playbackAndRouting: some View {
        GroupBox("Playback and Routing") {
            VStack(spacing: 7) {
                optionalBooleanPicker("Constant pitch", value: binding(\.constantPitch))
                optionalBooleanPicker("Velocity crossfade", value: binding(\.velocityCrossfade))
                optionalBooleanPicker("One-shot", value: binding(\.oneShot))
                Picker("MIDI channel", selection: binding(\.midiChannel)) {
                    Text("Unchanged").tag(Int?.none)
                    ForEach(1...16, id: \.self) { channel in
                        Text("\(channel)").tag(Optional(channel))
                    }
                }
                Picker("Output", selection: binding(\.output)) {
                    Text("Unchanged").tag(P9Output?.none)
                    ForEach(P9Output.standardChoices) { output in
                        Text(output.displayName).tag(Optional(output))
                    }
                }
            }
            .padding(6)
        }
    }

    private var loudSampleSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $loudSampleExpanded) {
                VStack(spacing: 7) {
                    bulkSamplePicker(
                        "Sample",
                        value: binding(\.loudSampleName)
                    )
                    bulkRow("Loudness", \.loudLoudness, range: -50...50)
                    bulkRow("Filter", \.loudFilter, range: 0...99)
                    bulkRow("Transpose", \.loudTranspose, range: P9Tuning.transposeRange)
                    bulkRow("Fine", \.loudFine, range: P9Tuning.fineRange)
                }
                .padding(.top, 8)
            } label: {
                Text("Loud Sample")
                    .fontWeight(.semibold)
            }
            .padding(6)
        }
    }

    private func bulkGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox(title) {
            VStack(spacing: 7) {
                content()
            }
            .padding(6)
        }
    }

    private func bulkRow(
        _ title: String,
        _ keyPath: WritableKeyPath<P9BulkEdits, P9BulkNumberEdit>,
        range: ClosedRange<Int>
    ) -> some View {
        let field = binding(keyPath)
        return HStack {
            Toggle(title, isOn: Binding(
                get: { field.wrappedValue.enabled },
                set: { field.wrappedValue.enabled = $0 }
            ))
            Spacer()
            Group {
                Picker("", selection: Binding(
                    get: { field.wrappedValue.mode },
                    set: { field.wrappedValue.mode = $0 }
                )) {
                    ForEach(P9BulkMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                P9BoundedNumberField(
                    value: Binding(
                        get: { field.wrappedValue.value },
                        set: { field.wrappedValue.value = $0 }
                    ),
                    range: field.wrappedValue.mode == .set ? range : -128...128
                )
                Stepper(
                    "",
                    value: Binding(
                        get: { field.wrappedValue.value },
                        set: { field.wrappedValue.value = $0 }
                    ),
                    in: field.wrappedValue.mode == .set ? range : -128...128
                )
                .labelsHidden()
            }
            .disabled(!field.wrappedValue.enabled)
        }
    }

    private func optionalBooleanPicker(_ title: String, value: Binding<Bool?>) -> some View {
        optionalChoicePicker(
            title,
            trueLabel: "Enable",
            falseLabel: "Disable",
            value: value
        )
    }

    private func bulkSamplePicker(
        _ title: String,
        value: Binding<String?>
    ) -> some View {
        Picker(title, selection: value) {
            Text("Unchanged").tag(String?.none)
            Text("No sample").tag(String?.some(""))
            ForEach(availableSampleNames, id: \.self) { sampleName in
                Text(sampleName).tag(String?.some(sampleName))
            }
        }
    }

    private func optionalChoicePicker(
        _ title: String,
        trueLabel: String,
        falseLabel: String,
        value: Binding<Bool?>
    ) -> some View {
        Picker(title, selection: value) {
            Text("Unchanged").tag(Bool?.none)
            Text(trueLabel).tag(Bool?.some(true))
            Text(falseLabel).tag(Bool?.some(false))
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<P9BulkEdits, Value>) -> Binding<Value> {
        Binding(
            get: { edits[keyPath: keyPath] },
            set: { edits[keyPath: keyPath] = $0 }
        )
    }
}
