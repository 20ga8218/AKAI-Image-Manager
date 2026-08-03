import AppKit
import CryptoKit
import Foundation

@main
@MainActor
struct AbletonImportRegressionRunner {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs(
                "usage: AbletonImportRegressionRunner <rack.adg> [akaiutil]\n",
                stderr
            )
            exit(2)
        }

        let sourceADG = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? AppSettings.executableDefault
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "akai-ableton-regression-\(UUID().uuidString)",
                isDirectory: true
            )
        let image = workspace.appendingPathComponent("ableton-import.img")
        let exports = workspace.appendingPathComponent(
            "native-exports",
            isDirectory: true
        )

        do {
            let sourceChecksum = try checksum(sourceADG)
            let preset = try AbletonDrumRackParser.parse(url: sourceADG)
            guard !preset.samples.isEmpty else {
                throw AbletonRegressionFailure(
                    "The supplied ADG did not expose any one-sample pads."
                )
            }
            if sourceADG.lastPathComponent
                == "S950 RACK filter gain velocity.adg" {
                guard preset.samples.map(\.s950Filter) == [99, 99, 99],
                      preset.samples.map(\.s950VelocityLoudness) == [0, 50, 0],
                      preset.samples.map(\.s950VelocityFilter) == [0, 50, 50]
                else {
                    throw AbletonRegressionFailure(
                        "The supplied three-pad velocity rack did not parse as "
                            + "Filter 99/99/99, Loudness Velocity 0/50/0 and "
                            + "Filter Velocity 0/50/50."
                    )
                }
            }

            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: workspace) }
            try FileManager.default.createDirectory(
                at: exports,
                withIntermediateDirectories: true
            )

            guard let defaults = UserDefaults(
                suiteName:
                    "AKAIImageManager.AbletonRegression.\(UUID().uuidString)"
            ) else {
                throw AbletonRegressionFailure(
                    "Could not create isolated test settings."
                )
            }
            let settings = AppSettings(defaults: defaults)
            settings.executablePath = executable.path
            settings.backupBeforeDestructive = false
            let model = AppModel(settings: settings)

            try await model.createFormattedImage(
                at: image,
                preset: .s900Hard32
            )
            let document = try model.prepareBlankP9Program(named: "ABLETON")
            var draft = AbletonDrumRackImportDraft(
                preset: preset,
                startNote: 36,
                existingSampleNames: model.availableSampleNames,
                existingKeygroupCount: document.program.keygroups.count,
                replacesBlankKeygroup: true
            )
            draft.rootNote = 60

            try await model.performAbletonDrumRackImport(
                draft,
                into: document
            )
            guard document.program.keygroups.count == preset.samples.count else {
                throw AbletonRegressionFailure(
                    "The blank keygroup was not replaced exactly; expected "
                        + "\(preset.samples.count) keygroups, got "
                        + "\(document.program.keygroups.count)."
                )
            }
            let mappedNotes = document.program.keygroups.map(\.lowKey)
            let expectedNotes = Array(36..<(36 + preset.samples.count))
            guard mappedNotes == expectedNotes,
                  document.program.keygroups.map(\.highKey) == expectedNotes
            else {
                throw AbletonRegressionFailure(
                    "The pads were not mapped in rack order from the requested start note."
                )
            }
            print(
                "✓ Parsed \(preset.samples.count) pads and mapped them in rack order"
            )
            print("✓ Replaced the blank full-range keygroup instead of appending it")

            try await model.performCreateP9InImage(document)
            let nativeFiles = model.snapshot.files.filter {
                NativeAkaiFileExport.isSupported($0.name)
            }
            guard nativeFiles.count == preset.samples.count + 1 else {
                throw AbletonRegressionFailure(
                    "Expected \(preset.samples.count) S9 files and one P9 after import."
                )
            }
            try await model.exportNativeFiles(
                nativeFiles,
                to: exports,
                policy: .rename,
                revealInFinder: false
            )

            guard let programURL = try FileManager.default
                .contentsOfDirectory(
                    at: exports,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .first(where: {
                    $0.pathExtension.caseInsensitiveCompare("p9")
                        == .orderedSame
                })
            else {
                throw AbletonRegressionFailure(
                    "The imported P9 could not be exported for verification."
                )
            }
            let programData = try Data(contentsOf: programURL)
            let storedProgram = try P9Program(data: programData)
            guard storedProgram.keygroups.count == preset.samples.count else {
                throw AbletonRegressionFailure(
                    "The stored P9 keygroup count differs from the preview."
                )
            }
            guard storedProgram.keygroups.map(\.softFilter)
                    == preset.samples.map(\.s950Filter),
                  storedProgram.keygroups.map(\.velocitySensitivity.loudness)
                    == preset.samples.map(\.s950VelocityLoudness),
                  storedProgram.keygroups.map(\.velocitySensitivity.filter)
                    == preset.samples.map(\.s950VelocityFilter)
            else {
                throw AbletonRegressionFailure(
                    "The stored P9 filter or velocity values differ from the ADG preview."
                )
            }
            print("✓ Stored base cutoff and both velocity sensitivities in the P9")

            var internalSampleNames = Set<String>()
            let nativeURLs = try FileManager.default.contentsOfDirectory(
                at: exports,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for sampleURL in nativeURLs where
                sampleURL.pathExtension.caseInsensitiveCompare("s9")
                    == .orderedSame
            {
                let name = try S9NativeSample.internalName(
                    in: Data(contentsOf: sampleURL)
                )
                internalSampleNames.insert(normalizedName(name))
            }
            let referencedNames = Set(
                storedProgram.keygroups.map {
                    normalizedName($0.softSampleName)
                }
            )
            guard referencedNames == internalSampleNames else {
                throw AbletonRegressionFailure(
                    "The P9 sample references do not exactly resolve to the stored S9 internal names."
                )
            }

            for index in storedProgram.keygroups.indices {
                let base =
                    P9Program.headerSize + index * P9Program.keygroupSize
                guard programData[base + 0x28] == 0,
                      programData[base + 0x29] == 0
                else {
                    throw AbletonRegressionFailure(
                        "Keygroup \(index + 1) retained a stale sample-header address."
                    )
                }
            }
            print("✓ Stored every P9 reference with its exact S9 internal name")
            print("✓ Cleared every imported keygroup’s stale sample-header address")

            await model.shutdown()
            guard try checksum(sourceADG) == sourceChecksum else {
                throw AbletonRegressionFailure(
                    "The source ADG changed during testing."
                )
            }
            print("✓ Created, re-exported and byte-validated the complete P9/S9 set")
            print("✓ Original ADG checksum is unchanged")
            print("\nAbleton import regression passed")
        } catch {
            fputs(
                "Ableton import regression failed: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
}

private struct AbletonRegressionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
