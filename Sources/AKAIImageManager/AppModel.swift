import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ExternalSampleEditSession: ObservableObject, Identifiable {
    let id = UUID()
    let sourceFile: AkaiFile
    let imageURL: URL
    let volumePath: String
    let wavURL: URL
    let editorURL: URL?
    let originalWAVData: Data
    let originalInspection: WAVInspection
    let originalAttributes: S9SampleAttributes
    let workspace: TemporaryWorkspace
    @Published var isReplacing = false
    @Published var errorMessage: String?

    init(
        sourceFile: AkaiFile,
        imageURL: URL,
        volumePath: String,
        wavURL: URL,
        editorURL: URL?,
        originalWAVData: Data,
        originalInspection: WAVInspection,
        originalAttributes: S9SampleAttributes,
        workspace: TemporaryWorkspace
    ) {
        self.sourceFile = sourceFile
        self.imageURL = imageURL
        self.volumePath = volumePath
        self.wavURL = wavURL
        self.editorURL = editorURL
        self.originalWAVData = originalWAVData
        self.originalInspection = originalInspection
        self.originalAttributes = originalAttributes
        self.workspace = workspace
    }

    var sampleBaseName: String {
        AkaiFilename.sanitizedBase(
            sourceFile.name,
            family: .s900,
            maximumLength: 10
        ).replacingOccurrences(of: "_", with: " ")
    }

    func removeWorkspace() {
        workspace.remove()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: ImageSession?
    @Published private(set) var snapshot = DiskSnapshot()
    @Published var selection = Set<AkaiFile.ID>()
    @Published var fileSortOrder = [KeyPathComparator<AkaiFile>]()
    @Published var progress: OperationProgress?
    @Published var report: OperationReport?
    @Published var diagnosticLog = ""
    @Published var isLogVisible = false
    @Published var showImportSheet = false
    @Published var pendingImportURLs: [URL] = []
    @Published var showFormatSheet = false
    @Published var showDiskInfo = false
    @Published var showDeleteConfirmation = false
    @Published var showDeleteAllConfirmation = false
    @Published var fileInformation: AkaiFileInformation?
    @Published var p9EditorDocument: P9EditorDocument?
    @Published var externalSampleEditSession: ExternalSampleEditSession?
    @Published var incompleteImageURL: URL?
    @Published var currentReadOnlyChoice = false
    @Published private(set) var headerNotice: HeaderNotice?
    @Published private(set) var operationActive = false
    @Published private(set) var keygroupTransfer: P9KeygroupTransfer?

    let settings: AppSettings
    private let controller = AkaiCommandController()
    private var currentOperationTask: Task<Void, Never>?
    private var recentURLs: [URL] = []
    private var keygroupTransferWorkspace: TemporaryWorkspace?
    private var selectionAnchor: AkaiFile.ID?
#if AKAI_TESTING
    var overwriteVerificationMutator: ((Data) -> Data)?
    var s9ReplacementVerificationMutator: ((Data) -> Data)?
#endif

    init(settings: AppSettings) {
        self.settings = settings
        loadRecentImages()
    }

    var isBusy: Bool { operationActive }
    var canMutate: Bool { session != nil && session?.readOnly == false && !isBusy }
    var canImport: Bool { canMutate && isS900Volume }
    var selectedFiles: [AkaiFile] { snapshot.files.filter { selection.contains($0.id) } }
    var displayedFiles: [AkaiFile] {
        guard !fileSortOrder.isEmpty else { return snapshot.files }
        return snapshot.files.sorted(using: fileSortOrder)
    }
    var selectedNativeFiles: [AkaiFile] { selectedFiles.filter { NativeAkaiFileExport.isSupported($0.name) } }
    var availableSampleNames: [String] {
        var seen = Set<String>()
        return snapshot.files.compactMap { file in
            guard file.isSample else { return nil }
            let name = Self.sampleBaseName(file.name)
            let key = Self.normalizedSampleKey(name)
            guard seen.insert(key).inserted else { return nil }
            return name
        }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
    var canExport: Bool {
        selectedFiles.contains {
            $0.isSample || $0.name.pathExtensionUppercased == "P9"
        } && !isBusy
    }
    var canCopyNativeFiles: Bool { !selectedNativeFiles.isEmpty && !isBusy }
    var canRenameSelectedNativeFile: Bool {
        selectedFiles.count == 1
            && NativeAkaiFileExport.isSupported(selectedFiles[0].name)
            && canMutate
    }
    var canShowSelectedFileInformation: Bool {
        selectedFiles.count == 1 && session != nil && !isBusy
    }
    var canEditSelectedP9: Bool {
        selectedFiles.count == 1
            && selectedFiles[0].name.pathExtensionUppercased == "P9"
            && !isBusy
    }
    var canExportSelectedP9ToAbleton: Bool {
        selectedFiles.count == 1
            && selectedFiles[0].name.pathExtensionUppercased == "P9"
            && session != nil
            && isS900Volume
            && !isBusy
    }
    var canCreateP9FromCopiedKeygroups: Bool {
        keygroupTransfer != nil && canImport
    }
    var canCreateP9Program: Bool {
        canImport && p9EditorDocument == nil
    }
    var canEditSelectedS9Sample: Bool {
        selectedFiles.count == 1
            && selectedFiles[0].isSample
            && isS900Volume
            && canMutate
            && externalSampleEditSession == nil
    }
    var isS900Volume: Bool {
        let normalized = snapshot.rawDInfo
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.localizedCaseInsensitiveContains("voltype: S900")
            || normalized.localizedCaseInsensitiveContains("type: S900")
    }
    var recentImages: [URL] { recentURLs }
    var usbCopyDestination: URL? {
        guard let source = session?.imageURL, session?.isRemovable == false else { return nil }
        return USBVolumeResolver.exactCopyDestination(
            source: source,
            mountedVolumes: ImageFileOperations.mountedVolumes()
        )
    }

    func selectFile(_ file: AkaiFile, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        if shift,
           let anchor = selectionAnchor ?? selection.first,
           let anchorIndex = displayedFiles.firstIndex(where: {
            $0.id == anchor
           }),
           let targetIndex = displayedFiles.firstIndex(where: {
            $0.id == file.id
           }) {
            let bounds =
                min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeSelection = Set(bounds.map { displayedFiles[$0].id })
            selection = command
                ? selection.union(rangeSelection)
                : rangeSelection
            return
        }

        if command {
            if selection.contains(file.id) {
                selection.remove(file.id)
            } else {
                selection.insert(file.id)
            }
        } else {
            selection = [file.id]
        }
        selectionAnchor = file.id
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open AKAI Image"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "img") ?? .data,
            UTType(filenameExtension: "iso") ?? .data,
            .data
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start { try await self.openImage(url, readOnly: self.currentReadOnlyChoice) }
    }

    func openRecent(_ url: URL) {
        start { try await self.openImage(url, readOnly: self.currentReadOnlyChoice) }
    }

    func handleOpenURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1,
           first.pathExtension.caseInsensitiveCompare("p9") == .orderedSame {
            openP9Editor(at: first)
            return
        }
        handleDroppedURLs(urls)
    }

    func handleDroppedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1,
           first.pathExtension.caseInsensitiveCompare("p9") == .orderedSame,
           session == nil {
            openP9Editor(at: first)
            return
        }
        if isImportableAudioOrAkaiFile(first) {
            prepareImport(urls.filter(isImportableAudioOrAkaiFile))
        } else {
            start { try await self.openImage(first, readOnly: self.currentReadOnlyChoice) }
        }
    }

    func prepareImport(_ urls: [URL]) {
        guard session != nil else {
            reportError(AppError.noImageOpen)
            return
        }
        guard session?.readOnly == false else {
            reportError(AppError.readOnly)
            return
        }
        guard isS900Volume else {
            reportError(
                AppError.verificationFailed(
                    "AKAI Image Manager imports only S950-format samples and programs."
                )
            )
            return
        }
        guard !isBusy else {
            reportError(AppError.controllerBusy)
            return
        }
        let wavURLs = urls.filter(isWAV)
        let nativeURLs = urls.filter(isNativeAkaiURL)
        if !nativeURLs.isEmpty {
            start {
                try await self.importNativeFiles(nativeURLs, policy: .rename)
                if !wavURLs.isEmpty {
                    self.pendingImportURLs = wavURLs
                    self.showImportSheet = true
                }
            }
        } else if !wavURLs.isEmpty {
            pendingImportURLs = wavURLs
            showImportSheet = true
        }
    }

    func prepareImport(_ urls: [URL], to volume: AkaiVolume) {
        let wavURLs = urls.filter(isWAV)
        let nativeURLs = urls.filter(isNativeAkaiURL)
        guard !wavURLs.isEmpty || !nativeURLs.isEmpty else { return }
        guard canImport else {
            reportError(
                AppError.verificationFailed(
                    "Select a writable S950 volume before importing."
                )
            )
            return
        }
        start {
            _ = try await self.run(try AkaiCommandBuilder.changeDirectory(volume.path))
            try await self.refresh()
            if !nativeURLs.isEmpty {
                try await self.importNativeFiles(nativeURLs, policy: .rename)
            }
            if !wavURLs.isEmpty {
                self.pendingImportURLs = wavURLs
                self.showImportSheet = true
            }
        }
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose WAV or AKAI Files"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .wav,
            UTType(filenameExtension: "s9") ?? .data,
            UTType(filenameExtension: "p9") ?? .data
        ]
        guard panel.runModal() == .OK else { return }
        prepareImport(panel.urls)
    }

    func openP9EditorPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open S950 P9 Program"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p9") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openP9Editor(at: url)
    }

    func openP9Editor(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            p9EditorDocument = try P9EditorDocument(data: data, source: .local(url))
        } catch {
            reportError(error)
        }
    }

    func chooseAbletonDrumRack(for document: P9EditorDocument) {
        guard document.source.imageURL != nil else {
            document.drumRackImportErrorMessage =
                "Open the P9 from a writable S950 IMG before importing an ADG."
            return
        }
        guard canImport else {
            document.drumRackImportErrorMessage =
                "The associated S950 IMG volume is not currently writable."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Ableton Drum Rack"
        panel.prompt = "Read Drum Rack"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "adg") ?? .data
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let preset = try AbletonDrumRackParser.parse(url: url)
            let occupiedKeygroups = document.program.keygroups.filter {
                !$0.softSampleName.isEmpty || !$0.loudSampleName.isEmpty
            }
            let occupiedRanges = occupiedKeygroups.map {
                min($0.lowKey, $0.highKey)...max($0.lowKey, $0.highKey)
            }
            let sourceNotes = preset.samples.map(\.sourceNote)
            let padSpan =
                (sourceNotes.max() ?? 0) - (sourceNotes.min() ?? 0)
            let requestedStart =
                (occupiedKeygroups.map(\.highKey).max() ?? 35) + 1
            let suggestedStart = max(0, min(127 - padSpan, requestedStart))
            let replacesBlankKeygroup =
                document.program.keygroups.count == 1
                && document.program.keygroups[0].isBlankFullRangePlaceholder
            document.abletonImportDraft = AbletonDrumRackImportDraft(
                preset: preset,
                startNote: suggestedStart,
                existingSampleNames: availableSampleNames,
                existingKeygroupCount: document.program.keygroups.count,
                existingKeyRanges: occupiedRanges,
                replacesBlankKeygroup: replacesBlankKeygroup
            )
        } catch {
            document.drumRackImportErrorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func importAbletonDrumRack(
        _ draft: AbletonDrumRackImportDraft,
        into document: P9EditorDocument
    ) {
        document.abletonImportDraft = nil
        start {
            document.isImportingDrumRack = true
            document.drumRackImportErrorMessage = nil
            document.drumRackImportMessage = nil
            defer {
                document.isImportingDrumRack = false
                self.progress = nil
            }
            do {
                try await self.performAbletonDrumRackImport(
                    draft,
                    into: document
                )
            } catch {
                document.drumRackImportErrorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if self.settings.autoOpenLogOnError {
                    self.isLogVisible = true
                }
            }
        }
    }

    func performAbletonDrumRackImport(
        _ draft: AbletonDrumRackImportDraft,
        into document: P9EditorDocument
    ) async throws {
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "Ableton Drum Rack import is supported only for S950 volumes."
            )
        }
        guard let sourceImageURL = document.source.imageURL,
              sourceImageURL.standardizedFileURL
                == activeSession.imageURL.standardizedFileURL
        else {
            throw AppError.verificationFailed(
                "The P9 editor is not associated with the open IMG."
            )
        }
        if let sourceVolumePath = document.source.volumePath,
           sourceVolumePath != snapshot.currentPath {
            throw AppError.verificationFailed(
                "Return to the exact destination volume before importing the Drum Rack."
            )
        }
        if let validationError = draft.validationError {
            throw AppError.verificationFailed(validationError)
        }
        let desiredNames = draft.rows.map {
            draft.cleanedSampleName($0.sampleName)
        }
        let existingKeys = Set(availableSampleNames.map(Self.normalizedSampleKey))
        if let collision = desiredNames.first(where: {
            existingKeys.contains(Self.normalizedSampleKey($0))
        }) {
            throw AppError.verificationFailed(
                "\(collision) now exists in the destination volume. Reopen the import preview and choose another name."
            )
        }
        if let maximum = snapshot.maximumFileCount,
           snapshot.fileCount + draft.rows.count > maximum {
            throw AppError.verificationFailed(
                "The destination volume does not have enough file slots for "
                    + "\(draft.rows.count) new S9 samples."
            )
        }

        let estimatedBytes = try draft.rows.reduce(Int64(0)) { total, row in
            total + Int64(
                try row.source.sampleURL
                    .resourceValues(forKeys: [.fileSizeKey])
                    .fileSize ?? 0
            )
        }
        if snapshot.freeBytes > 0, estimatedBytes > snapshot.freeBytes {
            throw AppError.insufficientSpace(
                required: estimatedBytes,
                available: snapshot.freeBytes
            )
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-ableton-import")
        defer { workspace.remove() }
        let options = ImportOptions(
            family: .s900,
            compressedS900: draft.compressedSamples,
            convertToMono: true,
            preserveSampleRate: true,
            collisionPolicy: .rename
        )
        var preparedFiles: [(name: String, url: URL)] = []
        progress = OperationProgress(
            kind: .importing,
            current: 0,
            total: draft.rows.count * 2 + 1,
            detail: "Preparing Ableton samples"
        )

        for (offset, row) in draft.rows.enumerated() {
            try Task.checkCancellation()
            let name = draft.cleanedSampleName(row.sampleName)
            let stagingBase = draft.stagingBaseName(row.sampleName)
            updateProgress(offset, detail: "Preparing \(name)")
            let prepared = try prepareWAVForS950Import(
                row.source.sampleURL,
                in: workspace.url,
                options: options,
                finalBase: stagingBase
            )
            preparedFiles.append((name, prepared.url))
        }

        _ = try await run(
            try AkaiCommandBuilder.localDirectory(workspace.url.path)
        )
        do {
            for (offset, item) in preparedFiles.enumerated() {
                try Task.checkCancellation()
                updateProgress(
                    draft.rows.count + offset,
                    detail: "Importing \(item.name).S9"
                )
                _ = try await run(
                    try AkaiCommandBuilder.importWAV(
                        filename: item.url.lastPathComponent,
                        options: options
                    )
                )
            }

            updateProgress(
                draft.rows.count * 2,
                detail: "Verifying imported samples"
            )
            try await refresh()
            let storedKeys = Set(availableSampleNames.map(Self.normalizedSampleKey))
            let missing = desiredNames.filter {
                !storedKeys.contains(Self.normalizedSampleKey($0))
            }
            guard missing.isEmpty else {
                throw AppError.verificationFailed(
                    "AKAI Util did not report the imported S9 sample"
                        + "\(missing.count == 1 ? "" : "s"): "
                        + missing.joined(separator: ", ")
                )
            }

            var finalizedDraft = draft
            for index in finalizedDraft.rows.indices {
                let requestedName = desiredNames[index]
                guard let storedName = availableSampleNames.first(where: {
                    Self.normalizedSampleKey($0)
                        == Self.normalizedSampleKey(requestedName)
                }) else {
                    throw AppError.verificationFailed(
                        "Could not resolve the exact sampler-visible name for \(requestedName)."
                    )
                }
                finalizedDraft.rows[index].sampleName = storedName
            }
            let updatedProgram = try finalizedDraft.appendingKeygroups(
                to: document.program
            )
            document.replaceProgram(
                with: updatedProgram,
                refreshEditor: true
            )
            document.drumRackImportMessage =
                "Imported \(draft.rows.count) S9 sample"
                + "\(draft.rows.count == 1 ? "" : "s") and added "
                + "\(draft.rows.count) keygroup"
                + "\(draft.rows.count == 1 ? "" : "s")."
            publishSuccess(
                title: "Ableton Drum Rack Imported",
                lines: [
                    "\(draft.rows.count) WAV files were converted and imported as S9 samples.",
                    "The mapped keygroups were added to \(document.source.filename); save or overwrite the P9 when ready."
                ]
            )
        } catch {
            let importMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            do {
                try await refresh()
                let desiredKeys = Set(desiredNames.map(Self.normalizedSampleKey))
                let importedFiles = snapshot.files.filter {
                    $0.isSample
                        && desiredKeys.contains(
                            Self.normalizedSampleKey(
                                Self.sampleBaseName($0.name)
                            )
                        )
                }
                for index in AkaiCommandBuilder.deletionOrder(
                    importedFiles.map(\.index)
                ) {
                    _ = try await run(try AkaiCommandBuilder.delete(index: index))
                }
                if !importedFiles.isEmpty {
                    try await refresh()
                }
            } catch {
                let cleanupMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                throw AppError.verificationFailed(
                    "Drum Rack import failed and its partial S9 samples could not all be removed. "
                        + "Import error: \(importMessage) Cleanup error: \(cleanupMessage)"
                )
            }
            throw AppError.verificationFailed(
                "Drum Rack import did not complete. Any newly imported S9 samples were removed. Cause: \(importMessage)"
            )
        }
    }

    func editSelectedP9() {
        guard canEditSelectedP9, let file = selectedFiles.first else { return }
        editP9(file)
    }

    func editP9(withIDs ids: Set<AkaiFile.ID>) {
        let matches = snapshot.files.filter {
            ids.contains($0.id) && $0.name.pathExtensionUppercased == "P9"
        }
        guard matches.count == 1 else { return }
        editP9(matches[0])
    }

    func openEditor(
        for file: AkaiFile,
        launchExternalEditor: Bool = false
    ) {
        selection = [file.id]
        if file.name.pathExtensionUppercased == "P9" {
            editP9(file)
        } else if file.isSample {
            editSelectedSampleInAudioEditor(
                launchEditor: launchExternalEditor
            )
        }
    }

    func containsSingleP9(withIDs ids: Set<AkaiFile.ID>) -> Bool {
        snapshot.files.filter {
            ids.contains($0.id) && $0.name.pathExtensionUppercased == "P9"
        }.count == 1
    }

    func canExportP9ToAbleton(withIDs ids: Set<AkaiFile.ID>) -> Bool {
        session != nil
            && isS900Volume
            && !isBusy
            && containsSingleP9(withIDs: ids)
    }

    func copyKeygroups(
        from program: P9Program,
        indexes: Set<Int>,
        source: P9EditorDocument.Source
    ) {
        guard !indexes.isEmpty else { return }
        start {
            try await self.stageKeygroupTransfer(
                from: program,
                indexes: indexes,
                source: source
            )
        }
    }

    func pasteKeygroups(into document: P9EditorDocument) {
        guard let transfer = keygroupTransfer else {
            reportError(
                AppError.verificationFailed("Copy one or more keygroups before pasting.")
            )
            return
        }
        start {
            try await self.applyKeygroupTransfer(transfer, to: document)
        }
    }

    func overwriteP9InImage(
        _ document: P9EditorDocument,
        createBackup: Bool
    ) {
        start {
            document.isOverwritingInImage = true
            defer {
                document.isOverwritingInImage = false
                self.progress = nil
            }
            do {
                _ = try await self.performP9Overwrite(
                    document,
                    createBackup: createBackup
                )
            } catch {
                document.overwriteErrorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if self.settings.autoOpenLogOnError {
                    self.isLogVisible = true
                }
            }
        }
    }

    func createP9Program() {
        guard session != nil else {
            reportError(AppError.noImageOpen)
            return
        }
        guard session?.readOnly == false else {
            reportError(AppError.readOnly)
            return
        }
        guard isS900Volume else {
            reportError(
                AppError.verificationFailed(
                    "New programs can be created only in an S950 IMG."
                )
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "New S950 Program"
        alert.informativeText =
            "Enter a name of up to 10 characters. The program will open with one blank keygroup so you can assign samples and settings before creating it in the IMG."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create Program")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.placeholderString = "PROGRAM"
        nameField.stringValue = suggestedBlankProgramName()
        alert.accessoryView = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            p9EditorDocument = try prepareBlankP9Program(named: nameField.stringValue)
        } catch {
            reportError(error)
        }
    }

    func prepareBlankP9Program(named requestedName: String) throws -> P9EditorDocument {
        guard let session else { throw AppError.noImageOpen }
        guard !session.readOnly else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "New programs can be created only in an S950 IMG."
            )
        }

        let programName = AkaiFilename.sanitizedBase(
            requestedName,
            family: .s900,
            maximumLength: 10
        )
        guard !programName.isEmpty else {
            throw AppError.verificationFailed("Enter a program name.")
        }
        let filename = "\(programName).P9"
        guard p9File(matchingNameKey: Self.normalizedP9NameKey(filename)) == nil else {
            throw AppError.verificationFailed(
                "\(filename) already exists in this volume. Choose another name."
            )
        }
        let program = try P9Program.blank(named: programName)
        return try P9EditorDocument(
            data: program.encoded(),
            source: .newImageProgram(
                filename: filename,
                imageURL: session.imageURL,
                volumePath: snapshot.currentPath
            )
        )
    }

    func createP9InImage(_ document: P9EditorDocument) {
        start {
            document.isCreatingInImage = true
            document.createErrorMessage = nil
            defer {
                document.isCreatingInImage = false
                self.progress = nil
            }
            do {
                try await self.performCreateP9InImage(document)
            } catch {
                document.createErrorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if self.settings.autoOpenLogOnError {
                    self.isLogVisible = true
                }
            }
        }
    }

    func performCreateP9InImage(_ document: P9EditorDocument) async throws {
        guard case .newImageProgram(
            let sourceFilename,
            let sourceImageURL,
            let sourceVolumePath
        ) = document.source else {
            throw AppError.verificationFailed(
                "Create in IMG is available only for a new program."
            )
        }
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "New programs can be created only in an S950 IMG."
            )
        }
        guard activeSession.imageURL.standardizedFileURL
                == sourceImageURL.standardizedFileURL,
              snapshot.currentPath == sourceVolumePath
        else {
            throw AppError.verificationFailed(
                "The exact destination IMG volume is no longer open. Return to that volume before creating this P9."
            )
        }
        guard document.pendingKeygroupPaste == nil,
              !document.isPreparingKeygroupPaste
        else {
            throw AppError.verificationFailed(
                "Apply the pasted keygroups before creating the P9."
            )
        }
        guard !document.program.keygroups.isEmpty else {
            throw P9ProgramError.mustKeepOneKeygroup
        }

        let sourceNameKey = Self.normalizedP9NameKey(sourceFilename)
        let programNameKey = Self.normalizedP9NameKey("\(document.program.name).P9")
        guard sourceNameKey == programNameKey else {
            throw AppError.verificationFailed(
                "The program name must match the new P9 filename."
            )
        }
        guard p9File(matchingNameKey: sourceNameKey) == nil else {
            throw AppError.verificationFailed(
                "\(sourceFilename) already exists in this volume. The app will not replace it during program creation."
            )
        }
        if let maximum = snapshot.maximumFileCount,
           snapshot.fileCount + 1 > maximum {
            throw AppError.verificationFailed(
                "The destination volume has reached its \(maximum)-file limit."
            )
        }

        let programData = try document.program.encoded()
        if snapshot.freeBytes > 0, Int64(programData.count) > snapshot.freeBytes {
            throw AppError.insufficientSpace(
                required: Int64(programData.count),
                available: snapshot.freeBytes
            )
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-p9-create")
        defer { workspace.remove() }
        let stagedFilename = "\(sourceNameKey).P9"
        let stagedURL = workspace.url.appendingPathComponent(stagedFilename)
        try programData.write(to: stagedURL, options: .atomic)

        progress = OperationProgress(
            kind: .importing,
            current: 0,
            total: 4,
            detail: "Preparing \(stagedFilename)"
        )
        _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))

        do {
            updateProgress(1, detail: "Creating \(stagedFilename) in the IMG")
            _ = try await run(
                try AkaiCommandBuilder.importNative(filename: stagedFilename)
            )

            updateProgress(2, detail: "Re-reading the destination volume")
            try await refresh()
            guard let storedFile = p9File(matchingNameKey: sourceNameKey) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not create \(stagedFilename) in the destination volume."
                )
            }

            try FileManager.default.removeItem(at: stagedURL)
            let filesBeforeVerification = Set(
                try FileManager.default.contentsOfDirectory(
                    at: workspace.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).map(\.standardizedFileURL)
            )
            updateProgress(3, detail: "Exporting \(storedFile.name) for byte verification")
            _ = try await run(try AkaiCommandBuilder.exportNative(index: storedFile.index))
            let filesAfterVerification = try FileManager.default.contentsOfDirectory(
                at: workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard let exported = filesAfterVerification.first(where: {
                !filesBeforeVerification.contains($0.standardizedFileURL)
                    && $0.pathExtension.caseInsensitiveCompare("p9") == .orderedSame
            }) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not export the new P9 for verification."
                )
            }
            let normalizedExport = try NativeAkaiFileExport.normalizeExportedFile(
                exported,
                expectedFilename: storedFile.name
            )
            let exportedData = try Data(contentsOf: normalizedExport)
            guard exportedData == programData else {
                throw AppError.verificationFailed(
                    "The P9 exported from the IMG differs from the new program data."
                )
            }

            updateProgress(4, detail: "New program verified")
            try document.markCreatedInImage(with: exportedData)
            publishSuccess(
                title: "S950 Program Created and Verified",
                lines: [
                    "\(storedFile.name) was created in \(activeSession.imageURL.lastPathComponent).",
                    "The stored P9 matched every prepared byte."
                ]
            )
        } catch {
            let originalMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            do {
                try await refresh()
                if let createdFile = p9File(matchingNameKey: sourceNameKey) {
                    _ = try await run(
                        try AkaiCommandBuilder.delete(index: createdFile.index)
                    )
                    try await refresh()
                }
            } catch {
                let cleanupMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                throw AppError.verificationFailed(
                    "Program creation failed and the incomplete P9 could not be removed automatically. Check \(sourceFilename) before using the IMG. Creation error: \(originalMessage) Cleanup error: \(cleanupMessage)"
                )
            }
            throw AppError.verificationFailed(
                "Program creation did not complete. Any incomplete \(sourceFilename) was removed. Cause: \(originalMessage)"
            )
        }
    }

    func performP9Overwrite(
        _ document: P9EditorDocument,
        createBackup: Bool = true
    ) async throws -> P9OverwriteResult {
        guard case .image(let sourceFilename, let sourceImageURL) = document.source
        else {
            throw AppError.verificationFailed(
                "Overwrite is available only for a P9 opened from an IMG."
            )
        }
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        guard activeSession.imageURL.standardizedFileURL
                == sourceImageURL.standardizedFileURL
        else {
            throw AppError.verificationFailed(
                "The exact source IMG is no longer open. Reopen this P9 before overwriting."
            )
        }
        guard document.pendingKeygroupPaste == nil,
              !document.isPreparingKeygroupPaste
        else {
            throw AppError.verificationFailed(
                "Apply the pasted keygroups before overwriting the P9."
            )
        }

        let sourceNameKey = Self.normalizedP9NameKey(sourceFilename)
        let programNameKey = Self.normalizedP9NameKey("\(document.program.name).P9")
        guard sourceNameKey == programNameKey else {
            throw AppError.verificationFailed(
                "The program name has changed. To overwrite safely, keep the original name "
                    + "\((sourceFilename as NSString).deletingPathExtension). "
                    + "Use Save Edited Copy to create a renamed program."
            )
        }
        guard let originalFile = p9File(matchingNameKey: sourceNameKey) else {
            throw AppError.verificationFailed(
                "\(sourceFilename) is no longer present in the open IMG."
            )
        }

        let editedData = try document.program.encoded()
        guard editedData != document.originalData else {
            throw AppError.verificationFailed("There are no applied P9 changes to overwrite.")
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-p9-overwrite")
        defer { workspace.remove() }
        let stagedFilename = "\(sourceNameKey).P9"
        let stagedURL = workspace.url.appendingPathComponent(stagedFilename)
        try editedData.write(to: stagedURL, options: .atomic)

        progress = OperationProgress(
            kind: .overwriting,
            current: 0,
            total: 5,
            detail: "Closing the IMG safely"
        )
        await controller.close()

        let backupURL: URL?
        do {
            if createBackup {
                updateProgress(1, detail: "Creating and verifying a complete IMG backup")
                backupURL = try createTimestampedBackup(
                    of: activeSession.imageURL
                )
            } else {
                updateProgress(1, detail: "Continuing without an IMG backup")
                backupURL = nil
            }
            try await reopenImageSession(activeSession)
        } catch {
            try? await reopenImageSession(activeSession)
            throw error
        }

        var mutationStarted = false
        do {
            guard let currentFile = p9File(matchingNameKey: sourceNameKey) else {
                throw AppError.verificationFailed(
                    "\(originalFile.name) disappeared before overwrite began."
                )
            }

            updateProgress(2, detail: "Replacing \(currentFile.name)")
            _ = try await run(
                try AkaiCommandBuilder.localDirectory(workspace.url.path)
            )
            mutationStarted = true
            _ = try await run(try AkaiCommandBuilder.delete(index: currentFile.index))
            _ = try await run(
                try AkaiCommandBuilder.importNative(filename: stagedFilename)
            )

            updateProgress(3, detail: "Re-reading the destination volume")
            try await refresh()
            guard let storedFile = p9File(matchingNameKey: sourceNameKey) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not restore \(sourceFilename) after replacement."
                )
            }

            try FileManager.default.removeItem(at: stagedURL)
            let filesBeforeVerification = Set(
                try FileManager.default.contentsOfDirectory(
                    at: workspace.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).map(\.standardizedFileURL)
            )
            updateProgress(4, detail: "Exporting \(storedFile.name) for byte verification")
            _ = try await run(try AkaiCommandBuilder.exportNative(index: storedFile.index))
            let filesAfterVerification = try FileManager.default.contentsOfDirectory(
                at: workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard let exported = filesAfterVerification.first(where: {
                !filesBeforeVerification.contains($0.standardizedFileURL)
                    && $0.pathExtension.caseInsensitiveCompare("p9") == .orderedSame
            }) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not export the replaced P9 for verification."
                )
            }
            let normalizedExport = try NativeAkaiFileExport.normalizeExportedFile(
                exported,
                expectedFilename: storedFile.name
            )
            let exportedData = try Data(contentsOf: normalizedExport)
            var verifiedData = exportedData
