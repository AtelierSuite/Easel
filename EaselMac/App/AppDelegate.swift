import AppKit

/// Easel on the Mac: a document app, each picture in a window of its own.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.make()
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Every point a pen or mouse passes through, not one per frame, so
        // a quick stroke keeps its shape.
        NSEvent.isMouseCoalescingEnabled = false
        // Tabs come from the documents' windows, and full screen from the
        // View menu; leave AppKit's own items to them.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    @objc func openSourceCode(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/AtelierSuite/Easel")!)
    }
}
