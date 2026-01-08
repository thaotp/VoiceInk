import SwiftUI
import AppKit

/// Custom NSPanel for the Lyric Mode overlay
/// Non-activating, always-on-top, resizable, multi-monitor support
class LyricModeOverlayPanel: NSPanel {
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    private static let windowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkLyricModeOverlay")
    
    var isClickThroughEnabled: Bool = false {
        didSet {
            ignoresMouseEvents = isClickThroughEnabled
        }
    }
    
    init() {
        let defaultFrame = LyricModeOverlayPanel.calculateDefaultFrame()
        
        super.init(
            contentRect: defaultFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable, .titled],
            backing: .buffered,
            defer: false
        )
        
        configurePanel()
        restoreFrameIfNeeded()
    }
    
    private func configurePanel() {
        // Window behavior
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        
        // Multi-monitor and spaces support
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Appearance
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        
        // Title bar
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        
        // Movement and sizing
        isMovable = true
        isMovableByWindowBackground = true
        
        // Size constraints
        minSize = NSSize(width: 300, height: 150)
        maxSize = NSSize(width: 800, height: 600)
        
        // Save position/size automatically
        setFrameAutosaveName(Self.windowAutosaveName)
        
        // Listen for screen changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    private func restoreFrameIfNeeded() {
        if !setFrameUsingName(Self.windowAutosaveName) {
            // No saved frame, use default
            let defaultFrame = LyricModeOverlayPanel.calculateDefaultFrame()
            setFrame(defaultFrame, display: true)
        }
    }
    
    private static func calculateDefaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 400, height: 250)
        }
        
        let width: CGFloat = 400
        let height: CGFloat = 250
        let padding: CGFloat = 50
        
        let visibleFrame = screen.visibleFrame
        let xPosition = visibleFrame.maxX - width - padding
        let yPosition = visibleFrame.minY + padding
        
        return NSRect(
            x: xPosition,
            y: yPosition,
            width: width,
            height: height
        )
    }
    
    func show() {
        orderFrontRegardless()
    }
    
    func hide() {
        orderOut(nil)
    }
    
    @objc private func handleScreenParametersChange() {
        // Ensure window stays within visible screen bounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let screen = self.screen ?? NSScreen.main else { return }
            
            let visibleFrame = screen.visibleFrame
            var currentFrame = self.frame
            
            // Adjust if window is outside visible area
            if currentFrame.maxX > visibleFrame.maxX {
                currentFrame.origin.x = visibleFrame.maxX - currentFrame.width
            }
            if currentFrame.minX < visibleFrame.minX {
                currentFrame.origin.x = visibleFrame.minX
            }
            if currentFrame.maxY > visibleFrame.maxY {
                currentFrame.origin.y = visibleFrame.maxY - currentFrame.height
            }
            if currentFrame.minY < visibleFrame.minY {
                currentFrame.origin.y = visibleFrame.minY
            }
            
            self.setFrame(currentFrame, display: true)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
