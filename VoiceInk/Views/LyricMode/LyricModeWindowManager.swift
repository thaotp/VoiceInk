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
    let originalTranscriptionPublisher = PassthroughSubject<(corrected: String, original: String), Never>()
    
    // Original (pre-correction) text mapping: corrected text -> original text
    @Published var originalTextMap: [String: String] = [:]
    
    // MARK: - Dependencies
    
    private var panel: LyricModeOverlayPanel?
    private var windowController: NSWindowController?
    private var appleSpeechService: AppleSpeechRealtimeService?
    private var diarizedOrchestrator: DiarizedTranscriberOrchestrator?
    private var cancellables = Set<AnyCancellable>()
    private var deviceChangeWorkItem: DispatchWorkItem?
    private var timer: Timer?
    
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
    /// Show Lyric Mode with Apple Speech engine
    func show() async throws {
        guard !isVisible else { return }
        
        // Configure audio device if specified
        configureAudioDevice()
        
        // Create Apple Speech service
        let speechService = AppleSpeechRealtimeService()
        speechService.setLanguage(settings.selectedLanguage)
        appleSpeechService = speechService
        
        // Initialize window
        initializeWindowForAppleSpeech()
        
        // Start Apple Speech listening
        try await speechService.startListening()
        
        // Show panel
        panel?.show()
        isVisible = true
    }
    
    func hide() {
        guard isVisible else { return }
        
        // Stop Apple Speech
        appleSpeechService?.stopListening()
        appleSpeechService = nil
        
        // Stop diarized orchestrator if active
        diarizedOrchestrator?.stop()
        diarizedOrchestrator = nil
        
        // Hide and cleanup window
        panel?.hide()
        deinitializeWindow()
        
        isVisible = false
    }
    
    func toggle() async throws {
        if isVisible {
            hide()
        } else {
            try await show()
        }
    }
    
    // MARK: - Notes-style Recording (without overlay by default)
    
    /// Start recording and transcription without showing overlay
    func startRecording(with whisperState: WhisperState) async throws {
        guard !isRecording else { return }
        
        // Configure audio device if specified
        configureAudioDevice()
        
        // Start Apple Speech transcription
        if settings.speakerDiarizationEnabled {
            // Use diarized transcription with speaker labels
            let orchestrator = DiarizedTranscriberOrchestrator.withSelectedBackend()
            orchestrator.setLanguage(settings.selectedLanguage)
            diarizedOrchestrator = orchestrator
            
            // Subscribe to diarization updates
            subscribeToDiarizedTranscription(orchestrator: orchestrator)
            
            try await orchestrator.start()
        } else {
            // Standard Apple Speech without diarization
            let speechService = AppleSpeechRealtimeService()
            speechService.setLanguage(settings.selectedLanguage)
            appleSpeechService = speechService
            
            // Subscribe to Apple Speech updates
            subscribeToAppleSpeechTranscription(service: speechService)
            
            try await speechService.startListening()
        }
        
        isRecording = true
        isVisible = true
        
        recordingDuration = 0
        startTimer()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        print("[WindowManager] stopRecording - Full Cleanup Starting")
        
        appleSpeechService?.stopListening()
        appleSpeechService = nil
        
        // Stop diarized orchestrator
        diarizedOrchestrator?.stop()
        diarizedOrchestrator = nil
        
        // Clear transcript data to prevent stale state
        transcriptSegments = []
        originalTextMap = [:]
        
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
        appleSpeechService?.pause()
        diarizedOrchestrator?.pause()
        stopTimer()
    }
    
    /// Resume recording after pause
    func resumeRecording() {
        appleSpeechService?.resume()
        diarizedOrchestrator?.resume()
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
            initializeWindowForAppleSpeech()
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
        var publishedForTranslation: Set<String> = [] // Cache to prevent duplicate translation
        
        service.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                
                // Only publish if not already sent for translation
                if !publishedForTranslation.contains(text) {
                    publishedForTranslation.insert(text)
                    self.transcriptionPublisher.send(text)
                }
            }
            .store(in: &cancellables)
        
        service.$partialTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.partialTranscriptionPublisher.send(text)
            }
            .store(in: &cancellables)
        
        // Forward original (pre-correction) text mapping for "Show original" feature
        service.originalTranscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mapping in
                self?.originalTextMap[mapping.corrected] = mapping.original
                self?.originalTranscriptionPublisher.send(mapping)
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToDiarizedTranscription(orchestrator: DiarizedTranscriberOrchestrator) {
        var publishedForTranslation: Set<String> = []
        
        // Subscribe to segment changes (using Combine for @Published)
        orchestrator.$segments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segments in
                guard let self = self else { return }
                
                print("[WindowManager] Received \(segments.count) diarized segments")
                
                // Convert segments to string format with speaker labels
                let newSegments = segments.map { segment -> String in
                    let speakerPrefix = segment.speaker.displayName
                    return "[\(speakerPrefix)]: \(segment.text)"
                }
                
                // Update transcript segments
                self.transcriptSegments = newSegments
                
                print("[WindowManager] Updated transcriptSegments to \(newSegments.count) items")
                
                // Publish new segments for translation
                if let lastSegment = newSegments.last, !publishedForTranslation.contains(lastSegment) {
                    publishedForTranslation.insert(lastSegment)
                    self.transcriptionPublisher.send(lastSegment)
                }
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToTeamsLiveCaptions(service: TeamsLiveCaptionsService) {
        var preExistingCount: Int = -1  // -1 means not yet initialized
        var publishedForTranslation: Set<String> = [] // Cache of segments already sent for translation
        
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
                    
                    // Mark pre-existing as already "published" so they won't be translated
                    for entry in entries where entry.isPreExisting {
                        let segment = entry.speaker != "Unknown"
                            ? "[\(entry.speaker)]: \(entry.text)"
                            : entry.text
                        publishedForTranslation.insert(segment)
                    }
                }
                
                // Sync transcript segments with caption entries
                let newSegments = entries.map { entry in
                    entry.speaker != "Unknown" 
                        ? "[\(entry.speaker)]: \(entry.text)" 
                        : entry.text
                }
                
                // Only update if there are changes
                if newSegments != self.transcriptSegments {
                    self.transcriptSegments = newSegments
                    
                    // Publish only NEW segments that haven't been published yet
                    for entry in entries where !entry.isPreExisting {
                        let segment = entry.speaker != "Unknown"
                            ? "[\(entry.speaker)]: \(entry.text)"
                            : entry.text
                        
                        // Only publish if not already sent for translation
                        if !publishedForTranslation.contains(segment) {
                            publishedForTranslation.insert(segment)
                            self.transcriptionPublisher.send(segment)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToWhisperKitTranscription(service: WhisperKitRealtimeService) {
        var publishedForTranslation: Set<String> = []
        
        service.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                
                // Only publish if not already sent for translation
                if !publishedForTranslation.contains(text) {
                    publishedForTranslation.insert(text)
                    self.transcriptionPublisher.send(text)
                }
            }
            .store(in: &cancellables)
        
        service.$partialTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.partialTranscriptionPublisher.send(text)
            }
            .store(in: &cancellables)
    }
    
    func clear() {
        appleSpeechService?.clear()
        
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
    
    // initializeWindow for Whisper removed - using initializeWindowForAppleSpeech only
    
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