#if AKAI_TESTING
            verifiedData = overwriteVerificationMutator?(exportedData) ?? exportedData
#endif
            guard verifiedData == editedData else {
                throw AppError.verificationFailed(
                    "The P9 exported from the IMG differs from the edited data."
                )
            }

            updateProgress(5, detail: "Overwrite verified")
            try document.markOverwritten(with: verifiedData)
            let result = P9OverwriteResult(
                filename: storedFile.name,
                backupURL: backupURL,
                verifiedByteCount: verifiedData.count
            )
            var successLines = [
                "\(storedFile.name) was replaced and verified byte-for-byte."
            ]
            if let backupURL {
                successLines.append("Backup: \(backupURL.path)")
            } else {
                successLines.append("No IMG backup was created.")
            }
            publishSuccess(
                title: "P9 Overwritten and Verified",
                lines: successLines
            )
            return result
        } catch {
            guard mutationStarted else { throw error }
            let originalMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            guard let backupURL else {
                try? await refresh()
                throw AppError.verificationFailed(
                    "P9 overwrite did not complete and no IMG backup was created, so automatic rollback is unavailable. Do not use the IMG until it has been checked or restored manually. Cause: \(originalMessage)"
                )
            }
            do {
                try await restoreImageSession(activeSession, from: backupURL)
            } catch {
                let rollbackMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                session = nil
                snapshot = DiskSnapshot()
                selection.removeAll()
                throw AppError.verificationFailed(
                    "P9 overwrite failed and automatic IMG restoration also failed. "
                        + "Do not use the destination IMG. Restore it manually from "
                        + "\(backupURL.path). Overwrite error: \(originalMessage) "
                        + "Restoration error: \(rollbackMessage)"
                )
            }
            throw AppError.verificationFailed(
                "P9 overwrite did not complete. The original IMG was restored and verified "
                    + "from \(backupURL.lastPathComponent). Cause: \(originalMessage)"
            )
        }
    }

    func createP9FromCopiedKeygroups() {
        guard let transfer = keygroupTransfer else {
            reportError(
                AppError.verificationFailed("Copy one or more keygroups before creating a program.")
            )
            return
        }
        guard session != nil else {
            reportError(AppError.noImageOpen)
            return
        }
        guard session?.readOnly == false else {
            reportError(AppError.readOnly)
            return
        }

        let alert = NSAlert()
        alert.messageText = "New Program from Copied Keygroups"
        alert.informativeText =
            "Name the destination program. The copied keygroups and their samples will be prepared for this IMG."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create Program")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.placeholderString = "PROGRAM"
        nameField.stringValue = suggestedProgramName(for: transfer)
        alert.accessoryView = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let programName = AkaiFilename.sanitizedBase(
            nameField.stringValue,
            family: .s900,
            maximumLength: 10
        )
        start {
            self.p9EditorDocument = try await self.prepareP9FromCopiedKeygroups(
                named: programName
            )
        }
    }

    func prepareP9FromCopiedKeygroups(
        named requestedName: String
    ) async throws -> P9EditorDocument {
        guard let transfer = keygroupTransfer else {
            throw AppError.verificationFailed(
                "Copy one or more keygroups before creating a program."
            )
        }
        guard let session else { throw AppError.noImageOpen }
        guard !session.readOnly else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "New programs can be created only in an S950 IMG."
            )
        }

        let programName = AkaiFilename.sanitizedBase(
            requestedName,
            family: .s900,
            maximumLength: 10
        )
        var program = try P9Program(data: transfer.programHeaderTemplate)
        program.name = programName
        let filename = "\(programName).P9"
        let document = try P9EditorDocument(
            data: program.encoded(),
            source: .newImageProgram(
                filename: filename,
                imageURL: session.imageURL,
                volumePath: snapshot.currentPath
            )
        )
        try await applyKeygroupTransfer(transfer, to: document)
        guard try document.applyPendingKeygroupPaste() != nil else {
            throw AppError.verificationFailed(
                "The copied keygroups were prepared but could not be applied to the new program."
            )
        }
        return document
    }

    private func suggestedProgramName(for transfer: P9KeygroupTransfer) -> String {
        let base = AkaiFilename.sanitizedBase(
            transfer.sourceProgramName,
            family: .s900,
            maximumLength: 10
        )
        let existing = Set(
            snapshot.files.compactMap { file -> String? in
                guard file.name.pathExtensionUppercased == "P9" else { return nil }
                return (file.name as NSString).deletingPathExtension.uppercased()
            }
        )
        return AkaiFilename.uniqueName(
            base: base,
            existing: existing,
            maximumLength: 10
        )
    }

    private func suggestedBlankProgramName() -> String {
        let existing = Set(
            snapshot.files.compactMap { file -> String? in
                guard file.name.pathExtensionUppercased == "P9" else { return nil }
                return (file.name as NSString).deletingPathExtension.uppercased()
            }
        )
        return AkaiFilename.uniqueName(
            base: "PROGRAM",
            existing: existing,
            maximumLength: 10
        )
    }

    private func p9File(matchingNameKey nameKey: String) -> AkaiFile? {
        snapshot.files.first {
            $0.name.pathExtensionUppercased == "P9"
                && Self.normalizedP9NameKey($0.name) == nameKey
        }
    }

    private static func normalizedP9NameKey(_ filename: String) -> String {
        AkaiFilename.sanitizedBase(
            filename,
            family: .s900,
            maximumLength: 10
        ).uppercased()
    }

    private func reopenImageSession(_ previousSession: ImageSession) async throws {
        let opened = try await controller.open(
            imageURL: previousSession.imageURL,
            executableURL: settings.executableURL,
            readOnly: previousSession.readOnly
        )
        appendLog(opened)
        session = ImageSession(
            imageURL: previousSession.imageURL,
            readOnly: previousSession.readOnly,
            removableVolumeURL: previousSession.removableVolumeURL,
            openedAt: Date()
        )
        try await refresh()
    }

    private func restoreImageSession(
        _ previousSession: ImageSession,
        from backupURL: URL
    ) async throws {
        await controller.close()
        try ImageFileOperations.copyAtomicallyAndVerify(
            source: backupURL,
            destination: previousSession.imageURL
        )
        try await reopenImageSession(previousSession)
    }

    private func editP9(_ file: AkaiFile) {
        guard !isBusy else { return }
        start {
            guard let session = self.session else { throw AppError.noImageOpen }
            self.progress = OperationProgress(
                kind: .exporting,
                current: 0,
                total: 1,
                detail: "Opening \(file.name)"
            )
            let workspace = try TemporaryWorkspace(prefix: "akai-p9-editor")
            defer { workspace.remove() }
            _ = try await self.run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
            _ = try await self.run(try AkaiCommandBuilder.exportNative(index: file.index))
            let exports = try FileManager.default.contentsOfDirectory(
                at: workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.caseInsensitiveCompare("p9") == .orderedSame }
            guard let exported = exports.first else {
                throw AppError.verificationFailed("AKAI Util did not export \(file.name).")
            }
            let normalized = try NativeAkaiFileExport.normalizeExportedFile(
                exported,
                expectedFilename: file.name
            )
            let data = try Data(contentsOf: normalized)
            self.p9EditorDocument = try P9EditorDocument(
                data: data,
                source: .image(
                    filename: file.name,
                    imageURL: session.imageURL
                )
            )
            self.progress = nil
        }
    }

    func importNativeFiles(_ urls: [URL], policy: CollisionPolicy) async throws {
        guard session != nil else { throw AppError.noImageOpen }
        guard session?.readOnly == false else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "Native import is supported only for S950-format S9 and P9 files."
            )
        }
        let totalBytes = try urls.reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        if snapshot.freeBytes > 0, totalBytes > snapshot.freeBytes {
            throw AppError.insufficientSpace(required: totalBytes, available: snapshot.freeBytes)
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-native-import")
        defer { workspace.remove() }
        _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
        var existingNames = Set(snapshot.files.map { $0.name.uppercased() })
        var lines: [String] = []
        progress = OperationProgress(kind: .importing, current: 0, total: urls.count, detail: "Preparing AKAI files")

        for (offset, source) in urls.enumerated() {
            try Task.checkCancellation()
            let fileExtension = source.pathExtension.uppercased()
            guard fileExtension == "S9" || fileExtension == "P9" else { continue }
            var base = AkaiFilename.sanitizedBase(source.lastPathComponent, family: .s900)
            var filename = "\(base).\(fileExtension)"
            if existingNames.contains(filename.uppercased()) {
                switch policy {
                case .skip:
                    lines.append("Skipped \(source.lastPathComponent): \(filename) already exists.")
                    updateProgress(offset + 1, detail: source.lastPathComponent)
                    continue
                case .replace:
                    _ = try await run(try AkaiCommandBuilder.delete(path: filename))
                case .rename:
                    let existingBases = Set(existingNames.compactMap { name -> String? in
                        guard (name as NSString).pathExtension == fileExtension else { return nil }
                        return (name as NSString).deletingPathExtension
                    })
                    base = AkaiFilename.uniqueName(base: base, existing: existingBases, maximumLength: 10)
                    filename = "\(base).\(fileExtension)"
                }
            }

            updateProgress(offset, detail: "Preparing \(source.lastPathComponent)")
            let stagedURL = workspace.url.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: stagedURL)
            if fileExtension == "S9" {
                try S9NativeSample.renameInternalName(in: stagedURL, to: base)
            }
            _ = try await run(try AkaiCommandBuilder.importNative(filename: filename))
            existingNames.insert(filename.uppercased())
            lines.append("\(source.lastPathComponent) → \(filename) (native AKAI file, unchanged)")
            updateProgress(offset + 1, detail: source.lastPathComponent)
        }
        try await refresh()
        publishSuccess(title: "AKAI File Import Complete", lines: lines)
        progress = nil
    }

    func isNativeAkaiFile(_ file: AkaiFile) -> Bool {
        NativeAkaiFileExport.isSupported(file.name)
    }

    func nativeFilesForDrag(startingWith file: AkaiFile) -> [AkaiFile] {
        guard isNativeAkaiFile(file) else { return [] }
        if !selection.contains(file.id) {
            selection = [file.id]
            selectionAnchor = file.id
        }
        return displayedFiles.filter {
            selection.contains($0.id) && isNativeAkaiFile($0)
        }
    }

    func nativeDragProvider(for file: AkaiFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = NativeAkaiFileExport.dragSuggestedName(for: file.name)
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let transferProgress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await self.exportNativeFileForDrag(file)
                    transferProgress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return transferProgress
        }
        return provider
    }

    private func exportNativeFileForDrag(_ file: AkaiFile) async throws -> URL {
        let exports = try await exportNativeFilesForDrag([file])
        guard let exported = exports[file.id] else {
            throw AppError.verificationFailed("AKAI Util did not create \(file.name).")
        }
        return exported
    }

    func exportNativeFilesForDrag(
        _ files: [AkaiFile]
    ) async throws -> [AkaiFile.ID: URL] {
        let nativeFiles = files.filter(isNativeAkaiFile)
        guard !nativeFiles.isEmpty, nativeFiles.count == files.count else {
            throw AppError.verificationFailed(
                "Only native S9 and P9 files can be dragged to Finder."
            )
        }
        guard session != nil else { throw AppError.noImageOpen }
        guard !operationActive else { throw AppError.controllerBusy }
        operationActive = true
        progress = OperationProgress(
            kind: .exporting,
            current: 0,
            total: nativeFiles.count,
            detail: nativeFiles.count == 1
                ? nativeFiles[0].name
                : "Preparing \(nativeFiles.count) original files"
        )
        defer {
            progress = nil
            operationActive = false
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-native-drag")
        do {
            var results: [AkaiFile.ID: URL] = [:]
            for (offset, file) in nativeFiles.enumerated() {
                try Task.checkCancellation()
                let fileWorkspace = workspace.url.appendingPathComponent(
                    String(offset),
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: fileWorkspace,
                    withIntermediateDirectories: true
                )
                progress = OperationProgress(
                    kind: .exporting,
                    current: offset,
                    total: nativeFiles.count,
                    detail: file.name
                )
                _ = try await run(
                    try AkaiCommandBuilder.localDirectory(fileWorkspace.path)
                )
                _ = try await run(
                    try AkaiCommandBuilder.exportNative(index: file.index)
                )
                let exportedFiles = try FileManager.default.contentsOfDirectory(
                    at: fileWorkspace,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                guard let exported = exportedFiles.first(where: {
                    NativeAkaiFileExport.isSupported($0.lastPathComponent)
                }) else {
                    throw AppError.verificationFailed(
                        "AKAI Util did not create \(file.name)."
                    )
                }
                results[file.id] = try NativeAkaiFileExport.normalizeExportedFile(
                    exported,
                    expectedFilename: file.name
                )
                progress = OperationProgress(
                    kind: .exporting,
                    current: offset + 1,
                    total: nativeFiles.count,
                    detail: file.name
                )
            }
            let workspaceURL = workspace.url
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                try? FileManager.default.removeItem(at: workspaceURL)
            }
            return results
        } catch {
            workspace.remove()
            throw error
        }
    }

    func openImage(_ url: URL, readOnly: Bool) async throws {
        progress = OperationProgress(kind: .opening, current: 0, total: 1, detail: url.lastPathComponent)
        headerNotice = nil
        fileInformation = nil
        discardExternalSampleEditSession()
        await controller.close()
        session = nil
        snapshot = DiskSnapshot()
        selection.removeAll()
        let result = try await controller.open(
            imageURL: url.standardizedFileURL,
            executableURL: settings.executableURL,
            readOnly: readOnly
        )
        appendLog(result)
        session = ImageSession(
            imageURL: url.standardizedFileURL,
            readOnly: readOnly,
            removableVolumeURL: USBVolumeResolver.owningVolume(for: url),
            openedAt: Date()
        )
        remember(url)
        try await refresh()
        progress = nil
    }

    func closeImage() {
        start {
            self.discardExternalSampleEditSession()
            await self.controller.close()
            self.session = nil
            self.snapshot = DiskSnapshot()
            self.selection.removeAll()
            self.headerNotice = nil
            self.fileInformation = nil
        }
    }

    func shutdown() async {
        currentOperationTask?.cancel()
        discardExternalSampleEditSession()
        await controller.close()
        session = nil
        snapshot = DiskSnapshot()
        selection.removeAll()
        progress = nil
        fileInformation = nil
        operationActive = false
        keygroupTransferWorkspace?.remove()
        keygroupTransferWorkspace = nil
        keygroupTransfer = nil
    }

    private func discardExternalSampleEditSession() {
        externalSampleEditSession?.removeWorkspace()
        externalSampleEditSession = nil
    }

    func refreshAction() {
        start { try await self.refresh() }
    }

    func refresh() async throws {
        guard session != nil else { throw AppError.noImageOpen }
        let existing = progress
        if progress == nil {
            progress = OperationProgress(kind: .refreshing, current: 0, total: 4, detail: "Reading disk layout")
        }
        let df = try await run("df")
        updateProgress(1, detail: "Reading volumes")
        let recursive = try await run("dirrec")
        updateProgress(2, detail: "Reading current volume")
        let directory = try await run("dir")
        updateProgress(3, detail: "Reading disk details")
        let dinfo = try await run("dinfo")

        let diskData = AkaiOutputParser.parseDF(df.output)
        let fileData = AkaiOutputParser.parseDirectory(directory.output)
        var next = DiskSnapshot()
        next.disks = diskData.0
        next.partitions = diskData.1
        next.volumes = AkaiOutputParser.parseVolumes(recursive.output)
        next.files = fileData.0
        next.maximumFileCount = fileData.1
        next.fileCount = max(fileData.2, fileData.0.count)
        next.currentPath = AkaiOutputParser.currentPath(directory.output) ?? snapshot.currentPath
        next.rawDF = df.cleanedOutput
        next.rawDInfo = dinfo.cleanedOutput
        next.rawDirectory = directory.cleanedOutput
        snapshot = next
        selection = selection.intersection(Set(next.files.map(\.id)))
        updateProgress(4, detail: "Ready")
        if existing == nil { progress = nil }
    }

    func navigate(to volume: AkaiVolume) {
        start {
            _ = try await self.run(try AkaiCommandBuilder.changeDirectory(volume.path))
            try await self.refresh()
        }
    }

    func performImport(
        options: ImportOptions,
        requestedNames: [String: String] = [:]
    ) {
        let urls = pendingImportURLs
        showImportSheet = false
        start {
            try await self.importWAVs(
                urls,
                options: options,
                requestedNames: requestedNames
            )
        }
    }

    func importWAVs(
        _ urls: [URL],
        options: ImportOptions,
        requestedNames: [String: String] = [:]
    ) async throws {
        guard session != nil else { throw AppError.noImageOpen }
        guard session?.readOnly == false else { throw AppError.readOnly }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "WAV import is supported only for S950 volumes."
            )
        }
        var requestedBases: [String: String] = [:]
        var baseSources: [String: URL] = [:]
        for source in urls {
            let path = source.standardizedFileURL.path
            let requested = requestedNames[path]
                ?? AkaiFilename.sanitizedBase(
                    source.lastPathComponent,
                    family: options.family
                )
            if let validationError = AkaiFilename.s950BaseValidationError(
                requested
            ) {
                throw AppError.verificationFailed(
                    "\(source.lastPathComponent): \(validationError)"
                )
            }
            let base = AkaiFilename.normalizedS950Base(requested)
            if let otherSource = baseSources[base] {
                throw AppError.verificationFailed(
                    "\(source.lastPathComponent) and \(otherSource.lastPathComponent) both request \(base).S9. Enter a different name for one of them."
                )
            }
            requestedBases[path] = base
            baseSources[base] = source
        }
        let estimatedBytes = try urls.reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        if snapshot.freeBytes > 0, estimatedBytes > snapshot.freeBytes {
            throw AppError.insufficientSpace(required: estimatedBytes, available: snapshot.freeBytes)
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-import")
        defer { workspace.remove() }
        _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
        var existing = Set(snapshot.files.map { ($0.name as NSString).deletingPathExtension.uppercased() })
        var reportLines: [String] = []
        progress = OperationProgress(kind: .importing, current: 0, total: urls.count, detail: "Preparing WAV files")

        for (offset, source) in urls.enumerated() {
            try Task.checkCancellation()
            var base = requestedBases[source.standardizedFileURL.path]
                ?? AkaiFilename.sanitizedBase(
                    source.lastPathComponent,
                    family: options.family
                )
            if existing.contains(base.uppercased()) {
                switch options.collisionPolicy {
                case .skip:
                    reportLines.append("Skipped \(source.lastPathComponent): \(base) already exists.")
                    updateProgress(offset + 1, detail: source.lastPathComponent)
                    continue
                case .rename:
                    base = AkaiFilename.uniqueName(
                        base: base,
                        existing: existing,
                        maximumLength: 10
                    )
                case .replace:
                    if let existingFile = snapshot.files.first(where: {
                        ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(base) == .orderedSame
                    }) {
                        _ = try await run(try AkaiCommandBuilder.delete(index: existingFile.index))
                    }
                }
            }
            updateProgress(offset, detail: "Preparing \(source.lastPathComponent)")
            let prepared = try prepareWAVForS950Import(
                source,
                in: workspace.url,
                options: options,
                finalBase: base
            )
            _ = try await run(try AkaiCommandBuilder.importWAV(filename: prepared.url.lastPathComponent, options: options))
            existing.insert(base.uppercased())
            let markerText = prepared.markerRange.map {
                " Loop markers \($0.lowerBound)–\($0.upperBound) were written to the S9; playback remains one-shot."
            } ?? ""
            if prepared.inspection.needsRepair {
                reportLines.append(
                    "\(source.lastPathComponent) → \(base): "
                        + "\(prepared.inspection.repairReasons.joined(separator: ", "))."
                        + markerText
                )
            } else {
                reportLines.append(
                    "\(source.lastPathComponent) → \(base): imported without audio repair."
                        + markerText
                )
            }
            updateProgress(offset + 1, detail: source.lastPathComponent)
        }
        try await refresh()
        publishSuccess(title: "Import Complete", lines: reportLines)
        progress = nil
    }

    private func prepareWAVForS950Import(
        _ sourceURL: URL,
        in workspace: URL,
        options: ImportOptions,
        finalBase: String
    ) throws -> (
        url: URL,
        inspection: WAVInspection,
        markerRange: ClosedRange<UInt32>?
    ) {
        let prepared = try WAVService.prepare(
            sourceURL,
            in: workspace,
            options: options,
            finalBase: finalBase
        )
        let orderedMarkers = prepared.inspection.cueSampleOffsets.sorted()
        guard orderedMarkers.count == 2, orderedMarkers[0] < orderedMarkers[1]
        else {
            return (prepared.url, prepared.inspection, nil)
        }

        let convertedInspection = try WAVService.inspect(
            prepared.url,
            options: options
        )
        let preparedData = try Data(contentsOf: prepared.url)
        let existingHeader = try WAVService.nativeS9Header(in: preparedData)
        let header = try S9NativeSample.nativeHeaderForWAVImport(
            existingHeader: existingHeader,
            preparedFrameCount: convertedInspection.frameCount,
            preparedSampleRate: convertedInspection.sampleRate,
            cueSampleOffsets: orderedMarkers,
            sourceFrameCount: prepared.inspection.frameCount
        )
        try WAVService.replaceNativeS9Header(in: prepared.url, with: header)
        let attributes = try S9NativeSample.attributes(in: header)
        guard let loopStart = attributes.loopStart else {
            throw AppError.verificationFailed(
                "The WAV loop markers could not be represented in the native S9 header."
            )
        }
        return (
            prepared.url,
            prepared.inspection,
            loopStart...attributes.playbackEnd
        )
    }

    func exportSelected() {
        exportSelected(withIDs: selection)
    }

    func exportSelectedP9ToAbleton() {
        exportP9ToAbleton(withIDs: selection)
    }

    func exportP9ToAbleton(withIDs ids: Set<AkaiFile.ID>) {
        let programs = snapshot.files.filter {
            ids.contains($0.id)
                && $0.name.pathExtensionUppercased == "P9"
        }
        guard programs.count == 1, canExportP9ToAbleton(withIDs: ids) else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Ableton Drum Rack"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.lastExportDestination()
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        settings.storeExportDestination(destination)

        let program = programs[0]
        start {
            let result = try await self.performAbletonDrumRackExport(
                program,
                to: destination
            )
            var lines = [
                "\(program.name) → \(result.adgURL.lastPathComponent)",
                "Exported \(result.sampleURLs.count) WAV sample\(result.sampleURLs.count == 1 ? "" : "s") to \(result.packageURL.lastPathComponent)."
            ]
            lines.append(contentsOf: result.warnings)
            self.publishSuccess(
                title: "Ableton Drum Rack Exported",
                lines: lines
            )
            self.progress = nil
            if self.settings.openExportDestination {
                NSWorkspace.shared.open(result.packageURL)
            }
        }
    }

    func exportSelected(withIDs ids: Set<AkaiFile.ID>) {
        let files = snapshot.files.filter { ids.contains($0.id) }
        let samples = files.filter(\.isSample)
        if !samples.isEmpty {
            export(files: samples)
            return
        }
        let programs = files.filter {
            $0.name.pathExtensionUppercased == "P9"
        }
        guard !programs.isEmpty else { return }
        copyNativeFiles(programs)
    }

    func exportAllSamples() {
        export(files: snapshot.files.filter(\.isSample))
    }

    func export(files: [AkaiFile]) {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.lastExportDestination()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        settings.storeExportDestination(destination)

        let alert = NSAlert()
        alert.messageText = "If exported WAV files already exist"
        alert.addButton(withTitle: "Create Unique Names")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        let response = alert.runModal()
        let policy: CollisionPolicy = response == .alertFirstButtonReturn ? .rename
            : response == .alertSecondButtonReturn ? .replace : .skip
        start { try await self.exportWAVs(files, to: destination, policy: policy) }
    }

    func exportWAVs(_ files: [AkaiFile], to destination: URL, policy: CollisionPolicy) async throws {
        guard session != nil else { throw AppError.noImageOpen }
        progress = OperationProgress(kind: .exporting, current: 0, total: files.count, detail: destination.lastPathComponent)
        var lines: [String] = []
        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            let workspace = try TemporaryWorkspace(prefix: "akai-export")
            defer { workspace.remove() }
            _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
            _ = try await run(try AkaiCommandBuilder.exportWAV(index: file.index))
            let exports = try FileManager.default.contentsOfDirectory(
                at: workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame }
            guard let exported = exports.first else {
                lines.append("\(file.name): AKAI Util did not create a WAV file.")
                updateProgress(offset + 1, detail: file.name)
                continue
            }
            var finalURL = destination.appendingPathComponent(exported.lastPathComponent)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                switch policy {
                case .skip:
                    lines.append("Skipped \(file.name): \(finalURL.lastPathComponent) exists.")
                    updateProgress(offset + 1, detail: file.name)
                    continue
                case .replace:
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: exported)
                case .rename:
                    finalURL = uniqueURL(for: finalURL)
                    try FileManager.default.moveItem(at: exported, to: finalURL)
                }
            } else {
                try FileManager.default.moveItem(at: exported, to: finalURL)
            }
            lines.append("\(file.name) → \(finalURL.lastPathComponent)")
            updateProgress(offset + 1, detail: file.name)
        }
        publishSuccess(title: "Export Complete", lines: lines)
        progress = nil
        if settings.openExportDestination {
            NSWorkspace.shared.open(destination)
        }
    }

    func performAbletonDrumRackExport(
        _ file: AkaiFile,
        to destinationDirectory: URL,
        templateURL suppliedTemplateURL: URL? = nil
    ) async throws -> AbletonDrumRackExportResult {
        guard session != nil else { throw AppError.noImageOpen }
        guard isS900Volume,
              file.name.pathExtensionUppercased == "P9",
              snapshot.files.contains(where: { $0.id == file.id })
        else {
            throw AppError.verificationFailed(
                "Ableton Drum Rack export requires a P9 program in an open S950 volume."
            )
        }
        let templateURL = suppliedTemplateURL
            ?? AbletonDrumRackExporter.bundledTemplateURL
        guard let templateURL,
              FileManager.default.fileExists(atPath: templateURL.path)
        else {
            throw AbletonDrumRackExportError.missingTemplate
        }

        progress = OperationProgress(
            kind: .exporting,
            current: 0,
            total: 2,
            detail: "Reading \(file.name)"
        )
        let program = try P9Program(data: try await exportNativeFileData(file))
        var warnings: [String] = []
        var resolvedKeygroups: [(index: Int, keygroup: P9Keygroup, sample: AkaiFile)] = []
        var seenNotes = Set<Int>()

        for (index, keygroup) in program.keygroups.enumerated() {
            let softName = keygroup.softSampleName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !softName.isEmpty else { continue }
            guard seenNotes.insert(keygroup.lowKey).inserted else {
                throw AbletonDrumRackExportError.invalidPad(
                    "more than one keygroup starts on \(P9Keygroup.noteName(keygroup.lowKey))."
                )
            }
            let rootNote = keygroup.lowKey + keygroup.softTuning.transpose
            guard (0...127).contains(rootNote) else {
                throw AbletonDrumRackExportError.invalidPad(
                    "keygroup \(index + 1) requires root note \(rootNote), outside 0–127."
                )
            }
            guard let sample = sampleFile(matchingP9Name: softName) else {
                throw AppError.verificationFailed(
                    "Keygroup \(index + 1) references \(softName), but that S9 sample is not present in the volume."
                )
            }
            resolvedKeygroups.append((index, keygroup, sample))
        }
        guard !resolvedKeygroups.isEmpty else {
            throw AbletonDrumRackExportError.invalidPad(
                "the program has no Soft samples to place on pads."
            )
        }

        let rangeCount = resolvedKeygroups.filter {
            $0.keygroup.lowKey != $0.keygroup.highKey
        }.count
        if rangeCount > 0 {
            warnings.append(
                "\(rangeCount) keygroup range\(rangeCount == 1 ? " was" : "s were") placed on its lowest note; Drum Rack pads cannot span key ranges."
            )
        }
        let loudCount = program.keygroups.filter {
            !$0.loudSampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if loudCount > 0 {
            warnings.append(
                "\(loudCount) Loud sample layer\(loudCount == 1 ? " was" : "s were") omitted; this export currently uses each keygroup's Soft sample."
            )
        }
        let skippedCount = program.keygroups.count - resolvedKeygroups.count
        if skippedCount > 0 {
            warnings.append(
                "Skipped \(skippedCount) keygroup\(skippedCount == 1 ? "" : "s") with no Soft sample."
            )
        }

        var uniqueSamples: [AkaiFile] = []
        var seenSampleIDs = Set<AkaiFile.ID>()
        for item in resolvedKeygroups where seenSampleIDs.insert(item.sample.id).inserted {
            uniqueSamples.append(item.sample)
        }
        progress = OperationProgress(
            kind: .exporting,
            current: 1,
            total: uniqueSamples.count + 2,
            detail: "Preparing Ableton export"
        )

        let rackName = Self.safeExportComponent(
            program.name,
            fallback: Self.sampleBaseName(file.name)
        )
        let packageURL = uniqueDirectoryURL(
            for: destinationDirectory.appendingPathComponent(
                "\(rackName) Ableton Rack",
                isDirectory: true
            )
        )
        let samplesURL = packageURL.appendingPathComponent(
            "Samples",
            isDirectory: true
        )
        var packageCreated = false
        do {
            try FileManager.default.createDirectory(
                at: samplesURL,
                withIntermediateDirectories: true
            )
            packageCreated = true

            var wavBySampleID: [AkaiFile.ID: URL] = [:]
            for (offset, sample) in uniqueSamples.enumerated() {
                try Task.checkCancellation()
                updateProgress(
                    offset + 2,
                    detail: "Exporting \(sample.name)"
                )
                let workspace = try TemporaryWorkspace(
                    prefix: "akai-ableton-sample"
                )
                defer { workspace.remove() }
                _ = try await run(
                    try AkaiCommandBuilder.localDirectory(workspace.url.path)
                )
                _ = try await run(
                    try AkaiCommandBuilder.exportWAV(index: sample.index)
                )
                let exports = try FileManager.default.contentsOfDirectory(
                    at: workspace.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter {
                    $0.pathExtension.caseInsensitiveCompare("wav")
                        == .orderedSame
                }
                guard let exported = exports.first else {
                    throw AppError.verificationFailed(
                        "AKAI Util did not export \(sample.name) as a WAV file."
                    )
                }
                let sampleName = Self.safeExportComponent(
                    Self.sampleBaseName(sample.name),
                    fallback: "SAMPLE"
                )
                let finalURL = samplesURL
                    .appendingPathComponent(sampleName)
                    .appendingPathExtension("wav")
                guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                    throw AppError.verificationFailed(
                        "Two S9 samples would create the same Ableton WAV name: \(finalURL.lastPathComponent)."
                    )
                }
                try FileManager.default.moveItem(at: exported, to: finalURL)
                wavBySampleID[sample.id] = finalURL
            }

            var pads: [AbletonSamplerExportPad] = []
            for item in resolvedKeygroups {
                guard let wavURL = wavBySampleID[item.sample.id] else {
                    throw AppError.verificationFailed(
                        "The WAV export for \(item.sample.name) is missing."
                    )
                }
                let audio = try AVAudioFile(forReading: wavURL)
                let keygroup = item.keygroup
                pads.append(
                    AbletonSamplerExportPad(
                        keygroupIndex: item.index,
                        receivingNote: keygroup.lowKey,
                        sampleName: Self.sampleBaseName(item.sample.name),
                        wavURL: wavURL,
                        sampleFrames: audio.length,
                        sampleRate: audio.fileFormat.sampleRate,
                        rootNote: keygroup.lowKey
                            + keygroup.softTuning.transpose,
                        detuneCents: Int(
                            (Double(keygroup.softTuning.fine) * 100.0 / 16.0)
                                .rounded()
                        ),
                        s950Filter: keygroup.softFilter,
                        s950VelocityLoudness:
                            keygroup.velocitySensitivity.loudness,
                        s950VelocityFilter:
                            keygroup.velocitySensitivity.filter
                    )
                )
            }

            updateProgress(
                uniqueSamples.count + 2,
                detail: "Writing Ableton Drum Rack"
            )
            let adgData = try AbletonDrumRackExporter.generate(
                templateURL: templateURL,
                rackName: rackName,
                pads: pads
            )
            let adgURL = packageURL
                .appendingPathComponent(rackName)
                .appendingPathExtension("adg")
            try adgData.write(to: adgURL, options: .atomic)

            let parsed = try AbletonDrumRackParser.parseXML(
                AbletonDrumRackExporter.decompressedADG(adgData),
                sourceURL: adgURL
            )
            guard parsed.samples.count == pads.count else {
                throw AppError.verificationFailed(
                    "The generated ADG contains \(parsed.samples.count) readable pads instead of \(pads.count)."
                )
            }
            for (pad, verified) in zip(pads, parsed.samples) {
                let expectedFilter = min(99, max(0, pad.s950Filter))
                let expectedLoudness = min(
                    99,
                    max(0, pad.s950VelocityLoudness)
                )
                let expectedVelocityFilter = min(
                    99,
                    max(0, pad.s950VelocityFilter)
                )
                guard verified.sourceNote == pad.receivingNote,
                      verified.sourceName == pad.sampleName,
                      verified.detectedRootNote == pad.rootNote,
                      verified.detuneCents == pad.detuneCents,
                      verified.s950Filter == expectedFilter,
                      verified.s950VelocityLoudness == expectedLoudness,
                      verified.s950VelocityFilter == expectedVelocityFilter
                else {
                    throw AppError.verificationFailed(
                        "Generated ADG verification failed on \(P9Keygroup.noteName(pad.receivingNote))."
                    )
                }
            }

            if !warnings.isEmpty {
                let notes = ([
                    "AKAI Image Manager Ableton export notes",
                    "",
                    "Program: \(program.name)",
                    "Pads: \(pads.count)",
                    ""
                ] + warnings.map { "- \($0)" }).joined(separator: "\n") + "\n"
                try notes.write(
                    to: packageURL.appendingPathComponent("Export Notes.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            return AbletonDrumRackExportResult(
                packageURL: packageURL,
                adgURL: adgURL,
                sampleURLs: uniqueSamples.compactMap {
                    wavBySampleID[$0.id]
                },
                warnings: warnings
            )
        } catch {
            if packageCreated {
                try? FileManager.default.removeItem(at: packageURL)
            }
            throw error
        }
    }

    func editSelectedSampleInAudioEditor() {
        editSelectedSampleInAudioEditor(launchEditor: false)
    }

    func editSelectedSampleInAudioEditor(launchEditor: Bool) {
        guard canEditSelectedS9Sample, let file = selectedFiles.first else { return }
        start {
            try await self.prepareExternalSampleEdit(
                file: file,
                editorURL: self.settings.audioEditorURL,
                launchEditor: launchEditor
            )
        }
    }

    func prepareExternalSampleEdit(
        file: AkaiFile,
        editorURL: URL?,
        launchEditor: Bool = false
    ) async throws {
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        guard isS900Volume, file.isSample else {
            throw AppError.verificationFailed(
                "External editing is available only for S950 samples."
            )
        }
        guard snapshot.files.contains(where: { $0.id == file.id }) else {
            throw AppError.verificationFailed(
                "The selected sample is no longer present in this volume."
            )
        }
        guard !launchEditor
            || editorURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true
        else {
            throw AppError.verificationFailed(
                "The selected audio editor cannot be found. Choose it again in Settings."
            )
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-s9-audio-edit")
        var retained = false
        defer {
            if !retained {
                workspace.remove()
            }
        }

        progress = OperationProgress(
            kind: .editingSample,
            current: 0,
            total: 2,
            detail: "Exporting \(file.name) as WAV"
        )
        _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
        _ = try await run(try AkaiCommandBuilder.exportWAV(index: file.index))
        let exports = try FileManager.default.contentsOfDirectory(
            at: workspace.url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame }
        guard let wavURL = exports.first else {
            throw AppError.verificationFailed(
                "AKAI Util did not export \(file.name) as a WAV file."
            )
        }
        let inspectionOptions = ImportOptions(
            family: .s900,
            compressedS900: settings.compressedS900,
            convertToMono: true,
            preserveSampleRate: true,
            collisionPolicy: .replace
        )
        var inspection = try WAVService.inspect(wavURL, options: inspectionOptions)
        var originalWAVData = try Data(contentsOf: wavURL)
        guard let nativeHeader = try WAVService.nativeS9Header(
            in: originalWAVData
        ) else {
            throw AppError.verificationFailed(
                "AKAI Util did not include the native S9 attributes in its exported WAV."
            )
        }
        let originalAttributes = try S9NativeSample.attributes(in: nativeHeader)
        if let loopStart = originalAttributes.loopStart,
           loopStart < originalAttributes.playbackEnd,
           originalAttributes.playbackMode.requiresLoopMarkers
                || loopStart > 0
                || originalAttributes.playbackEnd
                    < originalAttributes.sampleLength {
            let wavPoints = try Self.wavLoopMarkerOffsets(
                S9LoopPoints(
                    start: loopStart,
                    end: originalAttributes.playbackEnd
                ),
                nativeSampleLength: originalAttributes.sampleLength,
                wavFrameCount: inspection.frameCount
            )
            try WAVService.replaceCueSampleOffsets(
                [wavPoints.start, wavPoints.end],
                in: wavURL
            )
            inspection = try WAVService.inspect(
                wavURL,
                options: inspectionOptions
            )
            originalWAVData = try Data(contentsOf: wavURL)
        }
        let editSession = ExternalSampleEditSession(
            sourceFile: file,
            imageURL: activeSession.imageURL,
            volumePath: snapshot.currentPath,
            wavURL: wavURL,
            editorURL: editorURL,
            originalWAVData: originalWAVData,
            originalInspection: inspection,
            originalAttributes: originalAttributes,
            workspace: workspace
        )
        updateProgress(1, detail: "Preparing sample editor")
        if launchEditor {
            try await openEditedWAV(editSession)
        }
        externalSampleEditSession = editSession
        retained = true
        updateProgress(2, detail: "Ready for editing")
        publishSuccess(
            title: "Sample Opened for Editing",
            lines: [
                "\(file.name) was exported as \(wavURL.lastPathComponent).",
                editorURL.map {
                    "Use Open WAV in \($0.deletingPathExtension().lastPathComponent) if audio editing is required."
                } ?? "Native S9 attributes can be edited without configuring an external audio editor."
            ]
        )
        progress = nil
    }

    @discardableResult
    func reopenExternalAudioEditor(
        _ editSession: ExternalSampleEditSession,
        loopPoints: S9LoopPoints? = nil
    ) -> Bool {
        do {
            if let loopPoints {
                let wavPoints = try Self.wavLoopMarkerOffsets(
                    loopPoints,
                    nativeSampleLength:
                        editSession.originalAttributes.sampleLength,
                    wavFrameCount:
                        editSession.originalInspection.frameCount
                )
                try WAVService.replaceCueSampleOffsets(
                    [wavPoints.start, wavPoints.end],
                    in: editSession.wavURL
                )
            }
        } catch {
            editSession.errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
        Task {
            do {
                try await self.openEditedWAV(editSession)
            } catch {
                editSession.errorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        return true
    }

    func cancelExternalSampleEdit(_ editSession: ExternalSampleEditSession) {
        guard !editSession.isReplacing else { return }
        if externalSampleEditSession?.id == editSession.id {
            externalSampleEditSession = nil
        }
        editSession.removeWorkspace()
        publishSuccess(
            title: "Sample Edit Cancelled",
            lines: ["The temporary WAV was removed; the IMG was not changed."],
            systemImage: "xmark.circle"
        )
    }

    func replaceEditedS9Sample(
        _ editSession: ExternalSampleEditSession,
        compressed: Bool,
        createBackup: Bool,
        attributes: S9SampleEditSettings,
        loopPoints: S9LoopPoints? = nil
    ) {
        start {
            editSession.isReplacing = true
            editSession.errorMessage = nil
            defer {
                editSession.isReplacing = false
                self.progress = nil
            }
            do {
                _ = try await self.performEditedS9Replacement(
                    editSession,
                    compressed: compressed,
                    createBackup: createBackup,
                    attributes: attributes,
                    loopPoints: loopPoints
                )
                if self.externalSampleEditSession?.id == editSession.id {
                    self.externalSampleEditSession = nil
                }
                editSession.removeWorkspace()
            } catch {
                editSession.errorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if self.settings.autoOpenLogOnError {
                    self.isLogVisible = true
                }
            }
        }
    }

    func performEditedS9Replacement(
        _ editSession: ExternalSampleEditSession,
        compressed: Bool,
        createBackup: Bool = true,
        attributes: S9SampleEditSettings? = nil,
        loopPoints: S9LoopPoints? = nil
    ) async throws -> S9ReplacementResult {
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        guard activeSession.imageURL.standardizedFileURL
                == editSession.imageURL.standardizedFileURL,
              snapshot.currentPath == editSession.volumePath
        else {
            throw AppError.verificationFailed(
                "The exact source IMG and volume are no longer open. "
                    + "Reopen the original sample before replacing it."
            )
        }
        guard isS900Volume else {
            throw AppError.verificationFailed(
                "The open volume is not an S950 volume."
            )
        }
        let editedWAVData = try Data(contentsOf: editSession.wavURL)
        let audioOrMetadataChanged = editedWAVData != editSession.originalWAVData
        let attributesChanged = attributes.map {
            $0.rootNote != editSession.originalAttributes.rootNote
                || $0.playbackMode != editSession.originalAttributes.playbackMode
                || $0.playbackDirection
                    != editSession.originalAttributes.playbackDirection
        } ?? false
        let loopPointsChanged = loopPoints.map {
            $0.start != editSession.originalAttributes.loopStart
                || $0.end != editSession.originalAttributes.playbackEnd
        } ?? false
        guard audioOrMetadataChanged || attributesChanged || loopPointsChanged else {
            throw AppError.verificationFailed(
                "The WAV and S9 attributes have not changed. Save an audio edit or change an attribute first."
            )
        }
        let sampleBase = editSession.sampleBaseName
        guard let originalFile = sampleFile(matchingP9Name: sampleBase) else {
            throw AppError.verificationFailed(
                "\(editSession.sourceFile.name) is no longer present in the source volume."
            )
        }

        progress = OperationProgress(
            kind: .editingSample,
            current: 0,
            total: 8,
            detail: "Inspecting edited WAV"
        )
        let prepared = try await prepareNativeS9Replacement(
            from: editSession.wavURL,
            sampleBase: sampleBase,
            compressed: compressed
        )
        updateProgress(2, detail: "Prepared native \(sampleBase).S9")
        let stagedBase = AkaiFilename.sanitizedBase(
            sampleBase,
            family: .s900,
            maximumLength: 10
        )
        let stagedFilename = "\(stagedBase).S9"
        let stagedURL = editSession.workspace.url.appendingPathComponent(stagedFilename)
        var preparedData = prepared.data
        if let attributes {
            let cueSampleOffsets = try WAVService.cueSampleOffsets(
                in: editSession.wavURL
            )
            preparedData = try S9NativeSample.applying(
                attributes,
                cueSampleOffsets: cueSampleOffsets,
                editedWAVFrameCount: prepared.inspection.frameCount,
                to: preparedData,
                retainedFinePitchSixteenths:
                    editSession.originalAttributes.finePitchSixteenths,
                explicitLoopPoints: loopPoints
            )
        }
        preparedData = try S9NativeSample.renamingInternalName(
            in: preparedData,
            to: sampleBase
        )
        try preparedData.write(to: stagedURL, options: .atomic)
        guard Self.normalizedSampleKey(
            try S9NativeSample.internalName(in: preparedData)
        ) == Self.normalizedSampleKey(sampleBase) else {
            throw AppError.verificationFailed(
                "The prepared S9 internal sample name does not match \(sampleBase)."
            )
        }
        let availableAfterRemovingOriginal =
            snapshot.freeBytes + max(0, originalFile.byteSize)
        if snapshot.freeBytes > 0,
           Int64(preparedData.count) > availableAfterRemovingOriginal {
            throw AppError.insufficientSpace(
                required: Int64(preparedData.count),
                available: availableAfterRemovingOriginal
            )
        }

        updateProgress(3, detail: "Closing the IMG safely")
        await controller.close()
        let backupURL: URL?
        do {
            if createBackup {
                updateProgress(4, detail: "Creating and verifying a complete IMG backup")
                backupURL = try createTimestampedBackup(
                    of: activeSession.imageURL
                )
            } else {
                updateProgress(4, detail: "Continuing without an IMG backup")
                backupURL = nil
            }
            try await reopenImageSession(activeSession)
        } catch {
            try? await reopenImageSession(activeSession)
            throw error
        }

        var mutationStarted = false
        do {
            guard let currentFile = sampleFile(matchingP9Name: sampleBase) else {
                throw AppError.verificationFailed(
                    "\(originalFile.name) disappeared before replacement began."
                )
            }
            updateProgress(5, detail: "Replacing \(currentFile.name)")
            _ = try await run(
                try AkaiCommandBuilder.localDirectory(editSession.workspace.url.path)
            )
            mutationStarted = true
            _ = try await run(try AkaiCommandBuilder.delete(index: currentFile.index))
            _ = try await run(
                try AkaiCommandBuilder.importNative(filename: stagedFilename)
            )
            try await refresh()
            guard let storedFile = sampleFile(matchingP9Name: sampleBase) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not restore \(currentFile.name) after replacement."
                )
            }

            try FileManager.default.removeItem(at: stagedURL)
            let filesBeforeVerification = Set(
                try FileManager.default.contentsOfDirectory(
                    at: editSession.workspace.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).map(\.standardizedFileURL)
            )
            updateProgress(6, detail: "Exporting replacement for native verification")
            _ = try await run(try AkaiCommandBuilder.exportNative(index: storedFile.index))
            let filesAfterVerification = try FileManager.default.contentsOfDirectory(
                at: editSession.workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard let exported = filesAfterVerification.first(where: {
                !filesBeforeVerification.contains($0.standardizedFileURL)
                    && $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame
            }) else {
                throw AppError.verificationFailed(
                    "AKAI Util did not export the replacement S9 for verification."
                )
            }
            let normalizedExport = try NativeAkaiFileExport.normalizeExportedFile(
                exported,
                expectedFilename: stagedFilename
            )
            let exportedData = try Data(contentsOf: normalizedExport)
            var verifiedData = exportedData
#if AKAI_TESTING
            verifiedData = s9ReplacementVerificationMutator?(exportedData)
                ?? exportedData
#endif
            updateProgress(7, detail: "Comparing native S9 bytes")
            guard verifiedData == preparedData else {
                throw AppError.verificationFailed(
                    "The S9 exported from the IMG differs from the prepared replacement. "
                        + Self.nativeDataDifferenceSummary(
                            expected: preparedData,
                            actual: verifiedData
                        )
                )
            }
            updateProgress(8, detail: "Sample replacement verified")
            let result = S9ReplacementResult(
                filename: storedFile.name,
                backupURL: backupURL,
                verifiedByteCount: verifiedData.count,
                wavInspection: prepared.inspection
            )
            var successLines = [
                "\(storedFile.name) was replaced without changing its program reference."
            ]
            if let backupURL {
                successLines.append("Backup: \(backupURL.path)")
            } else {
                successLines.append("No IMG backup was created.")
            }
            if let attributes {
                successLines.append(
                    "Root \(P9Keygroup.noteName(attributes.rootNote)); "
                        + "\(attributes.playbackDirection.title.lowercased()); "
                        + "\(attributes.playbackMode.title.lowercased())."
                )
            }
            publishSuccess(
                title: "S9 Sample Replaced and Verified",
                lines: successLines
            )
            return result
        } catch {
            guard mutationStarted else { throw error }
            let originalMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            guard let backupURL else {
                try? await refresh()
                throw AppError.verificationFailed(
                    "S9 replacement did not complete and no IMG backup was created, so automatic rollback is unavailable. Do not use the IMG until it has been checked or restored manually. Cause: \(originalMessage)"
                )
            }
            do {
                try await restoreImageSession(activeSession, from: backupURL)
            } catch {
                let rollbackMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                session = nil
                snapshot = DiskSnapshot()
                selection.removeAll()
                throw AppError.verificationFailed(
                    "S9 replacement failed and automatic IMG restoration also failed. "
                        + "Do not use the destination IMG. Restore it manually from "
                        + "\(backupURL.path). Replacement error: \(originalMessage) "
                        + "Restoration error: \(rollbackMessage)"
                )
            }
            throw AppError.verificationFailed(
                "S9 replacement did not complete. The original IMG was restored and verified "
                    + "from \(backupURL.lastPathComponent). Cause: \(originalMessage)"
            )
        }
    }

    private static func wavLoopMarkerOffsets(
        _ loopPoints: S9LoopPoints,
        nativeSampleLength: UInt32,
        wavFrameCount: Int64
    ) throws -> S9LoopPoints {
        let points = try loopPoints.validated(
            sampleLength: nativeSampleLength
        )
        guard wavFrameCount > 0, wavFrameCount <= Int64(UInt32.max) else {
            throw AppError.verificationFailed(
                "The temporary WAV has an unsupported sample length."
            )
        }
        let wavLength = UInt32(wavFrameCount)
        func scaled(_ nativePosition: UInt32) -> UInt32 {
            let position = Double(nativePosition)
                * Double(wavLength)
                / Double(nativeSampleLength)
            return UInt32(
                max(0, min(Int64(wavLength), Int64(position.rounded())))
            )
        }
        return try S9LoopPoints(
            start: scaled(points.start),
            end: scaled(points.end)
        ).validated(sampleLength: wavLength)
    }

    private func openEditedWAV(
        _ editSession: ExternalSampleEditSession
    ) async throws {
        guard let editorURL = editSession.editorURL,
              FileManager.default.fileExists(atPath: editorURL.path)
        else {
            throw AppError.verificationFailed(
                "Choose an audio editor in AKAI Image Manager Settings first."
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open(
            [editSession.wavURL],
            withApplicationAt: editorURL,
            configuration: configuration
        )
    }

    private func prepareNativeS9Replacement(
        from wavURL: URL,
        sampleBase: String,
        compressed: Bool
    ) async throws -> (data: Data, inspection: WAVInspection) {
        let workspace = try TemporaryWorkspace(prefix: "akai-s9-conversion")
        defer { workspace.remove() }
        let inputDirectory = workspace.url.appendingPathComponent("input", isDirectory: true)
        let nativeDirectory = workspace.url.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inputDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        let options = ImportOptions(
            family: .s900,
            compressedS900: compressed,
            convertToMono: true,
            preserveSampleRate: true,
            collisionPolicy: .replace
        )
        let localBase = AkaiFilename.sanitizedBase(
            sampleBase,
            family: .s900,
            maximumLength: 10
        )
        let preparedWAV = try WAVService.prepare(
            wavURL,
            in: inputDirectory,
            options: options,
            finalBase: localBase
        )
        let conversionImage = workspace.url.appendingPathComponent("conversion.img")
        try ImageFileOperations.createZeroFilledImage(
            at: conversionImage,
            byteCount: FormatPreset.s900Hard32.byteCount
        )
        let conversionController = AkaiCommandController()
        do {
            let opened = try await conversionController.open(
                imageURL: conversionImage,
                executableURL: settings.executableURL,
                readOnly: false
            )
            appendLog(opened)
            let formatted = try await conversionController.send(
                FormatPreset.s900Hard32.command
            )
            appendLog(formatted)
            let volumeCreated = try await conversionController.send(
                "mkvol9 /disk0/A/CONVERT"
            )
            appendLog(volumeCreated)
            let volumeSelected = try await conversionController.send(
                try AkaiCommandBuilder.changeDirectory("/disk0/A/CONVERT")
            )
            appendLog(volumeSelected)
            updateProgress(1, detail: "Converting edited WAV to native S9")
            let local = try await conversionController.send(
                try AkaiCommandBuilder.localDirectory(inputDirectory.path)
            )
            appendLog(local)
            let imported = try await conversionController.send(
                try AkaiCommandBuilder.importWAV(
                    filename: preparedWAV.url.lastPathComponent,
                    options: options
                )
            )
            appendLog(imported)
            let listing = try await conversionController.send("dir")
            appendLog(listing)
            let files = AkaiOutputParser.parseDirectory(listing.output).0
            guard let convertedFile = files.first(where: {
                $0.isSample
                    && Self.normalizedSampleKey(Self.sampleBaseName($0.name))
                        == Self.normalizedSampleKey(sampleBase)
            }) else {
                throw AppError.verificationFailed(
                    "The disposable conversion image did not contain \(sampleBase)."
                )
            }
            let nativeLocal = try await conversionController.send(
                try AkaiCommandBuilder.localDirectory(nativeDirectory.path)
            )
            appendLog(nativeLocal)
            let exported = try await conversionController.send(
                try AkaiCommandBuilder.exportNative(index: convertedFile.index)
            )
            appendLog(exported)
            await conversionController.close()
        } catch {
            await conversionController.close()
            throw error
        }

        let nativeExports = try FileManager.default.contentsOfDirectory(
            at: nativeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame }
        guard let nativeURL = nativeExports.first else {
            throw AppError.verificationFailed(
                "AKAI Util did not export the converted native S9 file."
            )
        }
        let data = try S9NativeSample.renamingInternalName(
            in: Data(contentsOf: nativeURL),
            to: sampleBase
        )
        return (data, preparedWAV.inspection)
    }

    func copySelectedNativeFiles() {
        copyNativeFiles(selectedNativeFiles)
    }

    func copyNativeFiles(withIDs ids: Set<AkaiFile.ID>) {
        copyNativeFiles(snapshot.files.filter {
            ids.contains($0.id) && NativeAkaiFileExport.isSupported($0.name)
        })
    }

    func containsNativeFile(withIDs ids: Set<AkaiFile.ID>) -> Bool {
        snapshot.files.contains {
            ids.contains($0.id) && NativeAkaiFileExport.isSupported($0.name)
        }
    }

    func containsSingleRenameableNativeFile(
        withIDs ids: Set<AkaiFile.ID>
    ) -> Bool {
        guard ids.count == 1,
              let file = snapshot.files.first(where: { ids.contains($0.id) })
        else {
            return false
        }
        return NativeAkaiFileExport.isSupported(file.name) && canMutate
    }

    func containsSingleFile(withIDs ids: Set<AkaiFile.ID>) -> Bool {
        ids.count == 1
            && snapshot.files.contains(where: { ids.contains($0.id) })
            && session != nil
            && !isBusy
    }

    func showSelectedFileInformation() {
        guard canShowSelectedFileInformation,
              let file = selectedFiles.first
        else {
            return
        }
        loadFileInformation(file)
    }

    func showFileInformation(withIDs ids: Set<AkaiFile.ID>) {
        guard containsSingleFile(withIDs: ids),
              let file = snapshot.files.first(where: { ids.contains($0.id) })
        else {
            return
        }
        selection = [file.id]
        loadFileInformation(file)
    }

    private func loadFileInformation(_ file: AkaiFile) {
        start {
            self.progress = OperationProgress(
                kind: .refreshing,
                current: 0,
                total: 1,
                detail: "Reading \(file.name)"
            )
            defer { self.progress = nil }
            let result = try await self.run(
                try AkaiCommandBuilder.fileInformation(index: file.index)
            )
            let details = result.cleanedOutput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !details.isEmpty else {
                throw AppError.verificationFailed(
                    "AKAI Util returned no information for \(file.name)."
                )
            }
            self.fileInformation = AkaiFileInformation(
                filename: file.name,
                details: details
            )
            self.updateProgress(1, detail: file.name)
        }
    }

    func renameSelectedNativeFile() {
        guard canRenameSelectedNativeFile, let file = selectedFiles.first else {
            return
        }
        presentNativeRenamePrompt(for: file)
    }

    func renameNativeFile(withIDs ids: Set<AkaiFile.ID>) {
        guard containsSingleRenameableNativeFile(withIDs: ids),
              let file = snapshot.files.first(where: { ids.contains($0.id) })
        else {
            return
        }
        selection = [file.id]
        presentNativeRenamePrompt(for: file)
    }

    private func presentNativeRenamePrompt(for file: AkaiFile) {
        let isProgram = file.name.pathExtensionUppercased == "P9"
        let currentBase = Self.sampleBaseName(file.name)
            .replacingOccurrences(of: "_", with: " ")

        let alert = NSAlert()
        alert.messageText = isProgram ? "Rename S950 Program" : "Rename S950 Sample"
        alert.informativeText = isProgram
            ? "The P9 directory name and internal program name will be changed together. A verified backup of the complete IMG is created first."
            : "Every P9 in this volume that references this S9 will be updated to the new sample name. A verified backup of the complete IMG is created first."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: currentBase)
        field.placeholderString = "Name (up to 10 characters)"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let requestedName = field.stringValue
        start {
            try await self.performNativeRename(
                file,
                requestedName: requestedName
            )
        }
    }

    func performNativeRename(
        _ sourceFile: AkaiFile,
        requestedName: String
    ) async throws {
        defer { progress = nil }
        guard sourceFile.name.pathExtensionUppercased == "P9"
                || sourceFile.name.pathExtensionUppercased == "S9"
        else {
            throw AppError.verificationFailed(
                "Only native S9 samples and P9 programs can be renamed."
            )
        }
        let names = try Self.nativeRenameNames(from: requestedName)
        if sourceFile.name.pathExtensionUppercased == "P9" {
            try await performP9Rename(
                sourceFile,
                internalName: names.internalName,
                stagedBase: names.stagedBase
            )
        } else {
            try await performS9Rename(
                sourceFile,
                internalName: names.internalName,
                stagedBase: names.stagedBase
            )
        }
    }

    private func performP9Rename(
        _ sourceFile: AkaiFile,
        internalName: String,
        stagedBase: String
    ) async throws {
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        let sourceVolumePath = snapshot.currentPath
        let sourceKey = Self.normalizedP9NameKey(sourceFile.name)
        let destinationKey = Self.normalizedP9NameKey("\(stagedBase).P9")
        guard sourceKey != destinationKey else {
            throw AppError.verificationFailed(
                "The new program name is the same as the current name."
            )
        }
        guard p9File(matchingNameKey: destinationKey) == nil else {
            throw AppError.verificationFailed(
                "\(internalName).P9 already exists in this volume."
            )
        }

        progress = OperationProgress(
            kind: .renaming,
            current: 0,
            total: 7,
            detail: "Reading \(sourceFile.name)"
        )
        let originalData = try await exportNativeFileData(sourceFile)
        var program = try P9Program(data: originalData)
        program.name = internalName
        let renamedData = try program.encoded()

        let workspace = try TemporaryWorkspace(prefix: "akai-p9-rename")
        defer { workspace.remove() }
        let stagedFilename = "\(stagedBase).P9"
        try renamedData.write(
            to: workspace.url.appendingPathComponent(stagedFilename),
            options: .atomic
        )

        updateProgress(1, detail: "Closing the IMG safely")
        await controller.close()
        let backupURL: URL
        do {
            updateProgress(2, detail: "Creating and verifying a complete IMG backup")
            backupURL = try createTimestampedBackup(
                of: activeSession.imageURL
            )
            try await reopenImageSession(activeSession)
        } catch {
            try? await reopenImageSession(activeSession)
            throw error
        }

        var mutationStarted = false
        do {
            guard snapshot.currentPath == sourceVolumePath,
                  let currentFile = p9File(matchingNameKey: sourceKey)
            else {
                throw AppError.verificationFailed(
                    "\(sourceFile.name) is no longer present in the source volume."
                )
            }
            updateProgress(3, detail: "Replacing \(currentFile.name)")
            _ = try await run(
                try AkaiCommandBuilder.localDirectory(workspace.url.path)
            )
            mutationStarted = true
            _ = try await run(
                try AkaiCommandBuilder.delete(index: currentFile.index)
            )
            _ = try await run(
                try AkaiCommandBuilder.importNative(filename: stagedFilename)
            )

            updateProgress(4, detail: "Re-reading the destination volume")
            try await refresh()
            guard p9File(matchingNameKey: sourceKey) == nil,
                  let renamedFile = p9File(matchingNameKey: destinationKey)
            else {
                throw AppError.verificationFailed(
                    "AKAI Util did not replace \(sourceFile.name) with \(stagedFilename)."
                )
            }

            updateProgress(5, detail: "Exporting \(renamedFile.name) for verification")
            let verifiedData = try await exportNativeFileData(renamedFile)
            updateProgress(6, detail: "Comparing every P9 byte")
            guard verifiedData == renamedData else {
                throw AppError.verificationFailed(
                    "The renamed P9 exported from the IMG differs from the prepared program."
                )
            }
            let verifiedProgram = try P9Program(data: verifiedData)
            guard verifiedProgram.name == internalName else {
                throw AppError.verificationFailed(
                    "The P9 internal program name was not changed to \(internalName)."
                )
            }

            updateProgress(7, detail: "Program rename verified")
            selection = [renamedFile.id]
            publishSuccess(
                title: "Program Renamed and Verified",
                lines: [
                    "\(sourceFile.name) → \(renamedFile.name)",
                    "Backup: \(backupURL.path)"
                ]
            )
        } catch {
            try await handleNativeRenameFailure(
                error,
                mutationStarted: mutationStarted,
                activeSession: activeSession,
                backupURL: backupURL,
                itemDescription: "program rename"
            )
        }
    }

    private func performS9Rename(
        _ sourceFile: AkaiFile,
        internalName: String,
        stagedBase: String
    ) async throws {
        guard let activeSession = session else { throw AppError.noImageOpen }
        guard !activeSession.readOnly else { throw AppError.readOnly }
        let sourceVolumePath = snapshot.currentPath
        let sourceBase = Self.sampleBaseName(sourceFile.name)
        let sourceKey = Self.normalizedSampleKey(sourceBase)
        let destinationKey = Self.normalizedSampleKey(internalName)
        guard sourceKey != destinationKey else {
            throw AppError.verificationFailed(
                "The new sample name is the same as the current name."
            )
        }
        guard snapshot.files.filter(\.isSample).allSatisfy({
            $0.id == sourceFile.id
                || Self.normalizedSampleKey(Self.sampleBaseName($0.name))
                    != destinationKey
        }) else {
            throw AppError.verificationFailed(
                "\(internalName).S9 already exists in this volume."
            )
        }

        let p9Files = snapshot.files.filter {
            $0.name.pathExtensionUppercased == "P9"
        }
        progress = OperationProgress(
            kind: .renaming,
            current: 0,
            total: 8 + p9Files.count,
            detail: "Reading \(sourceFile.name)"
        )
        let originalSampleData = try await exportNativeFileData(sourceFile)
        let originalInternalName = try S9NativeSample.internalName(
            in: originalSampleData
        )
        let renamedSampleData = try S9NativeSample.renamingInternalName(
            in: originalSampleData,
            to: internalName
        )
        let oldNames = Set([sourceBase, originalInternalName])

        var affectedPrograms: [
            (file: AkaiFile, stagedFilename: String, data: Data, references: Int)
        ] = []
        for (offset, file) in p9Files.enumerated() {
            updateProgress(
                offset + 1,
                detail: "Checking references in \(file.name)"
            )
            let sourceData = try await exportNativeFileData(file)
            var program = try P9Program(data: sourceData)
            let references = program.renameSampleReferences(
                matching: oldNames,
                to: internalName
            )
            guard references > 0 else { continue }
            affectedPrograms.append(
                (
                    file: file,
                    stagedFilename:
                        "\(AkaiFilename.sanitizedBase(file.name, family: .s900, maximumLength: 10)).P9",
                    data: try program.encoded(),
                    references: references
                )
            )
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-s9-rename")
        defer { workspace.remove() }
        let stagedSampleFilename = "\(stagedBase).S9"
        try renamedSampleData.write(
            to: workspace.url.appendingPathComponent(stagedSampleFilename),
            options: .atomic
        )
        for program in affectedPrograms {
            try program.data.write(
                to: workspace.url.appendingPathComponent(
                    program.stagedFilename
                ),
                options: .atomic
            )
        }

        updateProgress(
            p9Files.count + 1,
            detail: "Closing the IMG safely"
        )
        await controller.close()
        let backupURL: URL
        do {
            updateProgress(
                p9Files.count + 2,
                detail: "Creating and verifying a complete IMG backup"
            )
            backupURL = try createTimestampedBackup(
                of: activeSession.imageURL
            )
            try await reopenImageSession(activeSession)
        } catch {
            try? await reopenImageSession(activeSession)
            throw error
        }

        var mutationStarted = false
        do {
            guard snapshot.currentPath == sourceVolumePath,
                  let currentSample = sampleFile(matchingP9Name: sourceBase)
            else {
                throw AppError.verificationFailed(
                    "\(sourceFile.name) is no longer present in the source volume."
                )
            }
            let currentPrograms = try affectedPrograms.map { staged -> AkaiFile in
                guard let current = p9File(
                    matchingNameKey: Self.normalizedP9NameKey(staged.file.name)
                ) else {
                    throw AppError.verificationFailed(
                        "\(staged.file.name) disappeared before rename began."
                    )
                }
                return current
            }

            updateProgress(
                p9Files.count + 3,
                detail: "Replacing the sample and linked programs"
            )
            _ = try await run(
                try AkaiCommandBuilder.localDirectory(workspace.url.path)
            )
            mutationStarted = true
            let deletionIndexes =
                [currentSample.index] + currentPrograms.map(\.index)
            for index in AkaiCommandBuilder.deletionOrder(deletionIndexes) {
                _ = try await run(
                    try AkaiCommandBuilder.delete(index: index)
                )
            }
            _ = try await run(
                try AkaiCommandBuilder.importNative(
                    filename: stagedSampleFilename
                )
            )
            for program in affectedPrograms {
                _ = try await run(
                    try AkaiCommandBuilder.importNative(
                        filename: program.stagedFilename
                    )
                )
            }

            updateProgress(
                p9Files.count + 4,
                detail: "Re-reading the destination volume"
            )
            try await refresh()
            guard sampleFile(matchingP9Name: sourceBase) == nil,
                  let renamedSample = sampleFile(
                    matchingP9Name: internalName
                  )
            else {
                throw AppError.verificationFailed(
                    "AKAI Util did not replace \(sourceFile.name) with \(stagedSampleFilename)."
                )
            }

            updateProgress(
                p9Files.count + 5,
                detail: "Verifying the renamed S9"
            )
            let verifiedSampleData = try await exportNativeFileData(
                renamedSample
            )
            guard verifiedSampleData == renamedSampleData,
                  try S9NativeSample.internalName(in: verifiedSampleData)
                    == internalName
            else {
                throw AppError.verificationFailed(
                    "The renamed S9 exported from the IMG differs from the prepared sample."
                )
            }

            var verifiedReferences = 0
            for staged in affectedPrograms {
                guard let storedProgram = p9File(
                    matchingNameKey:
                        Self.normalizedP9NameKey(staged.file.name)
                ) else {
                    throw AppError.verificationFailed(
                        "AKAI Util did not restore linked program \(staged.file.name)."
                    )
                }
                let verifiedData = try await exportNativeFileData(
                    storedProgram
                )
                guard verifiedData == staged.data else {
                    throw AppError.verificationFailed(
                        "Linked program \(storedProgram.name) differs from its prepared P9."
                    )
                }
                verifiedReferences += staged.references
            }

            updateProgress(
                p9Files.count + 8,
                detail: "Sample rename verified"
            )
            selection = [renamedSample.id]
            let programCount = affectedPrograms.count
            publishSuccess(
                title: "Sample Renamed and Verified",
                lines: [
                    "\(sourceFile.name) → \(renamedSample.name)",
                    "Updated \(verifiedReferences) reference\(verifiedReferences == 1 ? "" : "s") in \(programCount) P9 program\(programCount == 1 ? "" : "s").",
                    "Backup: \(backupURL.path)"
                ]
            )
        } catch {
            try await handleNativeRenameFailure(
                error,
                mutationStarted: mutationStarted,
                activeSession: activeSession,
                backupURL: backupURL,
                itemDescription: "sample rename"
            )
        }
    }

    private func exportNativeFileData(_ file: AkaiFile) async throws -> Data {
        let workspace = try TemporaryWorkspace(prefix: "akai-native-read")
        defer { workspace.remove() }
        _ = try await run(
            try AkaiCommandBuilder.localDirectory(workspace.url.path)
        )
        _ = try await run(
            try AkaiCommandBuilder.exportNative(index: file.index)
        )
        let exports = try FileManager.default.contentsOfDirectory(
            at: workspace.url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            NativeAkaiFileExport.isSupported($0.lastPathComponent)
        }
        guard let exported = exports.first else {
            throw AppError.verificationFailed(
                "AKAI Util did not export \(file.name)."
            )
        }
        let normalized = try NativeAkaiFileExport.normalizeExportedFile(
            exported,
            expectedFilename: file.name
        )
        return try Data(contentsOf: normalized)
    }

    private func handleNativeRenameFailure(
        _ error: Error,
        mutationStarted: Bool,
        activeSession: ImageSession,
        backupURL: URL,
        itemDescription: String
    ) async throws {
        guard mutationStarted else { throw error }
        let originalMessage =
            (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        do {
            try await restoreImageSession(activeSession, from: backupURL)
        } catch {
            let rollbackMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            session = nil
            snapshot = DiskSnapshot()
            selection.removeAll()
            throw AppError.verificationFailed(
                "\(itemDescription.capitalized) failed and automatic IMG restoration also failed. "
                    + "Do not use the destination IMG. Restore it manually from "
                    + "\(backupURL.path). Rename error: \(originalMessage) "
                    + "Restoration error: \(rollbackMessage)"
            )
        }
        throw AppError.verificationFailed(
            "\(itemDescription.capitalized) did not complete. The original IMG was restored and verified "
                + "from \(backupURL.lastPathComponent). Cause: \(originalMessage)"
        )
    }

    private static func nativeRenameNames(
        from requestedName: String
    ) throws -> (internalName: String, stagedBase: String) {
        let trimmed = requestedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw AppError.verificationFailed("Enter a new name.")
        }
        let stagedBase = AkaiFilename.sanitizedBase(
            trimmed,
            family: .s900,
            maximumLength: 10
        )
        let internalName = stagedBase.replacingOccurrences(
            of: "_",
            with: " "
        )
        return (internalName, stagedBase)
    }

    private func copyNativeFiles(_ files: [AkaiFile]) {
        guard !files.isEmpty, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Original S9/P9 Files"
        panel.prompt = "Copy"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.lastExportDestination()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        settings.storeExportDestination(destination)

        let alert = NSAlert()
        alert.messageText = "If original S9/P9 files already exist"
        alert.addButton(withTitle: "Create Unique Names")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        let response = alert.runModal()
        let policy: CollisionPolicy = response == .alertFirstButtonReturn ? .rename
            : response == .alertSecondButtonReturn ? .replace : .skip
        start { try await self.exportNativeFiles(files, to: destination, policy: policy) }
    }

    func exportNativeFiles(
        _ files: [AkaiFile],
        to destination: URL,
        policy: CollisionPolicy,
        revealInFinder: Bool? = nil
    ) async throws {
        guard session != nil else { throw AppError.noImageOpen }
        let nativeFiles = files.filter { NativeAkaiFileExport.isSupported($0.name) }
        guard !nativeFiles.isEmpty else {
            throw AppError.verificationFailed("Select at least one S9 or P9 file.")
        }

        progress = OperationProgress(
            kind: .exporting,
            current: 0,
            total: nativeFiles.count,
            detail: destination.lastPathComponent
        )
        var lines: [String] = []
        for (offset, file) in nativeFiles.enumerated() {
            try Task.checkCancellation()
            let workspace = try TemporaryWorkspace(prefix: "akai-native-export")
            defer { workspace.remove() }
            _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
            _ = try await run(try AkaiCommandBuilder.exportNative(index: file.index))
            let exports = try FileManager.default.contentsOfDirectory(
                at: workspace.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { NativeAkaiFileExport.isSupported($0.lastPathComponent) }
            guard let exported = exports.first else {
                lines.append("\(file.name): AKAI Util did not create an S9 or P9 file.")
                updateProgress(offset + 1, detail: file.name)
                continue
            }

            let normalizedExport = try NativeAkaiFileExport.normalizeExportedFile(
                exported,
                expectedFilename: file.name
            )
            var finalURL = destination.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                switch policy {
                case .skip:
                    lines.append("Skipped \(file.name): the file already exists.")
                    updateProgress(offset + 1, detail: file.name)
                    continue
                case .replace:
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: normalizedExport)
                case .rename:
                    finalURL = uniqueURL(for: finalURL)
                    try FileManager.default.moveItem(at: normalizedExport, to: finalURL)
                }
            } else {
                try FileManager.default.moveItem(at: normalizedExport, to: finalURL)
            }
            lines.append("\(file.name) → \(finalURL.lastPathComponent)")
            updateProgress(offset + 1, detail: file.name)
        }
        publishSuccess(title: "Original Files Copied", lines: lines)
        progress = nil
        if revealInFinder ?? settings.openExportDestination {
            NSWorkspace.shared.open(destination)
        }
    }

    func requestDeleteSelected() {
        guard !selectedFiles.isEmpty else { return }
        showDeleteConfirmation = true
    }

    func deleteSelected() {
        let files = selectedFiles
        selection.removeAll()
        showDeleteConfirmation = false
        start { try await self.delete(files: files) }
    }

    func delete(files: [AkaiFile]) async throws {
        guard session != nil else { throw AppError.noImageOpen }
        guard session?.readOnly == false else { throw AppError.readOnly }
        selection.subtract(files.map(\.id))
        progress = OperationProgress(kind: .deleting, current: 0, total: files.count, detail: "Deleting selected files")
        let order = AkaiCommandBuilder.deletionOrder(files.map(\.index))
        for (offset, index) in order.enumerated() {
            _ = try await run(try AkaiCommandBuilder.delete(index: index))
            updateProgress(offset + 1, detail: "File \(index)")
        }
        try await refresh()
        publishSuccess(title: "Files Deleted", lines: files.map(\.name))
        progress = nil
    }

    func deleteAllFiles() {
        showDeleteAllConfirmation = false
        start {
            guard let session = self.session else { throw AppError.noImageOpen }
            var lines: [String] = []
            if self.settings.backupBeforeDestructive {
                await self.controller.close()
                let backup = try self.createTimestampedBackup(
                    of: session.imageURL
                )
                lines.append("Backup: \(backup.path)")
                _ = try await self.controller.open(
                    imageURL: session.imageURL,
                    executableURL: self.settings.executableURL,
                    readOnly: false
                )
            }
            self.progress = OperationProgress(kind: .deleting, current: 0, total: self.snapshot.files.count, detail: "Deleting every file")
            let order = AkaiCommandBuilder.deletionOrder(self.snapshot.files.map(\.index))
            for (offset, index) in order.enumerated() {
                _ = try await self.run(try AkaiCommandBuilder.delete(index: index))
                self.updateProgress(offset + 1, detail: "File \(index)")
            }
            try await self.refresh()
            lines.append("Deleted \(order.count) files.")
            self.publishSuccess(title: "Volume Emptied", lines: lines)
            self.progress = nil
        }
    }

    func fixSelectedRAMNames() {
        let files = selectedFiles
        start {
            guard self.session != nil else { throw AppError.noImageOpen }
            guard self.session?.readOnly == false else { throw AppError.readOnly }
            self.progress = OperationProgress(kind: .importing, current: 0, total: files.count, detail: "Repairing internal names")
            for (offset, file) in files.enumerated() {
                _ = try await self.run(try AkaiCommandBuilder.fixRAMName(index: file.index))
                self.updateProgress(offset + 1, detail: file.name)
            }
            try await self.refresh()
            self.publishSuccess(
                title: "Internal Names Repaired",
                lines: files.map(\.name)
            )
            self.progress = nil
        }
    }

    func fixAllRAMNames() {
        start {
            guard self.session != nil else { throw AppError.noImageOpen }
            guard self.session?.readOnly == false else { throw AppError.readOnly }
            self.progress = OperationProgress(kind: .importing, current: 0, total: 1, detail: "Repairing internal names")
            _ = try await self.run("fixramnameall")
            try await self.refresh()
            self.publishSuccess(
                title: "Internal Names Repaired",
                lines: [
                    "AKAI Util repaired every compatible sample header in this volume."
                ]
            )
            self.progress = nil
        }
    }

    func backupImage() {
        start { try await self.backupCurrentImage() }
    }

    func backupCurrentImage() async throws {
        guard let session else { throw AppError.noImageOpen }
        progress = OperationProgress(kind: .backingUp, current: 0, total: 1, detail: session.imageURL.lastPathComponent)
        await controller.close()
        let backup = try createTimestampedBackup(of: session.imageURL)
        _ = try await controller.open(
            imageURL: session.imageURL,
            executableURL: settings.executableURL,
            readOnly: session.readOnly
        )
        try await refresh()
        publishSuccess(title: "Backup Created", lines: [backup.path])
        progress = nil
    }

    func createAndFormat(at url: URL, preset: FormatPreset) {
        showFormatSheet = false
        start { try await self.createFormattedImage(at: url, preset: preset) }
    }

    func createFormattedImage(at url: URL, preset: FormatPreset) async throws {
        progress = OperationProgress(kind: .formatting, current: 0, total: 3, detail: "Creating \(url.lastPathComponent)")
        await controller.close()
        session = nil
        do {
            try ImageFileOperations.createZeroFilledImage(at: url, byteCount: preset.byteCount)
            updateProgress(1, detail: "Formatting \(preset.rawValue)")
            let opened = try await controller.open(imageURL: url, executableURL: settings.executableURL, readOnly: false)
            appendLog(opened)
            session = ImageSession(imageURL: url, readOnly: false, removableVolumeURL: USBVolumeResolver.owningVolume(for: url), openedAt: Date())
            _ = try await run(preset.command)
            try await createInitialVolumeIfNeeded(for: preset)
            updateProgress(2, detail: "Verifying filesystem")
            try await refresh()
            guard !snapshot.disks.isEmpty else { throw AppError.verificationFailed("AKAI Util did not report a formatted disk.") }
            updateProgress(3, detail: "Ready")
            remember(url)
            publishSuccess(
                title: "Image Created",
                lines: [
                    url.path,
                    preset.rawValue,
                    "\(preset.byteCount) bytes; verified by AKAI Util."
                ]
            )
            progress = nil
        } catch {
            await controller.close()
            session = nil
            incompleteImageURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
            throw error
        }
    }

    func formatCurrent(preset: FormatPreset, backup: Bool) {
        showFormatSheet = false
        start {
            guard let session = self.session else { throw AppError.noImageOpen }
            guard !session.readOnly else { throw AppError.readOnly }
            let currentSize = UInt64((try session.imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard currentSize == preset.byteCount else {
                throw AppError.verificationFailed(
                    "\(preset.rawValue) requires an exact \(Int64(preset.byteCount).formattedByteCount) image, "
                        + "but \(session.imageURL.lastPathComponent) is \(Int64(currentSize).formattedByteCount)."
                )
            }
            var lines: [String] = []
            if backup {
                await self.controller.close()
                let destination = try self.createTimestampedBackup(
                    of: session.imageURL
                )
                lines.append("Backup: \(destination.path)")
                _ = try await self.controller.open(imageURL: session.imageURL, executableURL: self.settings.executableURL, readOnly: false)
            }
            self.progress = OperationProgress(kind: .formatting, current: 0, total: 2, detail: preset.rawValue)
            _ = try await self.run(preset.command)
            try await self.createInitialVolumeIfNeeded(for: preset)
            self.updateProgress(1, detail: "Verifying filesystem")
            try await self.refresh()
            guard !self.snapshot.disks.isEmpty else { throw AppError.verificationFailed("The formatted filesystem could not be read.") }
            self.updateProgress(2, detail: "Ready")
            lines.append("Formatted: \(session.imageURL.path)")
            self.publishSuccess(title: "Image Formatted", lines: lines)
            self.progress = nil
        }
    }

    private func createInitialVolumeIfNeeded(
        for preset: FormatPreset
    ) async throws {
        guard preset.requiresInitialVolume else { return }
        _ = try await run("mkvol9 /disk0/A/VOLUME_001")
        _ = try await run(
            try AkaiCommandBuilder.changeDirectory(
                "/disk0/A/VOLUME 001"
            )
        )
    }

    func removeIncompleteImage() {
        guard let url = incompleteImageURL else { return }
        try? FileManager.default.removeItem(at: url)
        incompleteImageURL = nil
    }

    func cleanEject() {
        start { try await self.performCleanEject() }
    }

    func performCleanEject() async throws {
        guard let session, let volume = session.removableVolumeURL else { throw AppError.usbVolumeNotFound }
        guard let usbClean = settings.usbCleanURL else { throw AppError.usbCleanNotFound }
        progress = OperationProgress(kind: .ejecting, current: 0, total: 2, detail: volume.lastPathComponent)
        await controller.close()
        self.session = nil
        snapshot = DiskSnapshot()
        selection.removeAll()
        updateProgress(1, detail: "Handing volume to USBclean")
        try await ImageFileOperations.handToUSBclean(volume: volume, application: usbClean)
        updateProgress(1, detail: "Waiting for \(volume.lastPathComponent) to unmount")
        try await ImageFileOperations.waitUntilUnmounted(volume: volume)
        updateProgress(2, detail: "Safe to unplug")
        report = nil
        headerNotice = HeaderNotice(
            title: "\(volume.lastPathComponent) safely ejected",
            detail: "The volume is no longer mounted and is safe to unplug.",
            systemImage: "eject.circle.fill"
        )
        progress = nil
    }

    func copyToUSBAndEject() {
        guard let destination = usbCopyDestination else {
            reportError(AppError.usbVolumeNotFound)
            return
        }
        start { try await self.performCopyToUSB(destination: destination) }
    }

    func performCopyToUSB(destination: URL) async throws {
        guard let session, !session.isRemovable else { throw AppError.usbVolumeNotFound }
        let destinationVolume = USBVolumeResolver.owningVolume(for: destination)
        guard let destinationVolume else { throw AppError.usbVolumeNotFound }
        progress = OperationProgress(kind: .copying, current: 0, total: 3, detail: destination.path)
        await controller.close()
        self.session = nil
        try ImageFileOperations.copyAtomicallyAndVerify(source: session.imageURL, destination: destination)
        updateProgress(2, detail: "Copy verified")
        if settings.ejectAfterUSBCopy {
            guard let usbClean = settings.usbCleanURL else { throw AppError.usbCleanNotFound }
            try await ImageFileOperations.handToUSBclean(volume: destinationVolume, application: usbClean)
            updateProgress(2, detail: "Waiting for \(destinationVolume.lastPathComponent) to unmount")
            try await ImageFileOperations.waitUntilUnmounted(volume: destinationVolume)
            updateProgress(3, detail: "Safe to unplug")
            report = nil
            headerNotice = HeaderNotice(
                title: "Copy verified; \(destinationVolume.lastPathComponent) safely ejected",
                detail: "The volume is no longer mounted and is safe to unplug.",
                systemImage: "checkmark.circle.fill"
            )
        } else {
            updateProgress(3, detail: "Copy complete")
            publishSuccess(
                title: "USB Copy Complete",
                lines: [
                    "Source: \(session.imageURL.path)",
                    "Destination: \(destination.path)",
                    "File size and SHA-256 checksum verified."
                ]
            )
        }
        progress = nil
    }

    func cancelOperation() {
        currentOperationTask?.cancel()
        Task { await controller.cancel() }
    }

    func copyDiskInfo() {
        let text = diskInformationText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var diskInformationText: String {
        guard let session else { return "No image open." }
        let size = (try? session.imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let lines = [
            "Image: \(session.imageURL.path)",
            "Image size: \(size.formattedByteCount)",
            "Location: \(session.isRemovable ? "Removable media" : "Local")",
            "Access: \(session.readOnly ? "Read-only" : "Read/write")",
            "Current AKAI path: \(snapshot.currentPath)",
            "Files: \(snapshot.fileCount)" + snapshot.maximumFileCount.map { " of \($0)" }.orEmpty,
            "Used: \(snapshot.usedBytes.formattedByteCount)",
            "Free: \(snapshot.freeBytes.formattedByteCount)",
            "",
            snapshot.rawDF,
            "",
            snapshot.rawDInfo
        ]
        return lines.joined(separator: "\n")
    }

    func stageKeygroupTransfer(
        from program: P9Program,
        indexes: Set<Int>,
        source: P9EditorDocument.Source
    ) async throws {
        let programHeaderTemplate = try program.destinationHeaderTemplate()
        let records = try program.keygroupRecords(at: indexes)
        let sampleNames = try program.sampleNames(at: indexes)
        let workspace = try TemporaryWorkspace(prefix: "akai-keygroup-copy")
        var retained = false
        defer {
            if !retained {
                workspace.remove()
            }
        }

        var sampleFiles: [String: URL] = [:]
        var missingSampleNames: [String] = []
        var sourceImageURL: URL?
        var sourceVolumePath: String?

        if let copiedFromImageURL = source.imageURL {
            guard let session,
                  session.imageURL.standardizedFileURL
                    == copiedFromImageURL.standardizedFileURL
            else {
                throw AppError.verificationFailed(
                    "The source IMG is no longer open. Reopen the source program and copy again."
                )
            }
            sourceImageURL = session.imageURL
            sourceVolumePath = snapshot.currentPath
            progress = OperationProgress(
                kind: .exporting,
                current: 0,
                total: max(1, sampleNames.count),
                detail: "Staging associated S9 samples"
            )
            _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))

            for (offset, name) in sampleNames.enumerated() {
                try Task.checkCancellation()
                updateProgress(offset, detail: name)
                guard let file = sampleFile(matchingP9Name: name) else {
                    missingSampleNames.append(name)
                    updateProgress(offset + 1, detail: "\(name) not found")
                    continue
                }

                let filesBefore = Set(
                    (try FileManager.default.contentsOfDirectory(
                        at: workspace.url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )).map(\.standardizedFileURL)
                )
                _ = try await run(try AkaiCommandBuilder.exportNative(index: file.index))
                let filesAfter = try FileManager.default.contentsOfDirectory(
                    at: workspace.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                guard let exported = filesAfter.first(where: {
                    !filesBefore.contains($0.standardizedFileURL)
                        && $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame
                }) else {
                    missingSampleNames.append(name)
                    updateProgress(offset + 1, detail: "\(name) did not export")
                    continue
                }

                let stagedURL = workspace.url
                    .appendingPathComponent(String(format: "sample-%03d.S9", offset + 1))
                try FileManager.default.moveItem(at: exported, to: stagedURL)
                sampleFiles[name.uppercased()] = stagedURL
                updateProgress(offset + 1, detail: name)
            }
        } else {
            missingSampleNames = sampleNames
        }

        let transfer = P9KeygroupTransfer(
            programHeaderTemplate: programHeaderTemplate,
            records: records,
            sampleFiles: sampleFiles,
            sampleNames: sampleNames,
            missingSampleNames: missingSampleNames,
            sourceProgramName: source.filename,
            sourceImageURL: sourceImageURL,
            sourceVolumePath: sourceVolumePath,
            createdAt: Date()
        )
        keygroupTransferWorkspace?.remove()
        keygroupTransferWorkspace = workspace
        keygroupTransfer = transfer
        retained = true
        progress = nil

        var lines = [
            transfer.summary,
            "The copied data remains available after closing this IMG."
        ]
        if !missingSampleNames.isEmpty {
            lines.append(
                "Samples not staged: \(missingSampleNames.joined(separator: ", "))."
            )
        }
        publishSuccess(title: "Keygroups Copied", lines: lines)
    }

    func applyKeygroupTransfer(
        _ transfer: P9KeygroupTransfer,
        to document: P9EditorDocument
    ) async throws {
        guard document.pendingKeygroupPaste == nil,
              !document.isPreparingKeygroupPaste
        else {
            throw AppError.verificationFailed(
                "Apply the current pasted keygroups before pasting another set."
            )
        }
        document.isPreparingKeygroupPaste = true
        defer {
            document.isPreparingKeygroupPaste = false
            progress = nil
        }

        var validationProgram = document.program
        try validationProgram.appendKeygroups(records: transfer.records)

        var sampleNameMapping: [String: String] = [:]
        var lines: [String] = []
        if let destinationImageURL = document.source.imageURL {
            guard let session,
                  session.imageURL.standardizedFileURL
                    == destinationImageURL.standardizedFileURL
            else {
                throw AppError.verificationFailed(
                    "The destination IMG is no longer open. Reopen the destination program and paste again."
                )
            }
            guard !session.readOnly else { throw AppError.readOnly }
            let sameLocation = transfer.sourceImageURL?.standardizedFileURL
                    == session.imageURL.standardizedFileURL
                && transfer.sourceVolumePath == snapshot.currentPath
            let imported = try await importTransferredSamples(
                transfer,
                reusingExistingSourceSamples: sameLocation
            )
            sampleNameMapping = imported.mapping
            lines.append(contentsOf: imported.lines)
        } else if !transfer.sampleNames.isEmpty {
            lines.append(
                "Keygroups pasted into a standalone P9; associated S9 samples were not imported into an IMG."
            )
        }

        lines.insert(
            "\(transfer.records.count) keygroup"
                + "\(transfer.records.count == 1 ? "" : "s") ready to apply to "
                + "\(document.source.filename).",
            at: 0
        )
        lines.append("Click Apply Pasted Keygroups, then use Save Edited Copy…")
        try document.stageKeygroupPaste(
            records: transfer.records,
            sampleNameMapping: sampleNameMapping,
            statusLines: lines
        )
    }

    private func importTransferredSamples(
        _ transfer: P9KeygroupTransfer,
        reusingExistingSourceSamples: Bool
    ) async throws -> (mapping: [String: String], lines: [String]) {
        struct PlannedSample {
            let sourceName: String
            let targetName: String
            let sourceURL: URL
        }

        let existingSamples = snapshot.files.filter(\.isSample)
        var existingByName: [String: String] = [:]
        for file in existingSamples {
            let base = Self.sampleBaseName(file.name)
            existingByName[Self.normalizedSampleKey(base)] = base
        }
        var existingNames = Set(
            existingSamples.map {
                AkaiFilename.sanitizedBase(
                    Self.sampleBaseName($0.name),
                    family: .s900,
                    maximumLength: 10
                ).uppercased()
            }
        )
        var mapping: [String: String] = [:]
        var lines: [String] = []
        var planned: [PlannedSample] = []

        for sourceName in transfer.sampleNames {
            let key = sourceName.uppercased()
            if reusingExistingSourceSamples,
               let existing = existingByName[Self.normalizedSampleKey(sourceName)] {
                mapping[key] = existing
                lines.append("Reused \(existing).S from the source volume.")
                continue
            }
            guard let sourceURL = transfer.sampleFiles[key] else {
                lines.append("Sample \(sourceName) was not available in the copied bundle.")
                continue
            }

            var targetName = AkaiFilename.sanitizedBase(
                sourceName,
                family: .s900,
                maximumLength: 10
            )
            if existingNames.contains(targetName.uppercased()) {
                targetName = AkaiFilename.uniqueName(
                    base: targetName,
                    existing: existingNames,
                    maximumLength: 10
                )
            }
            existingNames.insert(targetName.uppercased())
            existingByName[Self.normalizedSampleKey(targetName)] = targetName
            mapping[key] = targetName
            planned.append(
                PlannedSample(
                    sourceName: sourceName,
                    targetName: targetName,
                    sourceURL: sourceURL
                )
            )
        }

        if let maximum = snapshot.maximumFileCount,
           snapshot.fileCount + planned.count > maximum {
            throw AppError.verificationFailed(
                "The destination volume has room for only \(maximum - snapshot.fileCount) more files, but this paste needs \(planned.count)."
            )
        }
        let requiredBytes = try planned.reduce(Int64(0)) { total, item in
            let size = try item.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return total + Int64(size)
        }
        if snapshot.freeBytes > 0, requiredBytes > snapshot.freeBytes {
            throw AppError.insufficientSpace(
                required: requiredBytes,
                available: snapshot.freeBytes
            )
        }

        guard !planned.isEmpty else {
            return (mapping, lines)
        }

        let workspace = try TemporaryWorkspace(prefix: "akai-keygroup-paste")
        defer { workspace.remove() }
        _ = try await run(try AkaiCommandBuilder.localDirectory(workspace.url.path))
        progress = OperationProgress(
            kind: .importing,
            current: 0,
            total: planned.count,
            detail: "Importing associated S9 samples"
        )

        for (offset, item) in planned.enumerated() {
            try Task.checkCancellation()
            updateProgress(offset, detail: item.targetName)
            let filename = "\(item.targetName).S9"
            let stagedURL = workspace.url.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: item.sourceURL, to: stagedURL)
            try S9NativeSample.renameInternalName(
                in: stagedURL,
                to: item.targetName
            )
            _ = try await run(try AkaiCommandBuilder.importNative(filename: filename))
            lines.append(
                item.sourceName == item.targetName
                    ? "Imported \(item.targetName).S"
                    : "Imported \(item.sourceName) as \(item.targetName).S"
            )
            updateProgress(offset + 1, detail: item.targetName)
        }

        try await refresh()
        var importedByName: [String: String] = [:]
        for file in snapshot.files.filter(\.isSample) {
            let base = Self.sampleBaseName(file.name)
            importedByName[Self.normalizedSampleKey(base)] = base
        }
        let sampleList = snapshot.files.filter(\.isSample).map(\.name)
            .joined(separator: ", ")
        for item in planned {
            guard let actualName = importedByName[
                Self.normalizedSampleKey(item.targetName)
            ] else {
                throw AppError.verificationFailed(
                    "AKAI Util did not create \(item.targetName).S in the destination volume. "
                        + "Samples now present: \(sampleList)."
                )
            }
            mapping[item.sourceName.uppercased()] = actualName
        }
        return (mapping, lines)
    }

    private func sampleFile(matchingP9Name name: String) -> AkaiFile? {
        snapshot.files.first {
            $0.isSample
                && Self.normalizedSampleKey(Self.sampleBaseName($0.name))
                    == Self.normalizedSampleKey(name)
        }
    }

    private static func sampleBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedSampleKey(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: "_", with: " ")
    }

    private static func nativeDataDifferenceSummary(
        expected: Data,
        actual: Data
    ) -> String {
        let sharedCount = min(expected.count, actual.count)
        let differingOffsets = (0..<sharedCount).lazy.filter {
            expected[$0] != actual[$0]
        }
        let firstOffsets = Array(differingOffsets.prefix(8))
        let offsets = firstOffsets.map {
            String(format: "0x%X", $0)
        }.joined(separator: ", ")
        let sizeDetail = "prepared \(expected.count) bytes; exported \(actual.count) bytes"
        guard !firstOffsets.isEmpty else {
            return "Sizes: \(sizeDetail)."
        }
        return "First changed byte\(firstOffsets.count == 1 ? "" : "s"): \(offsets). Sizes: \(sizeDetail)."
    }

    private func run(_ command: String) async throws -> CommandResult {
        let result = try await controller.send(command)
        appendLog(result)
        if AkaiCommandBuilder.modifiesImage(command),
           let imageURL = session?.imageURL {
            do {
                try ImageFileOperations.updateModificationDate(of: imageURL)
            } catch {
                diagnosticLog += "[\(Date.formattedLogTime)] ! Could not update IMG modification date: \(error.localizedDescription)\n\n"
            }
        }
        return result
    }

    private func createTimestampedBackup(of imageURL: URL) throws -> URL {
        try ImageFileOperations.timestampedBackup(
            of: imageURL,
            destinationDirectory: settings.backupDestination(for: imageURL)
        )
    }

    private func appendLog(_ result: CommandResult) {
        let stamp = Date.formattedLogTime
        diagnosticLog += "[\(stamp)] › \(result.command)\n\(result.cleanedOutput)\n\n"
    }

    private func updateProgress(_ current: Int, detail: String) {
        guard var progress else { return }
        progress.current = current
        progress.detail = detail
        self.progress = progress
    }

    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !operationActive else {
            reportError(AppError.controllerBusy)
            return
        }
        headerNotice = nil
        operationActive = true
        currentOperationTask = Task {
            do {
                try await operation()
            } catch is CancellationError {
                progress = nil
                publishSuccess(
                    title: "Operation Cancelled",
                    lines: ["The active operation was cancelled."],
                    systemImage: "xmark.circle"
                )
            } catch {
                progress = nil
                reportError(error)
            }
            currentOperationTask = nil
            operationActive = false
        }
    }

    private func reportError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        headerNotice = nil
        report = OperationReport(title: "AKAI Image Manager", lines: [message], isError: true)
        if settings.autoOpenLogOnError { isLogVisible = true }
    }

    func publishSuccess(
        title: String,
        lines: [String],
        systemImage: String = "checkmark.circle.fill"
    ) {
        let meaningfulLines = lines.filter { !$0.isEmpty }
        let visibleLines = meaningfulLines.prefix(2)
        var detail = visibleLines.joined(separator: " • ")
        if meaningfulLines.count > visibleLines.count {
            detail += " • \(meaningfulLines.count - visibleLines.count) more"
        }
        if detail.isEmpty {
            detail = "Completed."
        }
        report = nil
        headerNotice = HeaderNotice(
            title: title,
            detail: detail,
            systemImage: systemImage
        )
    }

    private func uniqueURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for number in 2...999 {
            let candidate = directory.appendingPathComponent("\(stem) \(number)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private func uniqueDirectoryURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for number in 2...999 {
            let candidate = parent.appendingPathComponent(
                "\(name) \(number)",
                isDirectory: true
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    }

    private static func safeExportComponent(
        _ value: String,
        fallback: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:\0")
        let cleaned = source.unicodeScalars.map { scalar in
            invalid.contains(scalar) ? "_" : String(scalar)
        }.joined()
        return cleaned.isEmpty ? "AKAI PROGRAM" : cleaned
    }

    private func remember(_ url: URL) {
        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentURLs.insert(url.standardizedFileURL, at: 0)
        recentURLs = Array(recentURLs.prefix(10))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentImages")
    }

    private func loadRecentImages() {
        recentURLs = (UserDefaults.standard.stringArray(forKey: "recentImages") ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func isWAV(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame
    }

    private func isNativeAkaiURL(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.uppercased()
        return fileExtension == "S9" || fileExtension == "P9"
    }

    private func isImportableAudioOrAkaiFile(_ url: URL) -> Bool {
        isWAV(url) || isNativeAkaiURL(url)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

private extension String {
    var pathExtensionUppercased: String {
        (self as NSString).pathExtension.uppercased()
    }
}

private extension Date {
    static var formattedLogTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
