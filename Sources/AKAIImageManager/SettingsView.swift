import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable {
        case general
        case safety
    }

    @EnvironmentObject private var settings: AppSettings
    @State private var selectedTab: Tab

    init(initialTab: Tab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("AKAI Util") {
                    HStack {
                        TextField("Executable", text: $settings.executablePath)
                        Button("Choose…") { settings.chooseExecutable() }
                    }
                    LabeledContent("Detected", value: settings.detectedVersion)
                    Button("Validate Again") {
                        Task { await settings.validateExecutable() }
                    }
                }
                Section("S950 Import Defaults") {
                    Toggle("Convert WAV files to mono", isOn: $settings.defaultMono)
                    Toggle("Preserve compatible sample rates", isOn: $settings.preserveSampleRate)
                    Toggle("Compress S950 samples", isOn: $settings.compressedS900)
                }
                Section("External Audio Editor") {
                    HStack {
                        TextField(
                            "Application",
                            text: $settings.audioEditorPath,
                            prompt: Text("Choose an audio editor application")
                        )
                        Button("Choose…") { settings.chooseAudioEditor() }
                    }
                    Text(
                        "A selected S950 sample can be exported as WAV, opened in this editor, then safely converted and returned to its IMG."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Tab.general)

            Form {
                Section("Data Protection") {
                    Toggle("Back up before destructive operations", isOn: $settings.backupBeforeDestructive)
                    LabeledContent("Default IMG backup folder") {
                        HStack {
                            Text(
                                settings.backupFolderPath.isEmpty
                                    ? "Beside each IMG"
                                    : settings.backupFolderPath
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            Button("Choose…") { settings.chooseBackupFolder() }
                            if !settings.backupFolderPath.isEmpty {
                                Button("Use IMG Folder") {
                                    settings.clearBackupFolder()
                                }
                            }
                        }
                    }
                    Toggle(
                        "Open destination folder after export",
                        isOn: $settings.openExportDestination
                    )
                    Toggle("Open diagnostic log when an error occurs", isOn: $settings.autoOpenLogOnError)
                }
                Section("USBclean") {
                    HStack {
                        TextField("Application", text: $settings.usbCleanPath)
                        Button("Choose…") { settings.chooseUSBclean() }
                    }
                    Toggle("Clean and eject after a verified USB copy", isOn: $settings.ejectAfterUSBCopy)
                    Text("Ejection only happens after an explicit Clean Eject action, or after a confirmed USB copy when this preference is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Restore Defaults", role: .destructive) { settings.restoreDefaults() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Safety", systemImage: "lock.shield") }
            .tag(Tab.safety)
        }
        .padding(12)
    }
}
