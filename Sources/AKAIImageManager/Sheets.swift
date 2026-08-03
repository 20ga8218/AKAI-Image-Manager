import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SampleLoopAuditionController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerAttached = false
    private var activeFile: AVAudioFile?
    private var activeStart: AVAudioFramePosition = 0
    private var activeFrameCount: AVAudioFrameCount = 0
    private var playbackGeneration = UUID()

    func toggle(url: URL, start: Int, end: Int) {
        if isPlaying {
            stop()
        } else {
            play(url: url, start: start, end: end)
        }
    }

    func updateIfPlaying(url: URL, start: Int, end: Int) {
        guard isPlaying else { return }
        play(url: url, start: start, end: end)
    }

    func play(url: URL, start: Int, end: Int) {
        do {
            guard start >= 0, start < end else {
                throw AppError.verificationFailed(
                    "Loop start must be before loop end for audition."
                )
            }
            let file = try AVAudioFile(forReading: url)
            guard AVAudioFramePosition(end) <= file.length else {
                throw AppError.verificationFailed(
                    "The audition loop extends beyond the temporary WAV."
                )
            }
            let frameCount = AVAudioFrameCount(end - start)

            player.stop()
            engine.stop()
            if playerAttached {
                engine.disconnectNodeOutput(player)
            } else {
                engine.attach(player)
                playerAttached = true
            }
            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: file.processingFormat
            )
            engine.prepare()
            try engine.start()
            activeFile = file
            activeStart = AVAudioFramePosition(start)
            activeFrameCount = frameCount
            playbackGeneration = UUID()
            errorMessage = nil
            isPlaying = true
            scheduleNextSegment(generation: playbackGeneration)
            player.play()
        } catch {
            stop()
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func stop() {
        playbackGeneration = UUID()
        player.stop()
        engine.stop()
        activeFile = nil
        isPlaying = false
    }

    private func scheduleNextSegment(generation: UUID) {
        guard generation == playbackGeneration,
              isPlaying,
              let activeFile
        else { return }
        player.scheduleSegment(
            activeFile,
            startingFrame: activeStart,
            frameCount: activeFrameCount,
            at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleNextSegment(generation: generation)
            }
        }
    }
}

struct AkaiFileInformationSheet: View {
    let information: AkaiFileInformation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AKAI File Information")
                        .font(.title2.weight(.semibold))
                    Text(information.filename)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView([.vertical, .horizontal]) {
                Text(information.details)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .padding(12)
            }
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }

            HStack {
                Text(
                    "Values are reported directly by AKAI Util from the native file."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
    }
}

