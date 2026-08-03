import AVFoundation
import Foundation

@main
struct IntegrationRunner {
    static func main() async {
        let executablePath = CommandLine.arguments.dropFirst().first
            ?? "/usr/local/bin/akaiutil"
        let executable = URL(fileURLWithPath: executablePath)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("akai-integration-\(UUID().uuidString)", isDirectory: true)
        let image = workspace.appendingPathComponent("roundtrip.img")
        let inputWAV = workspace.appendingPathComponent("ROUNDTRIP.wav")
        let exportDirectory = workspace.appendingPathComponent("export", isDirectory: true)
        let nativeDirectory = workspace.appendingPathComponent("native", isDirectory: true)
        let controller = AkaiCommandController()

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            try ImageFileOperations.createZeroFilledImage(at: image, byteCount: FormatPreset.s900Low.byteCount)
            try writeTestWAV(to: inputWAV)

            _ = try await controller.open(imageURL: image, executableURL: executable, readOnly: false)
            print("✓ Opened disposable 800 KB image")

            _ = try await controller.send(FormatPreset.s900Low.command)
            let diskInfo = try await controller.send("df")
            let disks = AkaiOutputParser.parseDF(diskInfo.output).0
            guard disks.count == 1, disks[0].totalBlocks == 800, disks[0].blockSize == 1024 else {
                throw IntegrationFailure("Formatted disk information did not match the documented S900 low-density geometry.")
            }
            print("✓ Formatted and parsed disposable S900 image")

            _ = try await controller.send(try AkaiCommandBuilder.localDirectory(workspace.path))
            _ = try await controller.send("wav2sample9 ROUNDTRIP.wav")
            let listing = try await controller.send("dir")
            let files = AkaiOutputParser.parseDirectory(listing.output).0
            guard files.count == 1, files[0].isSample else {
                throw IntegrationFailure("WAV import did not produce one AKAI sample.")
            }
            print("✓ Imported canonical WAV and browsed structured file data")

            _ = try await controller.send(try AkaiCommandBuilder.localDirectory(nativeDirectory.path))
            _ = try await controller.send(try AkaiCommandBuilder.exportNative(index: files[0].index))
            let nativeExports = try FileManager.default.contentsOfDirectory(
                at: nativeDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard let nativeFile = nativeExports.first(where: {
                ["S9", "P9"].contains($0.pathExtension.uppercased())
            }) else {
                throw IntegrationFailure("AKAI Util did not export a native S9/P9 file.")
            }
            _ = try await controller.send(try AkaiCommandBuilder.delete(index: files[0].index))
            _ = try await controller.send(try AkaiCommandBuilder.importNative(filename: nativeFile.lastPathComponent))
            let nativeListing = try await controller.send("dir")
            let nativeFiles = AkaiOutputParser.parseDirectory(nativeListing.output).0
            guard nativeFiles.count == 1 else {
                throw IntegrationFailure("Native S9/P9 import did not restore the AKAI file.")
            }
            print("✓ Exported and re-imported a native S9/P9 file")

            _ = try await controller.send(try AkaiCommandBuilder.localDirectory(exportDirectory.path))
            _ = try await controller.send(try AkaiCommandBuilder.exportWAV(index: nativeFiles[0].index))
            let exports = try FileManager.default.contentsOfDirectory(
                at: exportDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame }
            guard let exported = exports.first else {
                throw IntegrationFailure("AKAI Util did not export a WAV file.")
            }
            let inspection = try WAVService.inspect(
                exported,
                options: ImportOptions(family: .s900, convertToMono: true)
            )
            guard inspection.isLinearPCM, inspection.channelCount == 1 else {
                throw IntegrationFailure("The exported WAV could not be inspected as mono PCM.")
            }
            print("✓ Exported sample back to a readable WAV")

            await controller.close()
            guard await controller.state == .closed else {
                throw IntegrationFailure("AKAI Util did not reach the closed state.")
            }
            print("✓ AKAI Util quit cleanly")
            print("\nDisposable integration round trip passed")
        } catch {
            await controller.close()
            fputs("Integration test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func writeTestWAV(to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11_025)
        else { throw IntegrationFailure("Could not allocate the test WAV format.") }
        buffer.frameLength = 11_025
        guard let samples = buffer.int16ChannelData?[0] else {
            throw IntegrationFailure("Could not access the test WAV buffer.")
        }
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Int16(sin(Double(frame) * 0.04) * 9_000)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }
}

struct IntegrationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
