import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            BrowserHeader()
            Divider()
            FileBrowser()
            Divider()
            StatusBar()
            if model.isLogVisible {
                Divider()
                DiagnosticLogView()
                    .frame(minHeight: 120, idealHeight: 190, maxHeight: 260)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle(model.session?.imageURL.lastPathComponent ?? "AKAI Image Manager")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDroppedURLs(urls)
            return !urls.isEmpty
        } isTargeted: { _ in }
        .sheet(isPresented: $model.showImportSheet) {
            ImportOptionsSheet()
                .environmentObject(model)
                .environmentObject(settings)
        }
        .sheet(isPresented: $model.showFormatSheet) {
            FormatImageSheet()
                .environmentObject(model)
                .environmentObject(settings)
        }
        .sheet(isPresented: $model.showDiskInfo) {
            DiskInfoSheet()
                .environmentObject(model)
        }
        .sheet(item: $model.fileInformation) { information in
            AkaiFileInformationSheet(information: information)
        }
        .sheet(item: $model.p9EditorDocument) { document in
            P9EditorSheet(
                document: document,
                keygroupTransfer: model.keygroupTransfer,
                availableSampleNames: model.availableSampleNames,
                onCopyKeygroups: { program, indexes, source in
                    model.copyKeygroups(
                        from: program,
                        indexes: indexes,
                        source: source
                    )
                },
                onPasteKeygroups: { destination in
                    model.pasteKeygroups(into: destination)
                },
                onOverwriteP9: { document, createBackup in
                    model.overwriteP9InImage(
                        document,
                        createBackup: createBackup
                    )
                },
                onCreateP9InImage: { document in
                    model.createP9InImage(document)
                },
                onChooseAbletonDrumRack: { document in
                    model.chooseAbletonDrumRack(for: document)
                },
                onImportAbletonDrumRack: { draft, document in
                    model.importAbletonDrumRack(draft, into: document)
                }
            )
        }
        .sheet(item: $model.externalSampleEditSession) { editSession in
            ExternalSampleEditSheet(editSession: editSession)
                .environmentObject(model)
                .environmentObject(settings)
        }
        .alert(item: Binding(
            get: { model.report?.isError == true ? model.report : nil },
            set: { model.report = $0 }
        )) { report in
            Alert(
                title: Text(report.title),
                message: Text(report.lines.joined(separator: "\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Delete selected files permanently?", isPresented: $model.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteSelected() }
        } message: {
            Text(model.selectedFiles.map { "\($0.index). \($0.name)" }.joined(separator: "\n")
                 + "\n\nDeletion inside an IMG cannot be undone without a backup.")
        }
        .sheet(isPresented: $model.showDeleteAllConfirmation) {
            DeleteAllSheet()
                .environmentObject(model)
                .environmentObject(settings)
        }
        .alert("Formatting did not complete", isPresented: Binding(
            get: { model.incompleteImageURL != nil },
            set: { if !$0 { model.incompleteImageURL = nil } }
        )) {
            Button("Keep File", role: .cancel) { model.incompleteImageURL = nil }
            Button("Delete Incomplete Image", role: .destructive) { model.removeIncompleteImage() }
        } message: {
            Text("The newly created image could not be verified. Delete \(model.incompleteImageURL?.lastPathComponent ?? "it")?")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.openPanel) {
                Label("Open Image", systemImage: "folder")
            }
            .help("Open an AKAI disk image (⌘O)")

            Button { model.showFormatSheet = true } label: {
                Label("New or Format", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Create or format an image")

            Button(action: model.importPanel) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canImport)
            .help("Import WAV, S9 or P9 files")

            Button(action: model.exportSelected) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canExport)
            .help("Export selected samples to WAV, or selected P9 programs as native files")

            Button(action: model.editSelectedP9) {
                Label("Edit P9", systemImage: "slider.horizontal.3")
            }
            .disabled(!model.canEditSelectedP9)
            .help("Open the selected P9 in the safe keygroup editor")

            Button(action: model.createP9Program) {
                Label("New Program", systemImage: "doc.badge.plus")
            }
            .disabled(!model.canCreateP9Program)
            .help("Create a new S950 program with one blank keygroup")

            Button(action: model.editSelectedSampleInAudioEditor) {
                Label("Edit Sample", systemImage: "waveform.badge.pencil")
            }
            .disabled(!model.canEditSelectedS9Sample)
            .help("Edit one selected S950 sample and optionally open its WAV in an audio editor")

            Button(action: model.requestDeleteSelected) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!model.canMutate || model.selectedFiles.isEmpty)
            .help("Permanently delete selected files")

            Button(action: model.refreshAction) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.session == nil || model.isBusy)
            .help("Refresh disks, volumes and files (⌘R)")

            Button {
                model.showDiskInfo = true
            } label: {
                Label("Disk Info", systemImage: "info.circle")
            }
            .disabled(model.session == nil || model.isBusy)
            .help("Show parsed disk information and diagnostics")

            Button(action: model.backupImage) {
                Label("Backup", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.session == nil || model.isBusy)
            .help("Create a timestamped backup in the configured backup folder")

            Button(action: model.cleanEject) {
                Label("Clean Eject", systemImage: "eject.circle")
            }
            .disabled(model.session?.isRemovable != true || model.isBusy)
            .help("Close AKAI Util, flush writes, then hand the owning volume to USBclean")

            Menu {
                Button("New S950 Program…") {
                    model.createP9Program()
                }
                .disabled(!model.canCreateP9Program)
                Button("New Program from Copied Keygroups…") {
                    model.createP9FromCopiedKeygroups()
                }
                .disabled(!model.canCreateP9FromCopiedKeygroups)
                Divider()
                Button("Disk Information…") { model.showDiskInfo = true }
                Button("Create Timestamped Backup") { model.backupImage() }
                    .disabled(model.session == nil)
                Divider()
                Button("Repair Selected Internal Sample Names") { model.fixSelectedRAMNames() }
                    .disabled(!model.canMutate || model.selectedFiles.isEmpty)
                Button("Repair All Internal Sample Names") { model.fixAllRAMNames() }
                    .disabled(!model.canMutate)
                Divider()
                Button("Delete All Files in Volume…", role: .destructive) {
                    model.showDeleteAllConfirmation = true
                }
                .disabled(!model.canMutate || model.snapshot.files.isEmpty)
                Divider()
                if model.session?.isRemovable == true {
                    Button("Clean and Eject") { model.cleanEject() }
                }
                if let destination = model.usbCopyDestination {
                    Button("Copy to \(destination.deletingLastPathComponent().lastPathComponent) and Eject…") {
                        confirmUSBCopy(destination)
                    }
                }
                Toggle("Diagnostic Log", isOn: $model.isLogVisible)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(model.session == nil && !model.isLogVisible)
            .help("More image, repair, deletion and diagnostic actions")
        }
    }

    private func confirmUSBCopy(_ destination: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace the USB image?"
        alert.informativeText = "Source:\n\(model.session?.imageURL.path ?? "")\n\nDestination:\n\(destination.path)\n\nAKAI Util will close before the verified copy begins."
        alert.addButton(withTitle: "Copy and Replace")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.copyToUSBAndEject() }
    }
}

