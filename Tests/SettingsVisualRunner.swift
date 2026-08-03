import AppKit
import SwiftUI

@main
@MainActor
struct SettingsVisualRunner {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: SettingsVisualRunner <screenshot.png>\n", stderr)
            exit(2)
        }
        let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let defaults = UserDefaults(
            suiteName: "AKAIImageManager.SettingsVisual.\(UUID().uuidString)"
        ) else {
            fputs("Could not create isolated settings.\n", stderr)
            exit(1)
        }
        let settings = AppSettings(defaults: defaults)
        settings.backupFolderPath =
            "/Users/example/Music/AKAI Image Manager Backups"
        settings.openExportDestination = true

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        NSApplication.shared.finishLaunching()
        let root = SettingsView(initialTab: .safety)
            .environmentObject(settings)
            .frame(width: 620, height: 560)
        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AKAI Image Manager Settings — Visual Smoke Test"
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        hostingView.layoutSubtreeIfNeeded()

        let bounds = hostingView.bounds
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: bounds
        ) else {
            fputs("Could not capture Settings.\n", stderr)
            exit(1)
        }
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:])
        else {
            fputs("Could not encode Settings screenshot.\n", stderr)
            exit(1)
        }
        do {
            try data.write(to: screenshotURL)
            print("Settings smoke screenshot: \(screenshotURL.path)")
        } catch {
            fputs("Settings visual smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        window.orderOut(nil)
    }
}
