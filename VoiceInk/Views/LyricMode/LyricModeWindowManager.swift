import SwiftUI
import AppKit
import Combine

/// Manages the Lyric Mode overlay window lifecycle
@MainActor
final class LyricModeWindowManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isVisible = false
    @Published private(set) var isRecording = false
    @Published private(set) var isOverlayVisible = false
    
    // Content state (persists across tab switches)
    @Published var transcriptSegments: [String] = []
    @Published var translatedSegments: [String] = []
    @Published var partialText: String = ""
    @Published var recordingDuration: TimeInterval = 0
    
    // Publishers for transcription updates
    let transcriptionPublisher = PassthroughSubject<String, Never>()
    let partialTranscriptionPublisher = PassthroughSubject<String, Never>()
    
    // MARK: - Dependencies
    
    private var panel: LyricModeOverlayPanel?
    private var windowController: NSWindowController?
    private var transcriptionEngine: RealtimeTranscriptionEngine?
    private var appleSpeechService: AppleSpeechRealtimeService?
    private var teamsLiveCaptionsService: TeamsLiveCaptionsService?
    private var whisperContext: WhisperContext?
    private var cancellables = Set<AnyCancellable>()
    private var deviceChangeWorkItem: DispatchWorkItem?
    private var timer: Timer?
    
    private let audioStreamService = RealtimeAudioStreamService()
    private let vadService = FluidAudioVADService()
    let settings = LyricModeSettings.shared
    
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
    
    // MARK: - Notes-style Recording (without overlay by default)
    
    /// Start recording and transcription without showing overlay
    func startRecording(with whisperState: WhisperState) async throws {
        guard !isRecording else { return }
        
        // Configure audio device if specified
        configureAudioDevice()
        
        // Start based on engine type
        switch settings.engineType {
        case .whisper:
            // Find the selected model
            let modelName = settings.selectedModelName.isEmpty 
                ? whisperState.availableModels.first?.name ?? ""
                : settings.selectedModelName
            
            guard let model = whisperState.availableModels.first(where: { $0.name == modelName }) else {
                throw NSError(domain: "LyricMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Whisper model available. Please download a model first."])
            }
            
            // Load model if not already loaded
            if whisperState.whisperContext == nil {
                try await whisperState.loadModel(model)
            }
            
            guard let context = whisperState.whisperContext else {
                throw NSError(domain: "LyricMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load Whisper model"])
            }
            
            // Set the language override for Lyrics mode
            let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage
            await context.setLanguageOverride(language)
            
            self.whisperContext = context
            
            // Configure VAD
            vadService.configuration.minSilenceDuration = settings.softTimeout
            vadService.configuration.maxSilenceDuration = settings.hardTimeout
            
            // Create engine
            let engine = RealtimeTranscriptionEngine(
                audioStream: audioStreamService,
                fluidVadService: vadService
            )
            transcriptionEngine = engine
            
            // Subscribe to transcription updates
            subscribeToWhisperTranscription(engine: engine)
            
            // Start transcription
            try await engine.start(with: context)
            
        case .appleSpeech:
            let speechService = AppleSpeechRealtimeService()
            speechService.setLanguage(settings.selectedLanguage)
            appleSpeechService = speechService
            
            // Subscribe to Apple Speech updates
            subscribeToAppleSpeechTranscription(service: speechService)
            
            try await speechService.startListening()
            
        case .cloud:
            // Cloud not implemented for real-time yet
            throw NSError(domain: "LyricMode", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cloud engine not supported for real-time"])
            
        case .teamsLiveCaptions:
            // Create Teams Live Captions service
            let teamsService = TeamsLiveCaptionsService()
            
            // Set selected PID from settings if available
            if settings.teamsSelectedPID > 0 {
                teamsService.selectedProcessPID = pid_t(settings.teamsSelectedPID)
                if !settings.teamsSelectedWindowTitle.isEmpty {
                    teamsService.selectedWindowTitle = settings.teamsSelectedWindowTitle
                }
            }
            
            // Subscribe to Teams captions updates
            subscribeToTeamsLiveCaptions(service: teamsService)
            
            // Start reading captions
            teamsService.startReading()
            teamsLiveCaptionsService = teamsService
        }
        
        isRecording = true
        isVisible = true
        
        recordingDuration = 0
        startTimer()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        print("[WindowManager] stopRecording - Full Cleanup Starting")
        
        transcriptionEngine?.stop()
        appleSpeechService?.stopListening()
        appleSpeechService = nil
        
        teamsLiveCaptionsService?.stopReading()
        teamsLiveCaptionsService = nil
        
        // Clear transcript data to prevent stale state
        transcriptSegments = []
        
        stopTimer()
        
        // Remove all Combine subscriptions
        cancellables.removeAll()
        isRecording = false
        
        // Destroy old window to force fresh view instances on next start
        deinitializeWindow()
        
        print("[WindowManager] stopRecording - Full Cleanup Complete")
    }
    
    /// Pause recording (keeps engine alive but stops processing)
    func pauseRecording() {
        transcriptionEngine?.pause()
        appleSpeechService?.pause()
        teamsLiveCaptionsService?.stopReading()
        stopTimer()
    }
    
    /// Resume recording after pause
    func resumeRecording() {
        transcriptionEngine?.resume()
        appleSpeechService?.resume()
        teamsLiveCaptionsService?.startReading()
        startTimer()
    }
    
    /// Toggle overlay visibility
    func toggleOverlay() {
        if isOverlayVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }
    
    /// Show overlay panel
    func showOverlay() {
        if panel == nil {
            if appleSpeechService != nil {
                initializeWindowForAppleSpeech()
            } else if transcriptionEngine != nil {
                initializeWindow()
            }
        }
        panel?.show()
        isOverlayVisible = true
    }
    
    /// Hide overlay panel
    func hideOverlay() {
        panel?.hide()
        isOverlayVisible = false
    }
    
    // MARK: - Subscription Helpers
    
    private func subscribeToWhisperTranscription(engine: RealtimeTranscriptionEngine) {
        engine.$confirmedLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                if let lastLine = lines.last, !lastLine.isEmpty {
                    self?.transcriptionPublisher.send(lastLine)
                }
            }
            .store(in: &cancellables)
        
        engine.$partialLine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.partialTranscriptionPublisher.send(text)
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToAppleSpeechTranscription(service: AppleSpeechRealtimeService) {
        service.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.transcriptionPublisher.send(text)
            }
            .store(in: &cancellables)
        
        service.$partialTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.partialTranscriptionPublisher.send(text)
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToTeamsLiveCaptions(service: TeamsLiveCaptionsService) {
        var preExistingCount: Int = -1  // -1 means not yet initialized
        
        service.$captionEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                let sinkStart = Date()
                defer {
                    let sinkDur = Date().timeIntervalSince(sinkStart)
                    if sinkDur > 0.1 { print("[WindowManager] SLOW sink: \(String(format: "%.3f", sinkDur))s") }
                }
                guard let self = self else { return }
                
                // On first update, count pre-existing entries (skip translation for these)
                if preExistingCount == -1 {
                    preExistingCount = entries.filter { $0.isPreExisting }.count
                    print("[WindowManager] Pre-existing captions: \(preExistingCount) (translation skipped)")
                }
                
                // Sync transcript segments with caption entries
                let newSegments = entries.map { entry in
                    entry.speaker != "Unknown" 
                        ? "[\(entry.speaker)]: \(entry.text)" 
                        : entry.text
                }
                
                // Only update if there are changes
                if newSegments != self.transcriptSegments {
                    let previousNewCount = max(0, self.transcriptSegments.count - preExistingCount)
                    self.transcriptSegments = newSegments
                    
                    // Only publish NEW segments (after pre-existing ones) for translation
                    let currentNewCount = entries.count - preExistingCount
                    if currentNewCount > previousNewCount {
                        // New caption arrived - publish only the latest new one
                        if let lastEntry = entries.last, !lastEntry.isPreExisting {
                            let lastSegment = lastEntry.speaker != "Unknown"
                                ? "[\(lastEntry.speaker)]: \(lastEntry.text)"
                                : lastEntry.text
                            self.transcriptionPublisher.send(lastSegment)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func clear() {
        transcriptionEngine?.clear()
        appleSpeechService?.clear()
        teamsLiveCaptionsService?.clear()
        
        // Destroy old overlay so a fresh one is created on next show
        deinitializeWindow()
    }
    
    // MARK: - Timer Logic
    
    private func startTimer() {
        stopTimer() // Invalidate existing if any
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 0.1
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideOverlayNotification),
            name: NSNotification.Name("HideLyricModeOverlay"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceListChange),
            name: NSNotification.Name("AudioDeviceListChanged"),
            object: nil
        )
    }
    
    @objc private func handleHideOverlayNotification() {
        hideOverlay()
    }
    
    @objc private func handleDeviceListChange() {
        // If recording with Apple Speech, pause and resume to handle device change
        guard isRecording, let speechService = appleSpeechService else { return }
        
        // Cancel any pending resume to debounce rapid notifications
        deviceChangeWorkItem?.cancel()
        
        print("LyricMode: Device list changed during recording, pausing and resuming Apple Speech")
        speechService.pause()
        
        // Small delay then resume (debounced)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.appleSpeechService?.resume()
        }
        deviceChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
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
    static let lyricModeStopRecording = Notification.Name("LyricModeStopRecording")
    static let lyricModeShowMainWindow = Notification.Name("LyricModeShowMainWindow")
    static let lyricModeClearAndReset = Notification.Name("LyricModeClearAndReset")
}