private struct BrowserHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let notice = model.headerNotice {
                    Label(notice.title, systemImage: notice.systemImage)
                        .font(.headline)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else {
                    Text(model.session == nil ? "No Image Open" : displayPath)
                        .font(.headline)
                        .lineLimit(1)
                }
                if let notice = model.headerNotice {
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let session = model.session {
                    Text(session.imageURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Open an IMG, ISO, or compatible raw image to begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.session != nil {
                if model.snapshot.volumes.count > 1 {
                    Menu {
                        ForEach(model.snapshot.volumes) { volume in
                            Button {
                                model.navigate(to: volume)
                            } label: {
                                if model.snapshot.currentPath == volume.path {
                                    Label(volume.name, systemImage: "checkmark")
                                } else {
                                    Text(volume.name)
                                }
                            }
                        }
                    } label: {
                        Label(currentVolumeName, systemImage: "folder")
                    }
                    .help("Choose an S950 volume")
                }
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(model.snapshot.fileCount) files")
                        .font(.subheadline.weight(.medium))
                    Text("\(model.snapshot.freeBytes.formattedByteCount) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var displayPath: String {
        if let currentVolume = model.snapshot.volumes.first(where: {
            $0.path == model.snapshot.currentPath
        }) {
            return currentVolume.name
        }
        if !model.snapshot.volumes.isEmpty {
            return "Choose an S950 Volume"
        }
        return model.snapshot.currentPath
            .split(separator: "/")
            .last
            .map(String.init) ?? "AKAI Image"
    }

    private var currentVolumeName: String {
        model.snapshot.volumes.first {
            $0.path == model.snapshot.currentPath
        }?.name ?? "Choose Volume"
    }
}

private struct FileBrowser: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.session == nil {
                ContentUnavailableView {
                    Label("Open an AKAI Image", systemImage: "opticaldiscdrive")
                } description: {
                    Text("Browse, import, export, back up and safely eject S950 images.")
                } actions: {
                    Button("Open Image…") { model.openPanel() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.snapshot.files.isEmpty {
                ContentUnavailableView {
                    Label("This Volume Is Empty", systemImage: "waveform.badge.plus")
                } description: {
                    Text(model.session?.readOnly == true
                         ? "The image is open read-only."
                         : "Drop WAV, S9 or P9 files here, or use Import.")
                } actions: {
                    HStack {
                        Button("New S950 Program…") {
                            model.createP9Program()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canCreateP9Program)
                        if model.keygroupTransfer != nil {
                            Button("From Copied Keygroups…") {
                                model.createP9FromCopiedKeygroups()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!model.canCreateP9FromCopiedKeygroups)
                        }
                        Button("Import Files…") { model.importPanel() }
                            .buttonStyle(.bordered)
                            .disabled(!model.canImport)
                    }
                }
            } else {
                Table(
                    model.displayedFiles,
                    selection: $model.selection,
                    sortOrder: $model.fileSortOrder
                ) {
                    TableColumn("#") { file in
                        selectionCell(for: file) {
                            Text(file.index, format: .number)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 38, ideal: 46, max: 58)
                    TableColumn("Name", value: \.name) { file in
                        selectionCell(for: file) {
                            FileNameCell(file: file)
                        }
                    }
                    .width(min: 180, ideal: 300)
                    TableColumn("Type", value: \.type) { file in
                        selectionCell(for: file) {
                            Text(file.type)
                        }
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Size", value: \.byteSize) { file in
                        selectionCell(for: file) {
                            Text(file.byteSize.formattedByteCount)
                                .monospacedDigit()
                        }
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Start Block") { file in
                        selectionCell(for: file) {
                            Group {
                                if let block = file.startBlock {
                                    Text(String(format: "0x%04X", block))
                                        .monospaced()
                                } else {
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Compression") { file in
                        selectionCell(for: file) {
                            Text(file.compression ?? "—")
                        }
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("") { file in
                        if model.isNativeAkaiFile(file) {
                            ZStack {
                                Color.clear
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                                NativeFileDragSource(file: file, model: model)
                            }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .help(
                                    "Drag selected original S9/P9 files to Finder"
                                )
                        }
                    }
                    .width(min: 32, ideal: 32, max: 32)
                }
                .background(
                    NativeTableDoubleClickMonitor { row in
                        guard model.displayedFiles.indices.contains(row) else {
                            return
                        }
                        model.openEditor(for: model.displayedFiles[row])
                    }
                )
                .contextMenu(forSelectionType: AkaiFile.ID.self) { selection in
                    Button("Edit P9 Keygroups…") {
                        model.editP9(withIDs: selection)
                    }
                    .disabled(!model.containsSingleP9(withIDs: selection))
                    Button("Edit Sample…") {
                        model.editSelectedSampleInAudioEditor()
                    }
                    .disabled(
                        selection.count != 1
                            || !model.canEditSelectedS9Sample
                    )
                    Button("Export Selected…") {
                        model.exportSelected(withIDs: selection)
                    }
                    .disabled(!model.snapshot.files.contains {
                        selection.contains($0.id)
                            && ($0.isSample
                                || ($0.name as NSString).pathExtension.uppercased()
                                    == "P9")
                    })
                    Button("Export P9 as Ableton Drum Rack…") {
                        model.exportP9ToAbleton(withIDs: selection)
                    }
                    .disabled(
                        !model.canExportP9ToAbleton(withIDs: selection)
                    )
                    Button("Copy Original S9/P9 Files…") {
                        model.copyNativeFiles(withIDs: selection)
                    }
                    .disabled(!model.containsNativeFile(withIDs: selection))
                    Button("File Information…") {
                        model.showFileInformation(withIDs: selection)
                    }
                    .disabled(!model.containsSingleFile(withIDs: selection))
                    Button("Rename S9/P9…") {
                        model.renameNativeFile(withIDs: selection)
                    }
                    .disabled(
                        !model.containsSingleRenameableNativeFile(
                            withIDs: selection
                        )
                    )
                    Button("Repair Internal Sample Name") { model.fixSelectedRAMNames() }
                        .disabled(selection.isEmpty || !model.canMutate)
                    Divider()
                    Button("Delete…", role: .destructive) { model.requestDeleteSelected() }
                        .disabled(selection.isEmpty || !model.canMutate)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionCell<Content: View>(
        for file: AkaiFile,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                NativeFileTableSelection.select(
                    file,
                    modifiers: NSEvent.modifierFlags,
                    model: model,
                    window: NSApp.keyWindow
                )
            }
    }
}

@MainActor
enum NativeFileTableSelection {
    static func select(
        _ file: AkaiFile,
        modifiers: NSEvent.ModifierFlags,
        model: AppModel,
        window: NSWindow?
    ) {
        model.selectFile(file, modifiers: modifiers)
        guard let window,
              let contentView = window.contentView,
              let table = NativeFileTableLocator.first(in: contentView)
        else { return }
        let selectedRows = IndexSet(
            model.displayedFiles.indices.filter {
                model.selection.contains(model.displayedFiles[$0].id)
            }
        )
        table.selectRowIndexes(selectedRows, byExtendingSelection: false)
        window.makeFirstResponder(table)
    }
}

private struct NativeTableDoubleClickMonitor: NSViewRepresentable {
    let onDoubleClick: @MainActor (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onDoubleClick: @MainActor (Int) -> Void
        private var eventMonitor: Any?

        init(onDoubleClick: @escaping @MainActor (Int) -> Void) {
            self.onDoubleClick = onDoubleClick
        }

        func install() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                guard event.clickCount == 2,
                      let self,
                      let window = self.hostView?.window,
                      event.window === window,
                      let contentView = window.contentView,
                      let table = NativeFileTableLocator.fileTable(
                        at: event.locationInWindow,
                        inside: contentView
                      )
                else { return event }
                let point = table.convert(event.locationInWindow, from: nil)
                let row = table.row(at: point)
                guard row >= 0 else { return event }
                Task { @MainActor in
                    self.onDoubleClick(row)
                }
                return event
            }
        }

        func uninstall() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

    }
}

enum NativeFileTableLocator {
    static func first(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView,
           table.numberOfColumns >= 6 {
            return table
        }
        for subview in view.subviews {
            if let table = first(in: subview) {
                return table
            }
        }
        return nil
    }

    static func fileTable(
        at windowPoint: NSPoint,
        inside view: NSView
    ) -> NSTableView? {
        if let table = view as? NSTableView,
           table.numberOfColumns >= 6 {
            let localPoint = table.convert(windowPoint, from: nil)
            if table.visibleRect.contains(localPoint) {
                return table
            }
        }
        for subview in view.subviews {
            if let table = fileTable(at: windowPoint, inside: subview) {
                return table
            }
        }
        return nil
    }
}

@MainActor
private struct NativeFileDragSource: NSViewRepresentable {
    let file: AkaiFile
    let model: AppModel

    func makeNSView(context: Context) -> NativeFileDragSourceView {
        NativeFileDragSourceView()
    }

    func updateNSView(
        _ nsView: NativeFileDragSourceView,
        context: Context
    ) {
        nsView.onMouseDown = {
            _ = model.nativeFilesForDrag(startingWith: file)
        }
        nsView.prepareDrag = {
            let files = model.nativeFilesForDrag(startingWith: file)
            guard !files.isEmpty, !model.isBusy else { return nil }
            return NativeFilePromiseCoordinator(files: files, model: model)
        }
    }
}

@MainActor
private final class NativeFileDragSourceView: NSView, NSDraggingSource {
    var onMouseDown: (() -> Void)?
    var prepareDrag: (() -> NativeFilePromiseCoordinator?)?
    private var startingPoint: NSPoint?
    private var startedDragging = false
    private var activeCoordinator: NativeFilePromiseCoordinator?

    override func mouseDown(with event: NSEvent) {
        startingPoint = convert(event.locationInWindow, from: nil)
        startedDragging = false
        onMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging,
              let startingPoint
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - startingPoint.x, point.y - startingPoint.y) >= 3
        else { return }
        guard let coordinator = prepareDrag?() else { return }

        startedDragging = true
        activeCoordinator = coordinator
        coordinator.onComplete = { [weak self, weak coordinator] in
            guard self?.activeCoordinator === coordinator else { return }
            self?.activeCoordinator = nil
        }
        let items = coordinator.draggingItems(in: bounds)
        guard !items.isEmpty else {
            activeCoordinator = nil
            return
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        startingPoint = nil
        startedDragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        startingPoint = nil
        startedDragging = false
        if operation.isEmpty {
            activeCoordinator = nil
        }
    }
}

private final class NativeFilePromiseCoordinator:
    NSObject,
    NSFilePromiseProviderDelegate
{
    let files: [AkaiFile]
    let model: AppModel
    var onComplete: (() -> Void)?
    private var providers: [NSFilePromiseProvider] = []
    private var exportTask: Task<[AkaiFile.ID: URL], Error>?
    private var completedPromises = Set<AkaiFile.ID>()

    init(files: [AkaiFile], model: AppModel) {
        self.files = files
        self.model = model
    }

    @MainActor
    func draggingItems(in bounds: NSRect) -> [NSDraggingItem] {
        providers = files.map { file in
            let type = UTType(
                filenameExtension: (file.name as NSString).pathExtension
            ) ?? .data
            let provider = NSFilePromiseProvider(
                fileType: type.identifier,
                delegate: self
            )
            provider.userInfo = file.id
            return provider
        }

        let icon = NSImage(
            systemSymbolName: files.count > 1 ? "doc.on.doc" : "doc",
            accessibilityDescription: "AKAI file"
        ) ?? NSImage()
        let size = NSSize(width: 28, height: 28)
        return providers.enumerated().map { offset, provider in
            let item = NSDraggingItem(pasteboardWriter: provider)
            let shift = CGFloat(min(offset, 4)) * 2
            item.setDraggingFrame(
                NSRect(
                    x: max(0, bounds.midX - size.width / 2 + shift),
                    y: max(0, bounds.midY - size.height / 2 - shift),
                    width: size.width,
                    height: size.height
                ),
                contents: icon
            )
            return item
        }
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        file(for: filePromiseProvider)?.name ?? "AKAI-File.S9"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let file = file(for: filePromiseProvider) else {
            completionHandler(
                AppError.verificationFailed("The dragged AKAI file is unavailable.")
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            do {
                let exports = try await exportedFiles()
                guard let source = exports[file.id] else {
                    throw AppError.verificationFailed(
                        "AKAI Util did not create \(file.name)."
                    )
                }
                try FileManager.default.copyItem(at: source, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            completedPromises.insert(file.id)
            if completedPromises.count == files.count {
                onComplete?()
            }
        }
    }

    @MainActor
    private func exportedFiles() async throws -> [AkaiFile.ID: URL] {
        if let exportTask {
            return try await exportTask.value
        }
        let task = Task { @MainActor [files, model] in
            try await model.exportNativeFilesForDrag(files)
        }
        exportTask = task
        return try await task.value
    }

    private func file(
        for provider: NSFilePromiseProvider
    ) -> AkaiFile? {
        guard let id = provider.userInfo as? AkaiFile.ID else { return nil }
        return files.first { $0.id == id }
    }
}

private struct FileNameCell: View {
    let file: AkaiFile

    var body: some View {
        Label(file.name, systemImage: file.isSample ? "waveform" : "doc")
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
        .help(
            file.name.uppercased().hasSuffix(".P9")
                ? "Double-click to edit this P9 program"
                : file.isSample
                    ? "Double-click to edit this sample; audio-editor launch is optional"
                    : ""
        )
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let progress = model.progress {
                ProgressView(value: progress.fraction)
                    .frame(width: 140)
                Text(progress.kind.rawValue)
                    .fontWeight(.medium)
                Text(progress.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { model.cancelOperation() }
            } else if model.session != nil {
                Label(
                    model.session?.readOnly == true ? "Read-only" : "Ready",
                    systemImage: model.session?.readOnly == true ? "lock.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(model.session?.readOnly == true ? .orange : .green)
                Text(model.snapshot.currentPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                SpaceGauge()
            } else {
                Text("Ready")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }
}

private struct SpaceGauge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            ProgressView(value: usedFraction)
                .frame(width: 90)
            Text("\(model.snapshot.usedBytes.formattedByteCount) used · \(model.snapshot.freeBytes.formattedByteCount) free")
                .monospacedDigit()
        }
    }

    private var usedFraction: Double {
        guard model.snapshot.totalBytes > 0 else { return 0 }
        return Double(model.snapshot.usedBytes) / Double(model.snapshot.totalBytes)
    }
}

private struct DiagnosticLogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Diagnostic Log", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticLog, forType: .string)
                }
                .buttonStyle(.borderless)
                Button {
                    model.isLogVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide diagnostic log")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Divider()
            ScrollView {
                Text(model.diagnosticLog.isEmpty ? "Commands and cleaned AKAI Util output will appear here." : model.diagnosticLog)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
