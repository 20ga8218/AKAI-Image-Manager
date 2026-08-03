import AppKit
import SwiftUI

@main
struct AKAIImageManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(minWidth: 920, minHeight: 600)
                .onOpenURL { model.handleOpenURLs([$0]) }
                .onAppear { appDelegate.model = model }
                .task { await settings.validateExecutable() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.openPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    if model.recentImages.isEmpty {
                        Text("No Recent Images")
                    } else {
                        ForEach(model.recentImages, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                model.openRecent(url)
                            }
                        }
                    }
                }
                Toggle(
                    "Open Images Read-Only",
                    isOn: $model.currentReadOnlyChoice
                )
                Divider()
                Button("Open S950 P9 Program…") { model.openP9EditorPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New or Format Image…") { model.showFormatSheet = true }
                    .keyboardShortcut("n")
                Button("Close Image") { model.closeImage() }
                    .keyboardShortcut("w")
                    .disabled(model.session == nil)
            }
            CommandMenu("Image") {
                Button("Import WAV Files…") { model.importPanel() }
                    .keyboardShortcut("i")
                    .disabled(!model.canImport)
                Button("Export Selected…") { model.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
                Button("Copy Original S9/P9 Files…") { model.copySelectedNativeFiles() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.canCopyNativeFiles)
                Button("Export Selected P9 as Ableton Drum Rack…") {
                    model.exportSelectedP9ToAbleton()
                }
                .disabled(!model.canExportSelectedP9ToAbleton)
                Button("Edit Selected P9 Keygroups…") { model.editSelectedP9() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!model.canEditSelectedP9)
                Button("Edit Selected Sample…") {
                    model.editSelectedSampleInAudioEditor()
                }
                .disabled(!model.canEditSelectedS9Sample)
                Button("Rename Selected S9/P9…") {
                    model.renameSelectedNativeFile()
                }
                .disabled(!model.canRenameSelectedNativeFile)
                Button("Selected File Information…") {
                    model.showSelectedFileInformation()
                }
                .disabled(!model.canShowSelectedFileInformation)
                Divider()
                Button("New S950 Program…") {
                    model.createP9Program()
                }
                .disabled(!model.canCreateP9Program)
                Button("New Program from Copied Keygroups…") {
                    model.createP9FromCopiedKeygroups()
                }
                .disabled(!model.canCreateP9FromCopiedKeygroups)
                Button("Export All Samples…") { model.exportAllSamples() }
                    .disabled(model.session == nil || model.isBusy)
                Divider()
                Button("Refresh") { model.refreshAction() }
                    .keyboardShortcut("r")
                    .disabled(model.session == nil || model.isBusy)
                Button("Disk Information") { model.showDiskInfo = true }
                    .disabled(model.session == nil)
                Button("Create Backup") { model.backupImage() }
                    .disabled(model.session == nil || model.isBusy)
                Divider()
                Button("Delete Selected…") { model.requestDeleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.canMutate || model.selectedFiles.isEmpty)
            }
            CommandMenu("View") {
                Toggle("Diagnostic Log", isOn: $model.isLogVisible)
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 620, height: 560)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
