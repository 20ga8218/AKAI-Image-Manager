import AppKit
import SwiftUI

@main
@MainActor
struct VisualSmokeRunner {
    static func main() async {
        guard (3...4).contains(CommandLine.arguments.count) else {
            fputs("usage: VisualSmokeRunner <image.img> <screenshot.png> [akaiutil]\n", stderr)
            exit(2)
        }
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let settings = AppSettings()
        if CommandLine.arguments.count == 4 {
            settings.executablePath = CommandLine.arguments[3]
        }
        let model = AppModel(settings: settings)

        NSApplication.shared.setActivationPolicy(.regular)
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
        window.title = "AKAI Image Manager — Visual Smoke Test"
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        do {
            try await model.openImage(imageURL, readOnly: true)
            try await Task.sleep(nanoseconds: 900_000_000)
            hostingView.layoutSubtreeIfNeeded()
            let bounds = hostingView.bounds
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw VisualSmokeFailure.capture
            }
            hostingView.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw VisualSmokeFailure.capture
            }
            try data.write(to: screenshotURL)
            print("Visual smoke screenshot: \(screenshotURL.path)")
            model.closeImage()
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            fputs("Visual smoke test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

enum VisualSmokeFailure: Error {
    case capture
}
