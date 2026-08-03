import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct InteractionRegressionRunner {
    static func main() async {
        let executablePath = CommandLine.arguments.dropFirst().first
            ?? AppSettings.executableDefault
        let retainedImagePath = CommandLine.arguments.dropFirst(2).first
        let markerFixturePath = ProcessInfo.processInfo.environment[
            "AKAI_MARKER_WAV_FIXTURE"
        ]
        let nativeLoopFixturePath = ProcessInfo.processInfo.environment[
            "AKAI_NATIVE_LOOP_S9_FIXTURE"
        ]
        let executable = URL(fileURLWithPath: executablePath)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("akai-interaction-\(UUID().uuidString)", isDirectory: true)
        let image = workspace.appendingPathComponent("interaction.img")
        let hardDiskImage = workspace.appendingPathComponent("s950-hard-disk.img")
        let wav = workspace.appendingPathComponent("SELECTION.wav")
        let markerWAV = workspace.appendingPathComponent("MARKERS.wav")
        let nativeDirectory = workspace.appendingPathComponent("native", isDirectory: true)
        let markerDirectory = workspace.appendingPathComponent("markers-native", isDirectory: true)
        let copiedDirectory = workspace.appendingPathComponent("copied", isDirectory: true)
        let audioEditor = workspace.appendingPathComponent(
            "Test Audio Editor.app",
            isDirectory: true
        )
        let seedingController = AkaiCommandController()
        let editorLaunchLog = workspace.appendingPathComponent("editor-launched")

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: copiedDirectory, withIntermediateDirectories: true)
            try createTestApplication(at: audioEditor, launchLog: editorLaunchLog)
            defer { try? FileManager.default.removeItem(at: workspace) }
            try ImageFileOperations.createZeroFilledImage(
                at: image,
                byteCount: FormatPreset.s900Low.byteCount
            )
            try writeTestWAV(to: wav)
            if let markerFixturePath {
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: markerFixturePath),
                    to: markerWAV
                )
            } else {
                try FileManager.default.copyItem(at: wav, to: markerWAV)
                try appendCueMarkers([500, 1_500], to: markerWAV)
            }

            _ = try await seedingController.open(
                imageURL: image,
                executableURL: executable,
                readOnly: false
            )
            _ = try await seedingController.send(FormatPreset.s900Low.command)
            _ = try await seedingController.send(
                try AkaiCommandBuilder.localDirectory(workspace.path)
            )
            _ = try await seedingController.send("wav2sample9 SELECTION.wav")
            let sampleListing = try await seedingController.send("dir")
            guard let sample = AkaiOutputParser.parseDirectory(sampleListing.output).0.first else {
                throw RegressionFailure("Could not seed an S9 sample.")
            }
            _ = try await seedingController.send(
                try AkaiCommandBuilder.localDirectory(nativeDirectory.path)
            )
            _ = try await seedingController.send(
                try AkaiCommandBuilder.exportNative(index: sample.index)
            )
            guard let nativeSample = try FileManager.default.contentsOfDirectory(
                at: nativeDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first(where: { $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame }) else {
                throw RegressionFailure("Could not create the native S9 seed.")
            }
            let programSeed = nativeDirectory.appendingPathComponent("DELETEP9.P9")
            try FileManager.default.copyItem(at: nativeSample, to: programSeed)
            _ = try await seedingController.send(
                try AkaiCommandBuilder.importNative(filename: programSeed.lastPathComponent)
            )
            if let nativeLoopFixturePath {
                let source = URL(fileURLWithPath: nativeLoopFixturePath)
                let destination = nativeDirectory.appendingPathComponent(
                    source.lastPathComponent
                )
                try FileManager.default.copyItem(at: source, to: destination)
                _ = try await seedingController.send(
                    try AkaiCommandBuilder.importNative(
                        filename: destination.lastPathComponent
                    )
                )
            }
            await seedingController.close()

            guard let defaults = UserDefaults(
                suiteName: "AKAIImageManager.InteractionRegression.\(UUID().uuidString)"
            ) else {
                throw RegressionFailure("Could not create isolated test settings.")
            }
            let settings = AppSettings(defaults: defaults)
            settings.executablePath = executable.path
            settings.backupBeforeDestructive = false
            settings.audioEditorPath = audioEditor.path
            let model = AppModel(settings: settings)

            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.finishLaunching()
            NSApplication.shared.activate(ignoringOtherApps: true)
            let root = MainView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(width: 1180, height: 760)
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(hostingView)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKey()

            try await model.openImage(image, readOnly: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            hostingView.layoutSubtreeIfNeeded()

            let markerOptions = ImportOptions(
                family: .s900,
                compressedS900: false,
                convertToMono: true,
                preserveSampleRate: true,
                collisionPolicy: .rename
            )
            let markerSourceInspection = try WAVService.inspect(
                markerWAV,
                options: markerOptions
            )
            let sourceMarkers = markerSourceInspection.cueSampleOffsets.sorted()
            guard sourceMarkers.count == 2, sourceMarkers[0] < sourceMarkers[1]
            else {
                throw RegressionFailure(
                    "The marker-WAV fixture does not contain exactly two valid cue markers."
                )
            }
            let crossingMap = try WAVService.zeroCrossings(in: markerWAV)
            guard !crossingMap.crossings.isEmpty,
                  let previousCrossing = crossingMap.previous(
                    before: Int(sourceMarkers[0])
                  ),
                  let nextCrossing = crossingMap.next(
                    after: Int(sourceMarkers[0])
                  ),
                  crossingMap.direction(at: previousCrossing.frame) != nil,
                  crossingMap.direction(at: nextCrossing.frame) != nil
            else {
                throw RegressionFailure(
                    "The supplied WAV did not expose navigable directed zero crossings."
                )
            }
            print("✓ Located previous/next WAV zero crossings with directions")
            let audition = SampleLoopAuditionController()
            audition.play(
                url: markerWAV,
                start: Int(sourceMarkers[0]),
                end: Int(sourceMarkers[1])
            )
            try await Task.sleep(nanoseconds: 100_000_000)
            guard audition.isPlaying, audition.errorMessage == nil else {
                throw RegressionFailure(
                    "The temporary WAV loop could not be auditioned: \(audition.errorMessage ?? "unknown error")"
                )
            }
            audition.updateIfPlaying(
                url: markerWAV,
                start: Int(sourceMarkers[0] + 1),
                end: Int(sourceMarkers[1])
            )
            guard audition.isPlaying, audition.errorMessage == nil else {
                throw RegressionFailure(
                    "The loop audition did not update after a loop-point change."
                )
            }
            audition.stop()
            guard !audition.isPlaying else {
                throw RegressionFailure("The loop audition did not stop.")
            }
            print("✓ Auditioned the temporary WAV loop and updated it live")
            try await model.importWAVs(
                [markerWAV],
                options: markerOptions,
                requestedNames: [
                    markerWAV.standardizedFileURL.path: "loopname"
                ]
            )
            guard let markerSample = model.snapshot.files.first(where: {
                $0.isSample
                    && ($0.name as NSString).deletingPathExtension
                        .caseInsensitiveCompare("LOOPNAME") == .orderedSame
            }) else {
                throw RegressionFailure(
                    "The two-marker WAV did not import into the disposable IMG."
                )
            }
            try await model.exportNativeFiles(
                [markerSample],
                to: markerDirectory,
                policy: .replace,
                revealInFinder: false
            )
            guard let markerNativeURL = try FileManager.default
                .contentsOfDirectory(
                    at: markerDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .first(where: {
                    $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame
                })
            else {
                throw RegressionFailure(
                    "The marker-derived S9 could not be exported for verification."
                )
            }
            let markerAttributes = try S9NativeSample.attributes(
                in: Data(contentsOf: markerNativeURL)
            )
            let expectedMarkerStart = UInt32(
                (Double(sourceMarkers[0]) * Double(markerAttributes.sampleLength)
                    / Double(markerSourceInspection.frameCount)).rounded()
            )
            let expectedMarkerEnd = UInt32(
                (Double(sourceMarkers[1]) * Double(markerAttributes.sampleLength)
                    / Double(markerSourceInspection.frameCount)).rounded()
            )
            guard markerAttributes.playbackMode == .oneShot,
                  markerAttributes.loopStart == expectedMarkerStart,
                  markerAttributes.playbackEnd == expectedMarkerEnd
            else {
                throw RegressionFailure(
                    "Ordinary WAV import did not retain both markers in a one-shot S9."
                )
            }
            print("✓ Ordinary WAV import writes two marker positions while retaining one-shot mode")

            if let nativeLoopFixturePath {
                let nativeData = try Data(
                    contentsOf: URL(fileURLWithPath: nativeLoopFixturePath)
                )
                let nativeName = try S9NativeSample.internalName(in: nativeData)
                let nativeAttributes = try S9NativeSample.attributes(in: nativeData)
                guard nativeAttributes.playbackMode.requiresLoopMarkers,
                      let nativeLoopStart = nativeAttributes.loopStart,
                      let nativeLoopSample = model.snapshot.files.first(where: {
                          $0.isSample
                              && ($0.name as NSString).deletingPathExtension
                                  .caseInsensitiveCompare(nativeName)
                                  == .orderedSame
                      })
                else {
                    throw RegressionFailure(
                        "The native-loop S9 fixture was not imported as a looping sample."
                    )
                }
                model.openEditor(for: nativeLoopSample)
                for _ in 0..<50 where model.externalSampleEditSession == nil {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let nativeEditSession = model.externalSampleEditSession
                else {
                    throw RegressionFailure(
                        "The native-loop S9 did not open in the sample editor."
                    )
                }
                let frameCount = nativeEditSession.originalInspection.frameCount
                func wavPosition(_ nativePosition: UInt32) -> UInt32 {
                    UInt32(
                        (Double(nativePosition) * Double(frameCount)
                            / Double(nativeAttributes.sampleLength)).rounded()
                    )
                }
                let expectedNativeCues = [
                    wavPosition(nativeLoopStart),
                    wavPosition(nativeAttributes.playbackEnd)
                ]
                let nativeCueData = try Data(
                    contentsOf: nativeEditSession.wavURL
                )
                let nativeMarkerText = String(
                    decoding: nativeCueData,
                    as: UTF8.self
                )
                guard nativeEditSession.originalInspection.cueSampleOffsets
                        == expectedNativeCues,
                      nativeMarkerText.contains("Loop Start"),
                      nativeMarkerText.contains("Loop End")
                else {
                    throw RegressionFailure(
                        "Native S9 loop points were not exposed as labelled WAV markers."
                    )
                }
                model.cancelExternalSampleEdit(nativeEditSession)
                for _ in 0..<40 where window.attachedSheet != nil {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                print("✓ Native looping S9 opens with labelled WAV loop markers")
            }

            guard let program = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("DELETEP9.P9") == .orderedSame
            }) else {
                throw RegressionFailure("The disposable image did not contain the P9 test entry.")
            }
            guard let table = findFileTable(
                in: hostingView,
                expectedRowCount: model.snapshot.files.count
            ),
                  let row = model.snapshot.files.firstIndex(where: { $0.id == program.id })
            else {
                throw RegressionFailure("Could not locate the rendered file table.")
            }

            model.selection.removeAll()
            NativeFileTableSelection.select(
                program,
                modifiers: [],
                model: model,
                window: window
            )
            try await Task.sleep(nanoseconds: 150_000_000)
            guard model.selection.contains(program.id) else {
                throw RegressionFailure(
                    "A mouse click in the Name cell did not update the SwiftUI P9 selection "
                    + "(native selected row: \(table.selectedRow))."
                )
            }
            guard table.selectedRow == row,
                  window.firstResponder === table
            else {
                throw RegressionFailure(
                    "A Name-cell selection did not select and focus its native table row."
                )
            }
            guard model.canExport else {
                throw RegressionFailure(
                    "Export Selected remained disabled for a selected P9."
                )
            }
            if let sampleRow = model.snapshot.files.firstIndex(where: {
                $0.id != program.id
            }) {
                let secondFile = model.snapshot.files[sampleRow]
                NativeFileTableSelection.select(
                    secondFile,
                    modifiers: [.command],
                    model: model,
                    window: window
                )
                try await Task.sleep(nanoseconds: 150_000_000)
                guard model.selection.count == 2,
                      model.selection.contains(program.id),
                      table.selectedRowIndexes == IndexSet([row, sampleRow])
                else {
                    throw RegressionFailure(
                        "Command-click selection did not synchronize both table rows."
                    )
                }
                NativeFileTableSelection.select(
                    program,
                    modifiers: [],
                    model: model,
                    window: window
                )
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            print("✓ Full-cell single and command-click selection synchronize and focus the P9 table")

            model.fileSortOrder = [
                KeyPathComparator(\AkaiFile.name, order: .reverse)
            ]
            try await Task.sleep(nanoseconds: 200_000_000)
            hostingView.layoutSubtreeIfNeeded()
            let descendingNames = model.snapshot.files.map(\.name).sorted(by: >)
            guard model.displayedFiles.map(\.name) == descendingNames,
                  let sortedProgramRow = model.displayedFiles.firstIndex(
                    where: { $0.id == program.id }
                  )
            else {
                throw RegressionFailure("Name sorting did not reorder the rendered files.")
            }
            NativeFileTableSelection.select(
                program,
                modifiers: [],
                model: model,
                window: window
            )
            guard table.selectedRow == sortedProgramRow,
                  model.selection == [program.id]
            else {
                throw RegressionFailure(
                    "Sorted-row selection did not retain the P9 stable identity."
                )
            }
            model.fileSortOrder = [KeyPathComparator(\AkaiFile.type)]
            guard model.displayedFiles.map(\.type)
                    == model.snapshot.files.map(\.type).sorted()
            else {
                throw RegressionFailure("Type sorting did not order the rendered files.")
            }
            model.fileSortOrder = [KeyPathComparator(\AkaiFile.byteSize)]
            guard model.displayedFiles.map(\.byteSize)
                    == model.snapshot.files.map(\.byteSize).sorted()
            else {
                throw RegressionFailure("Size sorting did not order the rendered files.")
            }
            model.fileSortOrder = []
            try await Task.sleep(nanoseconds: 150_000_000)
            hostingView.layoutSubtreeIfNeeded()
            print("✓ Name, Type and Size sorting preserve stable row selection")

            let dragProvider = model.nativeDragProvider(for: program)
            let p9Type = UTType(filenameExtension: "p9") ?? .data
            let draggedName = try await loadedFilename(
                from: dragProvider,
                typeIdentifier: p9Type.identifier
            )
            guard dragProvider.suggestedName == "DELETEP9",
                  (draggedName as NSString).deletingPathExtension == "DELETEP9",
                  (draggedName as NSString).pathExtension
                    .caseInsensitiveCompare("p9") == .orderedSame
            else {
                throw RegressionFailure(
                    "The P9 drag provider suggested \(dragProvider.suggestedName ?? "nil") "
                        + "and produced \(draggedName)."
                )
            }
            print("✓ P9 drag provider exports one exact extension")

            guard let dragSample = model.snapshot.files.first(where: \.isSample)
            else {
                throw RegressionFailure(
                    "The disposable image did not contain an S9 for multi-file drag testing."
                )
            }
            model.selection = [program.id, dragSample.id]
            let dragFiles = model.nativeFilesForDrag(startingWith: program)
            guard Set(dragFiles.map(\.id)) == Set([program.id, dragSample.id])
            else {
                throw RegressionFailure(
                    "Starting a drag on a selected P9 did not preserve both selected native files."
                )
            }
            let batchExports = try await model.exportNativeFilesForDrag(dragFiles)
            guard batchExports.count == 2,
                  batchExports[program.id]?.lastPathComponent == program.name,
                  batchExports[dragSample.id]?.lastPathComponent == dragSample.name
            else {
                throw RegressionFailure(
                    "The multi-file drag export did not preserve both exact S9/P9 names."
                )
            }
            print("✓ Multi-file drag preparation exports every selected S9/P9 with exact names")

            let editedSample = markerSample
            model.openEditor(for: editedSample)
            for _ in 0..<50 where model.externalSampleEditSession == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let editSession = model.externalSampleEditSession,
                  editSession.sourceFile.id == editedSample.id,
                  editSession.editorURL?.standardizedFileURL
                    == audioEditor.standardizedFileURL,
                  editSession.originalInspection.cueSampleOffsets
                    == [expectedMarkerStart, expectedMarkerEnd]
            else {
                throw RegressionFailure(
                    "Double-click routing did not open the selected sample editor."
                )
            }
            guard !FileManager.default.fileExists(atPath: editorLaunchLog.path)
            else {
                throw RegressionFailure(
                    "Opening the S9 edit dialogue also launched the external audio editor."
                )
            }
            for _ in 0..<40 where window.attachedSheet == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let sampleSheet = window.attachedSheet,
                  let sampleSheetContent = sampleSheet.contentView
            else {
                throw RegressionFailure(
                    "The S9 external-editor sheet was not rendered."
                )
            }
            sampleSheetContent.layoutSubtreeIfNeeded()
            let sampleSheetText = renderedText(in: sampleSheetContent)
                .joined(separator: "\n")
            guard sampleSheetText.contains("MIDI 60"),
                  sampleSheetText.contains("Forward"),
                  sampleSheetText.contains("One-shot"),
                  sampleSheetText.contains(expectedMarkerStart.formatted()),
                  sampleSheetText.contains(expectedMarkerEnd.formatted())
            else {
                throw RegressionFailure(
                    "The S9 editor did not render its root, direction and loop values."
                )
            }
            let labelledMarkerData = try Data(contentsOf: editSession.wavURL)
            let labelledMarkerText = String(
                decoding: labelledMarkerData,
                as: UTF8.self
            )
            guard labelledMarkerText.contains("LIST"),
                  labelledMarkerText.contains("adtl"),
                  labelledMarkerText.contains("Loop Start"),
                  labelledMarkerText.contains("Loop End")
            else {
                throw RegressionFailure(
                    "The S9 edit WAV did not expose labelled loop markers to the audio editor."
                )
            }
            model.cancelExternalSampleEdit(editSession)
            print("✓ S9 dialogue restores imported loop points as WAV markers without auto-launching audio")

            model.selection = [editedSample.id]
            model.showSelectedFileInformation()
            for _ in 0..<100 where model.operationActive {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let nativeInformation =
                model.fileInformation?.details.lowercased() ?? ""
            guard nativeInformation.contains("srate:"),
                  nativeInformation.contains("npitch:"),
                  nativeInformation.contains("pmode:"),
                  nativeInformation.contains("llen:")
            else {
                throw RegressionFailure(
                    "Native S9 information did not include sample rate, nominal pitch, playback mode and loop length."
                )
            }
            model.fileInformation = nil
            print("✓ Read native S9 sample-rate, pitch and loop attributes")

            try await model.exportNativeFiles(
                [program],
                to: copiedDirectory,
                policy: .rename,
                revealInFinder: false
            )
            let copiedNames = try FileManager.default.contentsOfDirectory(atPath: copiedDirectory.path)
            guard copiedNames == ["DELETEP9.P9"] else {
                throw RegressionFailure(
                    "The original P9 copy had an incorrect filename: \(copiedNames.joined(separator: ", "))."
                )
            }
            print("✓ Copied the original P9 with exactly one uppercase extension")

            try await model.delete(files: [program])
            try await Task.sleep(nanoseconds: 300_000_000)
            hostingView.layoutSubtreeIfNeeded()
            guard !model.snapshot.files.contains(where: { $0.name.uppercased().hasSuffix(".P9") }) else {
                throw RegressionFailure("The P9 entry remained after deletion.")
            }
            guard model.report == nil,
                  model.headerNotice?.title == "Files Deleted"
            else {
                throw RegressionFailure(
                    "Successful deletion used a blocking report instead of a header notice."
                )
            }
            print("✓ Successful deletion reports through the non-blocking header")
            print("✓ Deleted a rendered, selected P9 row without a SwiftUI environment crash")

            guard let sampleName = model.availableSampleNames.first else {
                throw RegressionFailure(
                    "The sample dropdown did not expose the S9 sample in the open volume."
                )
            }
            let staleDraftDocument = try model.prepareBlankP9Program(
                named: "DRAFTSAFE"
            )
            let blankBaseline = staleDraftDocument.program.keygroups[0]
            var importedProgram = staleDraftDocument.program
            importedProgram.keygroups[0].softSampleName = sampleName
            importedProgram.keygroups[0].lowKey = 36
            importedProgram.keygroups[0].highKey = 36
            let revisionBeforeImport = staleDraftDocument.editorRevision
            staleDraftDocument.replaceProgram(
                with: importedProgram,
                refreshEditor: true
            )
            guard staleDraftDocument.editorRevision > revisionBeforeImport,
                  !staleDraftDocument.applyKeygroupDraft(
                    blankBaseline,
                    baseline: blankBaseline,
                    at: 0
                  ),
                  staleDraftDocument.program.keygroups[0].softSampleName
                    == sampleName
            else {
                throw RegressionFailure(
                    "A stale editor draft replaced an externally imported first keygroup."
                )
            }
            print("✓ Stale editor drafts cannot overwrite an imported first keygroup")

            let newProgram = try model.prepareBlankP9Program(named: "NEWPROG")
            guard newProgram.program.keygroups.count == 1 else {
                throw RegressionFailure(
                    "A new program did not start with exactly one blank keygroup."
                )
            }
            var editedProgram = newProgram.program
            editedProgram.keygroups[0].softSampleName = sampleName
            editedProgram.keygroups[0].lowKey = 60
            editedProgram.keygroups[0].highKey = 60
            let duplicate = try editedProgram.appendKeygroup(copying: 0)
            editedProgram.keygroups[duplicate].lowKey = 61
            editedProgram.keygroups[duplicate].highKey = 61
            try editedProgram.deleteKeygroups(at: [0])
            newProgram.program = editedProgram

            try await model.performCreateP9InImage(newProgram)
            guard newProgram.source.isExistingImageProgram,
                  let storedProgram = model.snapshot.files.first(where: {
                      $0.name.caseInsensitiveCompare("NEWPROG.P9") == .orderedSame
                  })
            else {
                throw RegressionFailure(
                    "The verified new P9 was not present in the destination volume."
                )
            }
            guard newProgram.program.keygroups.count == 1,
                  newProgram.program.keygroups[0].id == 0,
                  newProgram.program.keygroups[0].softSampleName == sampleName,
                  newProgram.program.keygroups[0].lowKey == 61,
                  newProgram.program.keygroups[0].highKey == 61
            else {
                throw RegressionFailure(
                    "Keygroup creation/deletion did not survive the verified P9 round trip."
                )
            }
            model.selection = [storedProgram.id]
            print("✓ Sample choices come from the current S950 volume")
            print("✓ Created a new program and byte-verified it after keygroup add/delete")

            let imageBeforeAbletonExport = try Data(contentsOf: image)
            let templateURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent(
                "Sources/AKAIImageManager/Resources/AKAI-S950-Sampler-Template.adg"
            )
            let abletonExport = try await model.performAbletonDrumRackExport(
                storedProgram,
                to: workspace,
                templateURL: templateURL
            )
            let exportedPreset = try AbletonDrumRackParser.parse(
                url: abletonExport.adgURL
            )
            guard abletonExport.sampleURLs.count == 1,
                  exportedPreset.samples.count == 1,
                  exportedPreset.samples[0].sourceNote == 61,
                  exportedPreset.samples[0].sourceName == sampleName,
                  exportedPreset.samples[0].detectedRootNote == 61,
                  exportedPreset.samples[0].sampleURL.standardizedFileURL
                    == abletonExport.sampleURLs[0].standardizedFileURL,
                  abletonExport.warnings.isEmpty,
                  try Data(contentsOf: image) == imageBeforeAbletonExport
            else {
                throw RegressionFailure(
                    "The P9-to-Ableton export did not round-trip as one matching, non-destructive Sampler pad."
                )
            }
            print("✓ Exported P9/S9 content as a verified, non-destructive Ableton Sampler rack")

            guard let currentSample = model.snapshot.files.first(where: {
                $0.isSample
                    && sampleBaseName($0.name)
                        .caseInsensitiveCompare(sampleName) == .orderedSame
            }) else {
                throw RegressionFailure(
                    "The disposable S9 disappeared before rename testing."
                )
            }
            try await model.performNativeRename(
                currentSample,
                requestedName: "RENAMED"
            )
            guard let renamedSample = model.snapshot.files.first(where: {
                $0.isSample
                    && sampleBaseName($0.name) == "RENAMED"
            }), let linkedProgram = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("NEWPROG.P9") == .orderedSame
            }) else {
                throw RegressionFailure(
                    "The transactional S9 rename did not create the expected sample and retain its linked P9."
                )
            }
            model.openEditor(for: linkedProgram)
            for _ in 0..<100 where model.operationActive {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let linkedDocument = model.p9EditorDocument,
                  linkedDocument.program.keygroups[0].softSampleName == "RENAMED"
            else {
                throw RegressionFailure(
                    "The transactional S9 rename did not update the linked P9 reference."
                )
            }
            model.p9EditorDocument = nil
            model.selection = [renamedSample.id]
            print("✓ Renamed an S9 and byte-verified its updated linked P9")

            guard let programBeforeRename = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("NEWPROG.P9") == .orderedSame
            }) else {
                throw RegressionFailure(
                    "The linked P9 disappeared before program rename testing."
                )
            }
            try await model.performNativeRename(
                programBeforeRename,
                requestedName: "RACKPROG"
            )
            guard let renamedProgram = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("RACKPROG.P9") == .orderedSame
            }), !model.snapshot.files.contains(where: {
                $0.name.caseInsensitiveCompare("NEWPROG.P9") == .orderedSame
            }) else {
                throw RegressionFailure(
                    "The transactional P9 rename did not replace the directory entry."
                )
            }
            model.openEditor(for: renamedProgram)
            for _ in 0..<100 where model.operationActive {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard model.p9EditorDocument?.program.name == "RACKPROG" else {
                throw RegressionFailure(
                    "The transactional P9 rename did not update the internal program name."
                )
            }
            model.p9EditorDocument = nil
            print("✓ Renamed a P9 and byte-verified its internal program name")

            let imageBeforeReadOnlyExport = try Data(contentsOf: image)
            await model.shutdown()
            try await model.openImage(image, readOnly: true)
            guard let readOnlyProgram = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("RACKPROG.P9") == .orderedSame
            }), model.session?.readOnly == true else {
                throw RegressionFailure(
                    "The renamed P9 was not available after reopening the IMG read-only."
                )
            }
            let readOnlyAbletonExport = try await model.performAbletonDrumRackExport(
                readOnlyProgram,
                to: workspace,
                templateURL: templateURL
            )
            let readOnlyPreset = try AbletonDrumRackParser.parse(
                url: readOnlyAbletonExport.adgURL
            )
            guard readOnlyPreset.samples.count == 1,
                  readOnlyPreset.samples[0].sourceNote == 61,
                  try Data(contentsOf: image) == imageBeforeReadOnlyExport
            else {
                throw RegressionFailure(
                    "Read-only P9-to-Ableton export failed or changed the IMG."
                )
            }
            print("✓ Exported P9/S9 content from a read-only IMG without changing it")

            try await model.createFormattedImage(
                at: hardDiskImage,
                preset: .s900Hard32
            )
            guard model.snapshot.volumes.count == 1,
                  model.snapshot.volumes[0].name == "VOLUME 001",
                  model.snapshot.currentPath == model.snapshot.volumes[0].path
            else {
                throw RegressionFailure(
                    "The S950 hard-disk formatter did not create and open its initial volume."
                )
            }
            print("✓ S950 32 MB formatting creates and opens VOLUME 001")

            await model.shutdown()
            window.orderOut(nil)
            if let retainedImagePath {
                let retainedImage = URL(fileURLWithPath: retainedImagePath)
                if FileManager.default.fileExists(atPath: retainedImage.path) {
                    try FileManager.default.removeItem(at: retainedImage)
                }
                try FileManager.default.copyItem(at: image, to: retainedImage)
                print("Retained disposable image: \(retainedImage.path)")
            }
            print("\nInteraction regression passed")
        } catch {
            await seedingController.close()
            fputs("Interaction regression failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func findFileTable(in view: NSView, expectedRowCount: Int) -> NSTableView? {
        if let table = view as? NSTableView,
           table.numberOfColumns >= 6,
           table.numberOfRows == expectedRowCount {
            return table
        }
        for subview in view.subviews {
            if let table = findFileTable(in: subview, expectedRowCount: expectedRowCount) {
                return table
            }
        }
        return nil
    }

    private static func renderedText(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            result.append(field.stringValue)
        } else if let segmented = view as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                if let label = segmented.label(forSegment: index),
                   !label.isEmpty {
                    result.append(label)
                }
            }
        } else if let button = view as? NSButton, !button.title.isEmpty {
            result.append(button.title)
        }
        for subview in view.subviews {
            result.append(contentsOf: renderedText(in: subview))
        }
        return result
    }

    private static func sampleBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .uppercased()
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func loadedFilename(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url.lastPathComponent)
                } else {
                    continuation.resume(
                        throwing: RegressionFailure(
                            "The native drag provider returned no file."
                        )
                    )
                }
            }
        }
    }

    private static func writeTestWAV(to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205),
              let samples = buffer.int16ChannelData?[0]
        else {
            throw RegressionFailure("Could not allocate the test WAV.")
        }
        buffer.frameLength = 2_205
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Int16(sin(Double(frame) * 0.04) * 8_000)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }

    private static func appendCueMarkers(
        _ sampleOffsets: [UInt32],
        to wavURL: URL
    ) throws {
        var data = try Data(contentsOf: wavURL)
        guard data.count >= 12,
              Data(data[0..<4]) == Data("RIFF".utf8),
              Data(data[8..<12]) == Data("WAVE".utf8)
        else {
            throw RegressionFailure("The generated marker source is not RIFF/WAVE.")
        }
        var payload = Data()
        appendLittleEndian(UInt32(sampleOffsets.count), to: &payload)
        for (index, sampleOffset) in sampleOffsets.enumerated() {
            appendLittleEndian(UInt32(index + 1), to: &payload)
            appendLittleEndian(sampleOffset, to: &payload)
            payload.append(Data("data".utf8))
            appendLittleEndian(UInt32(0), to: &payload)
            appendLittleEndian(UInt32(0), to: &payload)
            appendLittleEndian(sampleOffset, to: &payload)
        }
        data.append(Data("cue ".utf8))
        appendLittleEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        if !payload.count.isMultiple(of: 2) { data.append(0) }
        let riffSize = UInt32(data.count - 8)
        data[4] = UInt8(riffSize & 0xFF)
        data[5] = UInt8((riffSize >> 8) & 0xFF)
        data[6] = UInt8((riffSize >> 16) & 0xFF)
        data[7] = UInt8((riffSize >> 24) & 0xFF)
        try data.write(to: wavURL, options: .atomic)
    }

    private static func appendLittleEndian(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func createTestApplication(
        at url: URL,
        launchLog: URL
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let executable = executableDirectory.appendingPathComponent(
            "Test Audio Editor"
        )
        try Data(
            "#!/bin/sh\n/usr/bin/touch '\(launchLog.path)'\nexit 0\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let propertyList: [String: Any] = [
            "CFBundleIdentifier": "test.akai.interaction-audio-editor",
            "CFBundleName": "Test Audio Editor",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Test Audio Editor"
        ]
        let propertyListData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try propertyListData.write(
            to: contents.appendingPathComponent("Info.plist")
        )
    }
}

private struct RegressionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