struct ImportOptionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var options = ImportOptions()
    @State private var inspections: [WAVInspection] = []
    @State private var inspectionError: String?
    @State private var sampleNames: [String: String] = [:]
    @FocusState private var focusedSamplePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Import WAV Samples")
                        .font(.title2.weight(.semibold))
                    Text("\(model.pendingImportURLs.count) file\(model.pendingImportURLs.count == 1 ? "" : "s") into \(model.snapshot.currentPath)")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                LabeledContent("Target sampler", value: "S950")
                Toggle("Create compressed S950 samples", isOn: $options.compressedS900)
                Toggle("Convert to mono", isOn: $options.convertToMono)
                Toggle("Preserve compatible sample rates", isOn: $options.preserveSampleRate)
                Picker("If a name exists", selection: $options.collisionPolicy) {
                    ForEach(CollisionPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
            }
            .formStyle(.grouped)

            GroupBox("Filename and repair preview") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.pendingImportURLs, id: \.path) { url in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.tertiary)
                                    HStack(spacing: 3) {
                                        TextField(
                                            "S950 name",
                                            text: sampleNameBinding(for: url)
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced).weight(.medium))
                                        .frame(width: 145)
                                        .focused(
                                            $focusedSamplePath,
                                            equals: url.standardizedFileURL.path
                                        )
                                        .onSubmit { normalizeName(for: url) }
                                        Text(".S9")
                                            .font(.system(.body, design: .monospaced).weight(.medium))
                                    }
                                    Spacer()
                                    if let inspection = inspections.first(where: { $0.url == url }) {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(inspection.needsRepair ? "Repair needed" : "Compatible")
                                                .foregroundStyle(inspection.needsRepair ? .orange : .green)
                                            if inspection.cueSampleOffsets.count == 2 {
                                                Text("2 loop markers")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                if let error = filenameValidationError(for: url) {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 120)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated input: \(estimatedSize.formattedByteCount)")
                    Text("Available in image: \(model.snapshot.freeBytes.formattedByteCount)")
                        .foregroundStyle(estimatedSize > model.snapshot.freeBytes && model.snapshot.freeBytes > 0 ? .red : .secondary)
                }
                .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    model.performImport(
                        options: options,
                        requestedNames: normalizedRequestedNames
                    )
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.pendingImportURLs.isEmpty
                            || hasInvalidSampleNames
                            || (estimatedSize > model.snapshot.freeBytes
                                && model.snapshot.freeBytes > 0)
                    )
            }
        }
        .padding(22)
        .frame(width: 700, height: 590)
        .onAppear {
            options = settings.defaultImportOptions
            initializeSampleNames()
            inspect()
        }
        .onChange(of: options) { inspect() }
        .onChange(of: focusedSamplePath) { oldValue, _ in
            guard let oldValue,
                  let url = model.pendingImportURLs.first(where: {
                      $0.standardizedFileURL.path == oldValue
                  })
            else { return }
            normalizeName(for: url)
        }
    }

    private var estimatedSize: Int64 {
        model.pendingImportURLs.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func inspect() {
        inspections = model.pendingImportURLs.compactMap { try? WAVService.inspect($0, options: options) }
        inspectionError = nil
    }

    private func initializeSampleNames() {
        for url in model.pendingImportURLs {
            let path = url.standardizedFileURL.path
            if sampleNames[path] == nil {
                sampleNames[path] = AkaiFilename.sanitizedBase(
                    url.lastPathComponent,
                    family: .s900
                )
            }
        }
    }

    private func sampleNameBinding(for url: URL) -> Binding<String> {
        let path = url.standardizedFileURL.path
        return Binding(
            get: {
                sampleNames[path] ?? AkaiFilename.sanitizedBase(
                    url.lastPathComponent,
                    family: .s900
                )
            },
            set: { sampleNames[path] = $0 }
        )
    }

    private func normalizeName(for url: URL) {
        let path = url.standardizedFileURL.path
        sampleNames[path] = AkaiFilename.normalizedS950Base(
            sampleNames[path] ?? ""
        )
    }

    private var normalizedRequestedNames: [String: String] {
        Dictionary(uniqueKeysWithValues: model.pendingImportURLs.map { url in
            let path = url.standardizedFileURL.path
            return (
                path,
                AkaiFilename.normalizedS950Base(
                    sampleNames[path]
                        ?? AkaiFilename.sanitizedBase(
                            url.lastPathComponent,
                            family: .s900
                        )
                )
            )
        })
    }

    private var duplicateSampleNames: Set<String> {
        let names = normalizedRequestedNames.values
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private func filenameValidationError(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let name = sampleNames[path]
            ?? AkaiFilename.sanitizedBase(url.lastPathComponent, family: .s900)
        if let error = AkaiFilename.s950BaseValidationError(name) {
            return error
        }
        if duplicateSampleNames.contains(
            AkaiFilename.normalizedS950Base(name)
        ) {
            return "Enter a unique name for each imported sample."
        }
        return nil
    }

    private var hasInvalidSampleNames: Bool {
        model.pendingImportURLs.contains {
            filenameValidationError(for: $0) != nil
        }
    }
}

struct ExternalSampleEditSheet: View {
    @ObservedObject var editSession: ExternalSampleEditSession
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var compressed = false
    @State private var createBackup = true
    @State private var editAttributes: S9SampleEditSettings
    @State private var markerSummary: String?
    @State private var loopStart: Int
    @State private var loopEnd: Int
    @State private var loopPointsManuallyEdited = false
    @State private var zeroCrossingMap: WAVZeroCrossingMap?
    @State private var zeroCrossingError: String?
    @StateObject private var audition = SampleLoopAuditionController()

    init(editSession: ExternalSampleEditSession) {
        self.editSession = editSession
        _editAttributes = State(
            initialValue: S9SampleEditSettings(
                attributes: editSession.originalAttributes
            )
        )
        let attributes = editSession.originalAttributes
        _loopStart = State(initialValue: Int(attributes.loopStart ?? 0))
        _loopEnd = State(
            initialValue: Int(
                attributes.loopStart == nil
                    ? attributes.sampleLength
                    : attributes.playbackEnd
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.pencil")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit \(editSession.sourceFile.name)")
                        .font(.title2.weight(.semibold))
                    Text("Edit native attributes, or open the WAV in your audio editor")
                    .foregroundStyle(.secondary)
                }
            }

            GroupBox("Round-trip WAV") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Temporary file") {
                        Text(editSession.wavURL.lastPathComponent)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent(
                        "Exported format",
                        value:
                            "\(Int(editSession.originalInspection.sampleRate)) Hz · "
                            + "\(editSession.originalInspection.bitDepth)-bit · "
                            + "\(editSession.originalInspection.channelCount) channel"
                            + "\(editSession.originalInspection.channelCount == 1 ? "" : "s")"
                    )
                    Text(
                        editSession.editorURL == nil
                            ? "Native attributes can be changed without an audio editor. Configure one in Settings only if audio editing is required."
                            : "Open the WAV below only when audio editing is required. Save over it; do not use Save As or change its location."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(
                            "Open WAV in "
                                + (editSession.editorURL?
                                    .deletingPathExtension().lastPathComponent
                                    ?? "Audio Editor")
                        ) {
                            openWAVInEditor()
                        }
                        .disabled(
                            editSession.editorURL == nil
                                || loopValidationError != nil
                        )
                        Button("Show WAV in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [editSession.wavURL]
                            )
                        }
                    }
                }
                .padding(7)
            }

            GroupBox("Return to the S950 IMG") {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Root pitch", selection: $editAttributes.rootNote) {
                        ForEach(0..<128, id: \.self) { note in
                            Text("\(P9Keygroup.noteName(note)) · MIDI \(note)")
                                .tag(note)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(
                        "Playback direction",
                        selection: $editAttributes.playbackDirection
                    ) {
                        ForEach(S9PlaybackDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(
                        "Playback mode",
                        selection: $editAttributes.playbackMode
                    ) {
                        ForEach(S9PlaybackMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 18) {
                        LabeledContent(
                            "Sample length",
                            value: "\(editSession.originalAttributes.sampleLength.formatted()) samples"
                        )
                        Divider()
                        LabeledContent(
                            "Loop length",
                            value: "\(loopLength.formatted()) samples"
                        )
                    }

                    HStack {
                        Text("Loop start")
                        Spacer()
                        zeroCrossingControls(
                            position: loopStart,
                            previous: previousLoopStartCrossing,
                            next: nextLoopStartCrossing,
                            move: { loopStartBinding.wrappedValue = $0.frame }
                        )
                        TextField(
                            "Loop start",
                            value: loopStartBinding,
                            format: .number
                        )
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130)
                        Stepper(
                            "Loop start",
                            value: loopStartBinding,
                            in: 0...Int(editSession.originalAttributes.sampleLength)
                        )
                        .labelsHidden()
                    }

                    HStack {
                        Text("Loop end")
                        Spacer()
                        zeroCrossingControls(
                            position: loopEnd,
                            previous: previousLoopEndCrossing,
                            next: nextLoopEndCrossing,
                            move: { loopEndBinding.wrappedValue = $0.frame }
                        )
                        TextField(
                            "Loop end",
                            value: loopEndBinding,
                            format: .number
                        )
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130)
                        Stepper(
                            "Loop end",
                            value: loopEndBinding,
                            in: 0...Int(editSession.originalAttributes.sampleLength)
                        )
                        .labelsHidden()
                    }

                    if let loopValidationError {
                        Label(
                            loopValidationError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label(
                            "After saving marker changes in the external editor, return here and click Refresh Loop Points from Saved WAV to update the values shown above. Replacement reads saved markers automatically; refreshing lets you verify them first.",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        HStack {
                            Button("Refresh Loop Points from Saved WAV") {
                                checkSavedMarkers()
                            }
                            Button {
                                audition.toggle(
                                    url: editSession.wavURL,
                                    start: loopStart,
                                    end: loopEnd
                                )
                            } label: {
                                Label(
                                    audition.isPlaying
                                        ? "Stop Audition"
                                        : "Audition Loop",
                                    systemImage: audition.isPlaying
                                        ? "stop.fill" : "play.fill"
                                )
                            }
                            .disabled(
                                editSession.isReplacing
                                    || loopValidationError != nil
                            )
                            if let markerSummary {
                                Text(markerSummary)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(
                            "Audition Loop repeats the current start-to-end region and restarts immediately when either value changes."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()
                    Toggle("Create compressed S950 sample", isOn: $compressed)
                    Toggle(
                        "Create and verify a complete IMG backup first",
                        isOn: $createBackup
                    )
                    Text(
                        "The replacement keeps the original sample name, so P9 references remain valid. "
                            + "The stored S9 is re-exported and compared byte-for-byte. "
                            + (createBackup
                                ? "If replacement or verification fails, the IMG backup is restored automatically."
                                : "Without a backup, automatic rollback is unavailable.")
                    )
                    .font(.caption)
                    .foregroundStyle(
                        createBackup ? Color.secondary : Color.orange
                    )
                }
                .padding(7)
            }

            if editSession.isReplacing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.progress?.detail ?? "Preparing replacement…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage = editSession.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let auditionError = audition.errorMessage {
                Label(
                    auditionError,
                    systemImage: "speaker.slash.fill"
                )
                .foregroundStyle(.red)
                .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let zeroCrossingError {
                Label(
                    zeroCrossingError,
                    systemImage: "waveform.path.ecg.rectangle"
                )
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Text("The source IMG remains unchanged until the final replacement step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    audition.stop()
                    model.cancelExternalSampleEdit(editSession)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(editSession.isReplacing)
                Button(
                    createBackup
                        ? "Back Up and Replace Sample"
                        : "Replace Without Backup"
                ) {
                    audition.stop()
                    model.replaceEditedS9Sample(
                        editSession,
                        compressed: compressed,
                        createBackup: createBackup,
                        attributes: editAttributes,
                        loopPoints: loopPointsManuallyEdited
                            ? currentLoopPoints : nil
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    editSession.isReplacing || loopValidationError != nil
                )
            }
        }
        .padding(22)
        .frame(width: 720, height: 760)
        .interactiveDismissDisabled(editSession.isReplacing)
        .onAppear {
            compressed = settings.compressedS900
            loadZeroCrossings()
        }
        .onChange(of: editAttributes.playbackMode) { oldValue, newValue in
            if oldValue != newValue, newValue.requiresLoopMarkers {
                loopPointsManuallyEdited = true
            }
        }
        .onDisappear { audition.stop() }
    }

    private func checkSavedMarkers() {
        do {
            let markers = try WAVService.cueSampleOffsets(in: editSession.wavURL)
                .sorted()
            if markers.count == 2, markers[0] < markers[1] {
                loadZeroCrossings()
                loopStart = Int(markers[0])
                loopEnd = Int(markers[1])
                loopPointsManuallyEdited = false
                markerSummary = "Start \(markers[0]) · End \(markers[1])"
                audition.updateIfPlaying(
                    url: editSession.wavURL,
                    start: loopStart,
                    end: loopEnd
                )
            } else {
                markerSummary = "Found \(markers.count); exactly 2 are required"
            }
        } catch {
            markerSummary = error.localizedDescription
        }
    }

    private var loopStartBinding: Binding<Int> {
        Binding(
            get: { loopStart },
            set: {
                loopStart = $0
                loopPointsManuallyEdited = true
                markerSummary = "Values changed here"
                refreshAuditionIfPossible()
            }
        )
    }

    private var loopEndBinding: Binding<Int> {
        Binding(
            get: { loopEnd },
            set: {
                loopEnd = $0
                loopPointsManuallyEdited = true
                markerSummary = "Values changed here"
                refreshAuditionIfPossible()
            }
        )
    }

    private var loopValidationError: String? {
        let length = Int(editSession.originalAttributes.sampleLength)
        guard loopStart >= 0, loopEnd >= 0 else {
            return "Loop positions cannot be negative."
        }
        guard loopStart < loopEnd else {
            return "Loop start must be before loop end."
        }
        guard loopEnd <= length else {
            return "Loop end must not exceed the sample length."
        }
        return nil
    }

    private var loopLength: Int {
        max(0, loopEnd - loopStart)
    }

    private var previousLoopStartCrossing: WAVZeroCrossing? {
        zeroCrossingMap?.previous(before: loopStart)
    }

    private var nextLoopStartCrossing: WAVZeroCrossing? {
        guard let crossing = zeroCrossingMap?.next(after: loopStart),
              crossing.frame < loopEnd
        else { return nil }
        return crossing
    }

    private var previousLoopEndCrossing: WAVZeroCrossing? {
        guard let crossing = zeroCrossingMap?.previous(before: loopEnd),
              crossing.frame > loopStart
        else { return nil }
        return crossing
    }

    private var nextLoopEndCrossing: WAVZeroCrossing? {
        zeroCrossingMap?.next(after: loopEnd)
    }

    @ViewBuilder
    private func zeroCrossingControls(
        position: Int,
        previous: WAVZeroCrossing?,
        next: WAVZeroCrossing?,
        move: @escaping (WAVZeroCrossing) -> Void
    ) -> some View {
        Button {
            if let previous { move(previous) }
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(previous == nil)
        .help("Move to the previous zero crossing")

        Image(systemName: zeroCrossingIcon(at: position))
            .frame(width: 18)
            .foregroundStyle(
                zeroCrossingMap?.direction(at: position) == nil
                    ? Color.secondary : Color.accentColor
            )
            .help(zeroCrossingDescription(at: position))

        Button {
            if let next { move(next) }
        } label: {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(next == nil)
        .help("Move to the next zero crossing")
    }

    private func zeroCrossingIcon(at position: Int) -> String {
        switch zeroCrossingMap?.direction(at: position) {
        case .upward: return "arrow.up.right"
        case .downward: return "arrow.down.right"
        case nil: return "minus"
        }
    }

    private func zeroCrossingDescription(at position: Int) -> String {
        switch zeroCrossingMap?.direction(at: position) {
        case .upward: return "Upward zero crossing"
        case .downward: return "Downward zero crossing"
        case nil: return "The current position is not a zero crossing"
        }
    }

    private func loadZeroCrossings() {
        do {
            zeroCrossingMap = try WAVService.zeroCrossings(
                in: editSession.wavURL
            )
            zeroCrossingError = nil
        } catch {
            zeroCrossingMap = nil
            zeroCrossingError =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private var currentLoopPoints: S9LoopPoints? {
        guard loopValidationError == nil,
              let start = UInt32(exactly: loopStart),
              let end = UInt32(exactly: loopEnd)
        else { return nil }
        return S9LoopPoints(start: start, end: end)
    }

    private func openWAVInEditor() {
        audition.stop()
        let points = loopPointsManuallyEdited ? currentLoopPoints : nil
        if model.reopenExternalAudioEditor(
            editSession,
            loopPoints: points
        ), points != nil {
            loopPointsManuallyEdited = false
            markerSummary = "Loop markers saved to WAV"
        }
    }

    private func refreshAuditionIfPossible() {
        guard loopValidationError == nil else {
            audition.stop()
            return
        }
        audition.updateIfPlaying(
            url: editSession.wavURL,
            start: loopStart,
            end: loopEnd
        )
    }
}

struct FormatImageSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case new = "New Image"
        case existing = "Format Open Image"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .new
    @State private var preset: FormatPreset = .s900Low
    @State private var destination: URL?
    @State private var backup = true
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: mode == .new ? "plus.rectangle.on.rectangle" : "externaldrive.badge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(mode == .existing ? Color.orange : Color.accentColor)
                VStack(alignment: .leading) {
                    Text("New or Format Image")
                        .font(.title2.weight(.semibold))
                    Text(mode == .new ? "Create an exact-size raw image and format it for an S950." : "Formatting permanently erases the open image.")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Operation", selection: $mode) {
                ForEach(Mode.allCases) { value in
                    Text(value.rawValue).tag(value)
                        .disabled(value == .existing && model.session == nil)
                }
            }
            .pickerStyle(.segmented)

            Form {
                Picker("Format preset", selection: $preset) {
                    Section("Floppy images") {
                        ForEach(FormatPreset.allCases.filter(\.isFloppy)) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    Section("Hard-disk images") {
                        ForEach(FormatPreset.allCases.filter { !$0.isFloppy }) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                }
                LabeledContent("Exact size", value: Int64(preset.byteCount).formattedByteCount)
                LabeledContent("AKAI command", value: preset.command)
            }
            .formStyle(.grouped)

            if mode == .new {
                GroupBox("Destination") {
                    HStack {
                        Text(destination?.path ?? "Choose where to save the new IMG file")
                            .foregroundStyle(destination == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseDestination() }
                    }
                    .padding(7)
                }
            } else if let session = model.session {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Every file in \(session.imageURL.lastPathComponent) will be permanently erased.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Toggle("Create timestamped backup first", isOn: $backup)
                        TextField("Type \(session.imageURL.lastPathComponent) to confirm", text: $confirmation)
                    }
                    .padding(6)
                }
            }

            Spacer()
            HStack {
                Text("Only image files are formatted. Physical drives are never targeted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .new ? "Create and Format" : "Erase and Format", role: mode == .existing ? .destructive : nil) {
                    perform()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(mode == .existing ? .red : .accentColor)
                .disabled(!canPerform)
            }
        }
        .padding(22)
        .frame(width: 660, height: 550)
        .onAppear {
            backup = settings.backupBeforeDestructive
            if model.session == nil { mode = .new }
        }
    }

    private var canPerform: Bool {
        switch mode {
        case .new: return destination != nil
        case .existing:
            return model.session != nil && confirmation == model.session?.imageURL.lastPathComponent
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Save New AKAI Image"
        panel.nameFieldStringValue = "AKAI Disk.img"
        panel.allowedContentTypes = [UTType(filenameExtension: "img") ?? .data]
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func perform() {
        switch mode {
        case .new:
            if let destination { model.createAndFormat(at: destination, preset: preset) }
        case .existing:
            model.formatCurrent(preset: preset, backup: backup)
        }
    }
}

struct DiskInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Disk Information", systemImage: "info.circle.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Copy") { model.copyDiskInfo() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(model.diskInformationText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Raw AKAI Util responses are included so unusual media can still be diagnosed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }
}

struct DeleteAllSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Delete Every File in This Volume", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("This permanently deletes exactly \(model.snapshot.files.count) files from \(model.snapshot.currentPath). It does not use AKAI Util’s wipe-volume command.")
            ScrollView {
                Text(model.snapshot.files.map { "\($0.index). \($0.name)" }.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 170)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Toggle("Create a timestamped backup first", isOn: $settings.backupBeforeDestructive)
            TextField("Type DELETE ALL to confirm", text: $confirmation)
            Text("Deletion inside an IMG is not recoverable without a backup.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete All Files", role: .destructive) {
                    dismiss()
                    model.deleteAllFiles()
                }
                .disabled(confirmation != "DELETE ALL")
            }
        }
        .padding(22)
        .frame(width: 590, height: 510)
    }
}
