#if DEBUG
import AppKit
import Paintbrush

/// For the Mac App Store screenshots, driven by `Assets/App Store/capture-mac.sh`.
///
/// Launched with `-ScreenshotDocument <path>`, the app opens that document
/// alone, in Dark Mode, in a window sized to the screenshots on the sharpest
/// screen there is. It then picks the tool, layer, swatch and inspector panel
/// the other arguments name, and once the window has settled writes its
/// number to `-ScreenshotWindowFile` for `screencapture` to find.
@MainActor
enum ScreenshotStaging {
    private static let defaults = UserDefaults.standard

    static var isStaging: Bool { defaults.string(forKey: "ScreenshotDocument") != nil }

    /// 2880 × 1800 pixels on a Retina screen.
    private static let windowSize = NSSize(width: 1440, height: 900)

    static func run() {
        guard let path = defaults.string(forKey: "ScreenshotDocument") else { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSDocumentController.shared.openDocument(
            withContentsOf: URL(fileURLWithPath: path), display: true
        ) { document, _, error in
            guard let controller = document?.windowControllers.first as? EditorWindowController,
                  let window = controller.window else {
                fail("could not open \(path): \(error?.localizedDescription ?? "no window")")
            }
            place(window)
            stage(controller.session.state)
            Task {
                // Let the canvas fit the picture and the inspector come in.
                try? await Task.sleep(for: .seconds(3))
                guard let file = defaults.string(forKey: "ScreenshotWindowFile") else { return }
                do {
                    try String(window.windowNumber).write(toFile: file, atomically: true, encoding: .utf8)
                } catch {
                    fail("could not write \(file): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func place(_ window: NSWindow) {
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? window.screen
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - windowSize.width / 2, y: visible.midY - windowSize.height / 2)
        window.setFrame(NSRect(origin: origin, size: windowSize), display: true)
        // In front and key, so the window is drawn as the one being used.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func stage(_ state: EditorState) {
        let composition = state.composition
        if let name = defaults.string(forKey: "ScreenshotLayer") {
            guard let layer = composition.layers.first(where: { $0.name == name }) else { fail("no layer named \(name)") }
            state.activeLayerID = layer.id
        }
        if let raw = defaults.string(forKey: "ScreenshotTool") {
            guard let tool = Tool(rawValue: raw) else { fail("no tool \(raw)") }
            state.tool = tool
        }
        if defaults.object(forKey: "ScreenshotSwatch") != nil {
            let index = defaults.integer(forKey: "ScreenshotSwatch")
            guard composition.swatches.indices.contains(index) else { fail("no swatch \(index)") }
            state.color = composition.swatches[index]
        }
        if let raw = defaults.string(forKey: "ScreenshotPanel") {
            guard let panel = EditorPanel(rawValue: raw) else { fail("no panel \(raw)") }
            state.presentedPanel = panel
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ScreenshotStaging: \(message)\n".utf8))
        exit(1)
    }
}
#endif
