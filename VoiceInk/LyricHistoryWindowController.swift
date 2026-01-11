import SwiftUI
import SwiftData
import AppKit

class LyricHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = LyricHistoryWindowController()

    private var historyWindow: NSWindow?
    private let windowIdentifier = NSUserInterfaceItemIdentifier("com.prakashjoshipax.voiceink.lyricHistoryWindow")
    private let windowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkLyricHistoryWindowFrame")

    private override init() {
        super.init()
    }

    func showHistoryWindow(modelContext: ModelContext) {
        if let existingWindow = historyWindow {
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = createHistoryWindow(modelContext: modelContext)
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func createHistoryWindow(modelContext: ModelContext) -> NSWindow {
        // We need to inject the modelContext (or container) into the new view hierarchy
        // Since we have the context, we can get the container
        let container = modelContext.container
        
        let historyView = LyricHistoryView()
            .modelContainer(container) // crucial for the separate window to access SwiftData
            .frame(minWidth: 800, minHeight: 600)

        let hostingController = NSHostingController(rootView: historyView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = "Lyric Session History"
        window.identifier = windowIdentifier
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 600, height: 400)

        window.setFrameAutosaveName(windowAutosaveName)
        if !window.setFrameUsingName(windowAutosaveName) {
            window.center()
        }

        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == windowIdentifier else { return }

        historyWindow = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == windowIdentifier else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
