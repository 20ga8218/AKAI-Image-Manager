import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppSettings: ObservableObject {
    static let executableDefault: String = {
        let candidates = [
            "/usr/local/bin/akaiutil",
            "/opt/homebrew/bin/akaiutil"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            ?? "/usr/local/bin/akaiutil"
    }()
    static let usbCleanDefault = "/Applications/USBclean.app"
    nonisolated static var applicationBundleContentType: UTType {
        .applicationBundle
    }

    @Published var executablePath: String { didSet { save() } }
    @Published var defaultMono: Bool { didSet { save() } }
    @Published var preserveSampleRate: Bool { didSet { save() } }
    @Published var compressedS900: Bool { didSet { save() } }
    @Published var backupBeforeDestructive: Bool { didSet { save() } }
    @Published var backupFolderPath: String { didSet { save() } }
    @Published var openExportDestination: Bool { didSet { save() } }
    @Published var audioEditorPath: String { didSet { save() } }
    @Published var usbCleanPath: String { didSet { save() } }
    @Published var autoOpenLogOnError: Bool { didSet { save() } }
    @Published var ejectAfterUSBCopy: Bool { didSet { save() } }
    @Published var detectedVersion = "Not checked"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        executablePath = defaults.string(forKey: "executablePath") ?? Self.executableDefault
        defaultMono = defaults.object(forKey: "defaultMono") as? Bool ?? true
        preserveSampleRate = defaults.object(forKey: "preserveSampleRate") as? Bool ?? true
        compressedS900 = defaults.object(forKey: "compressedS900") as? Bool ?? false
        backupBeforeDestructive = defaults.object(forKey: "backupBeforeDestructive") as? Bool ?? true
        backupFolderPath = defaults.string(forKey: "backupFolderPath") ?? ""
        openExportDestination = defaults.object(forKey: "openExportDestination") as? Bool ?? false
        audioEditorPath = defaults.string(forKey: "audioEditorPath") ?? ""
        usbCleanPath = defaults.string(forKey: "usbCleanPath") ?? Self.usbCleanDefault
        autoOpenLogOnError = defaults.object(forKey: "autoOpenLogOnError") as? Bool ?? true
        ejectAfterUSBCopy = defaults.object(forKey: "ejectAfterUSBCopy") as? Bool ?? false
    }

    var defaultImportOptions: ImportOptions {
        ImportOptions(
            family: .s900,
            compressedS900: compressedS900,
            convertToMono: defaultMono,
            preserveSampleRate: preserveSampleRate,
            collisionPolicy: .rename
        )
    }

    var executableURL: URL { URL(fileURLWithPath: executablePath) }
    var audioEditorURL: URL? {
        guard !audioEditorPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: audioEditorPath)
        return Self.isRunnableApplication(at: url) ? url : nil
    }
    var usbCleanURL: URL? { ImageFileOperations.exactUSBcleanURL(preferredPath: usbCleanPath) }

    func validateExecutable() async {
        let path = executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            detectedVersion = "Not executable"
            return
        }
        detectedVersion = await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-h"]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                if let range = output.range(of: #"Rev\.\s+([0-9]+(?:\.[0-9]+)*)"#, options: .regularExpression) {
                    let versionText = output[range]
                        .replacingOccurrences(of: "Rev.", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    return "AKAI Util \(versionText)"
                }
                return "Executable detected"
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose AKAI Util"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = executableURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
            Task { await validateExecutable() }
        }
    }

    func chooseUSBclean() {
        let panel = NSOpenPanel()
        panel.title = "Choose USBclean"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [Self.applicationBundleContentType]
        if panel.runModal() == .OK, let url = panel.url { usbCleanPath = url.path }
    }

    func chooseAudioEditor() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio Editor"
        panel.prompt = "Choose Editor"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [Self.applicationBundleContentType]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK,
           let url = panel.url,
           Self.isRunnableApplication(at: url) {
            audioEditorPath = url.path
        }
    }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Default IMG Backup Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !backupFolderPath.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: backupFolderPath,
                isDirectory: true
            )
        }
        if panel.runModal() == .OK, let url = panel.url {
            storeBackupDestination(url)
        }
    }

    func clearBackupFolder() {
        backupFolderPath = ""
        defaults.removeObject(forKey: "backupFolderBookmark")
        defaults.removeObject(forKey: "backupFolderPath")
    }

    func backupDestination(for imageURL: URL) -> URL {
        if !backupFolderPath.isEmpty {
            return storedBackupDestination()
                ?? URL(
                    fileURLWithPath: backupFolderPath,
                    isDirectory: true
                )
        }
        return imageURL.deletingLastPathComponent()
    }

    nonisolated static func isRunnableApplication(at url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: url),
              let executableURL = bundle.executableURL
        else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func restoreDefaults() {
        executablePath = Self.executableDefault
        defaultMono = true
        preserveSampleRate = true
        compressedS900 = false
        backupBeforeDestructive = true
        clearBackupFolder()
        openExportDestination = false
        audioEditorPath = ""
        usbCleanPath = Self.usbCleanDefault
        autoOpenLogOnError = true
        ejectAfterUSBCopy = false
        defaults.removeObject(forKey: "lastExportBookmark")
        Task { await validateExecutable() }
    }

    func storeExportDestination(_ url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: "lastExportBookmark")
        }
        defaults.set(url.path, forKey: "lastExportPath")
    }

    func lastExportDestination() -> URL? {
        if let data = defaults.data(forKey: "lastExportBookmark") {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale { storeExportDestination(url) }
                return url
            }
        }
        return defaults.string(forKey: "lastExportPath").map(URL.init(fileURLWithPath:))
    }

    private func storeBackupDestination(_ url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: "backupFolderBookmark")
        }
        backupFolderPath = url.path
    }

    private func storedBackupDestination() -> URL? {
        if let data = defaults.data(forKey: "backupFolderBookmark") {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale { storeBackupDestination(url) }
                return url
            }
        }
        guard !backupFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: backupFolderPath, isDirectory: true)
    }

    private func save() {
        defaults.set(executablePath, forKey: "executablePath")
        defaults.set(defaultMono, forKey: "defaultMono")
        defaults.set(preserveSampleRate, forKey: "preserveSampleRate")
        defaults.set(compressedS900, forKey: "compressedS900")
        defaults.set(backupBeforeDestructive, forKey: "backupBeforeDestructive")
        defaults.set(backupFolderPath, forKey: "backupFolderPath")
        defaults.set(openExportDestination, forKey: "openExportDestination")
        defaults.set(audioEditorPath, forKey: "audioEditorPath")
        defaults.set(usbCleanPath, forKey: "usbCleanPath")
        defaults.set(autoOpenLogOnError, forKey: "autoOpenLogOnError")
        defaults.set(ejectAfterUSBCopy, forKey: "ejectAfterUSBCopy")
    }
}
