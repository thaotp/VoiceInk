import SwiftUI
import AppKit

/// Manages the Lyric Mode overlay window lifecycle
@MainActor
final class LyricModeWindowManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isVisible = false
    
    // MARK: - Dependencies
    
    private var panel: LyricModeOverlayPanel?
    private var windowController: NSWindowController?
    private var transcriptionEngine: RealtimeTranscriptionEngine?
    private var appleSpeechService: AppleSpeechRealtimeService?
    private var whisperContext: WhisperContext?
    
    private let audioStreamService = RealtimeAudioStreamService()
    private let vadService = FluidAudioVADService()
    private let settings = LyricModeSettings.shared
    
    // MARK: - Initialization
    
    init() {
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    
    /// Show Lyric Mode with Whisper engine
    func show(with whisperContext: WhisperContext) async throws {
        guard !isVisible else { return }
        
        self.whisperContext = whisperContext
        
        // Configure audio device if specified
        configureAudioDevice()
        
        // Configure VAD with settings
        vadService.configuration.minSilenceDuration = settings.softTimeout
        vadService.configuration.maxSilenceDuration = settings.hardTimeout
        
        // Create transcription engine with FluidAudio VAD
        let engine = RealtimeTranscriptionEngine(
            audioStream: audioStreamService,
            fluidVadService: vadService
        )
        transcriptionEngine = engine
        
        // Initialize window
        initializeWindow()
        
        // Start transcription
        try await engine.start(with: whisperContext)
        
        // Show panel
        panel?.show()
        isVisible = true
    }
    
    /// Show Lyric Mode with Apple Speech engine
    func showWithAppleSpeech() async throws {
        guard !isVisible else { return }
        
        // Configure audio device if specified
        configureAudioDevice()
        
        // Create Apple Speech service
        let speechService = AppleSpeechRealtimeService()
        speechService.setLanguage(settings.selectedLanguage)
        appleSpeechService = speechService
        
        // Create a simple transcription engine for display
        // We'll use the speech service directly for transcription
        let engine = RealtimeTranscriptionEngine(
            audioStream: audioStreamService,
            fluidVadService: vadService
        )
        transcriptionEngine = engine
        
        // Initialize window
        initializeWindowForAppleSpeech()
        
        // Start Apple Speech listening (requests authorization if needed)
        try await speechService.startListening()
        
        // Show panel
        panel?.show()
        isVisible = true
    }
    
    func hide() {
        guard isVisible else { return }
        
        // Stop transcription engine
        transcriptionEngine?.stop()
        
        // Stop Apple Speech if active
        appleSpeechService?.stopListening()
        appleSpeechService = nil
        
        // Hide and cleanup window
        panel?.hide()
        deinitializeWindow()
        
        transcriptionEngine = nil
        isVisible = false
    }
    
    func toggle(with whisperContext: WhisperContext) async throws {
        if isVisible {
            hide()
        } else {
            try await show(with: whisperContext)
        }
    }
    
    func clear() {
        transcriptionEngine?.clear()
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("HideLyricModeOverlay"),
            object: nil
        )
    }
    
    @objc private func handleHideNotification() {
        hide()
    }
    
    private func configureAudioDevice() {
        if !settings.selectedAudioDeviceUID.isEmpty {
            let audioDeviceManager = AudioDeviceManager.shared
            if let device = audioDeviceManager.availableDevices.first(where: { $0.uid == settings.selectedAudioDeviceUID }) {
                try? AudioDeviceConfiguration.setDefaultInputDevice(device.id)
            }
        }
    }
    
    private func initializeWindow() {
        deinitializeWindow()
        
        let overlayPanel = LyricModeOverlayPanel()
        overlayPanel.isClickThroughEnabled = settings.isClickThroughEnabled
        
        guard let engine = transcriptionEngine else { return }
        
        let overlayView = LyricModeOverlayView(
            transcriptionEngine: engine,
            settings: settings
        )
        
        let hostingController = NSHostingController(rootView: overlayView)
        overlayPanel.contentView = hostingController.view
        
        self.panel = overlayPanel
        self.windowController = NSWindowController(window: overlayPanel)
    }
    
    private func initializeWindowForAppleSpeech() {
        deinitializeWindow()
        
        let overlayPanel = LyricModeOverlayPanel()
        overlayPanel.isClickThroughEnabled = settings.isClickThroughEnabled
        
        guard let speechService = appleSpeechService else { return }
        
        let overlayView = LyricModeAppleSpeechOverlayView(
            speechService: speechService,
            settings: settings
        )
        
        let hostingController = NSHostingController(rootView: overlayView)
        overlayPanel.contentView = hostingController.view
        
        self.panel = overlayPanel
        self.windowController = NSWindowController(window: overlayPanel)
    }
    
    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }
    
    // MARK: - Settings Updates
    
    func updateClickThrough(_ enabled: Bool) {
        panel?.isClickThroughEnabled = enabled
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showLyricModeOverlay = Notification.Name("ShowLyricModeOverlay")
    static let hideLyricModeOverlay = Notification.Name("HideLyricModeOverlay")
    static let toggleLyricModeOverlay = Notification.Name("ToggleLyricModeOverlay")
}
