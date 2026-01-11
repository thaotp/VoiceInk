import SwiftUI
import Combine

/// Main view for Lyric Mode with Notes-style inline transcription
struct LyricModeMainView: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    
    @State private var showingSettings = false
    @State private var translatedText: String = ""
    @State private var timer: Timer?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isPaused = false
    @State private var isTranslateEnabled = false
    @State private var shouldAutoScroll = true
    @State private var isProgrammaticScroll = false
    @State private var translatedSegments: [String] = []
    
    private let translationService = LyricModeTranslationService()
    
    // Convenience accessors for manager's content state
    private var transcriptSegments: [String] {
        get { lyricModeManager.transcriptSegments }
        nonmutating set { lyricModeManager.transcriptSegments = newValue }
    }
    
    private var partialText: String {
        get { lyricModeManager.partialText }
        nonmutating set { lyricModeManager.partialText = newValue }
    }
    
    private var recordingDuration: TimeInterval {
        get { lyricModeManager.recordingDuration }
        nonmutating set { lyricModeManager.recordingDuration = newValue }
    }
    
    /// Get the display name for the selected audio device
    private var selectedAudioDeviceName: String {
        if settings.selectedAudioDeviceUID.isEmpty {
            return "Default"
        }
        let devices = AudioDeviceManager.shared.availableDevices
        if let device = devices.first(where: { $0.uid == settings.selectedAudioDeviceUID }) {
            // Shorten name for header display
            let name = device.name
            return name.count > 20 ? String(name.prefix(17)) + "..." : name
        }
        return "Default"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Transcription area
            transcriptionArea
            
            Divider()
            
            // Controls
            controlsSection
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingSettings) {
            LyricModeSettingsPopup(
                settings: settings,
                whisperState: whisperState,
                isRecording: lyricModeManager.isRecording,
                onSettingsApplied: { audioDeviceChanged, engineChanged in
                    // Settings applied. Note: Audio device changes will take effect on next recording session.
                }
            )
        }
        .onChange(of: lyricModeManager.isRecording) { _, isRecording in
            if isRecording {
                startTimer()
            } else {
                stopTimer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyricModeStopRecording)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyricModeShowMainWindow)) { _ in
            // Bring the main window to front
            if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) }) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyricModeClearAndReset)) { _ in
            clearAndReset()
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Lyric Mode")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    // Audio input status indicator
                    audioStatusIndicator
                }
                
                // Current settings info
                HStack(spacing: 8) {
                    Label(settings.engineType.rawValue, systemImage: settings.engineType.icon)
                    Text("•")
                    Text(settings.selectedLanguage == "auto" ? "Auto" : settings.selectedLanguage.uppercased())
                    Text("•")
                    Label(selectedAudioDeviceName, systemImage: "mic")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            
            Spacer()
            
            // Translate toggle
            Button(action: { isTranslateEnabled.toggle() }) {
                Image(systemName: isTranslateEnabled ? "character.book.closed.fill" : "character.book.closed")
                    .font(.title3)
                    .foregroundColor(isTranslateEnabled ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(isTranslateEnabled ? "Hide Translation" : "Show Translation")
            
            // Overlay toggle
            Button(action: { lyricModeManager.toggleOverlay() }) {
                Image(systemName: lyricModeManager.isOverlayVisible ? "text.bubble.fill" : "text.bubble")
                    .font(.title3)
                    .foregroundColor(lyricModeManager.isOverlayVisible ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(lyricModeManager.isOverlayVisible ? "Hide Overlay" : "Show Overlay")
            
            // Settings button
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    /// Audio input status indicator showing connection/recording state
    private var audioStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(audioStatusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(audioStatusColor.opacity(0.3), lineWidth: 2)
                        .scaleEffect(lyricModeManager.isRecording && !isPaused ? 1.5 : 1.0)
                        .opacity(lyricModeManager.isRecording && !isPaused ? 0.0 : 1.0)
                        .animation(
                            lyricModeManager.isRecording && !isPaused ?
                            Animation.easeOut(duration: 1.0).repeatForever(autoreverses: false) :
                            .default,
                            value: lyricModeManager.isRecording
                        )
                )
            
            Text(audioStatusText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(audioStatusColor.opacity(0.1))
        )
    }
    
    private var audioStatusColor: Color {
        if !isAudioDeviceAvailable {
            return .red
        } else if lyricModeManager.isRecording {
            return isPaused ? .orange : .green
        } else {
            return .gray
        }
    }
    
    private var audioStatusText: String {
        if !isAudioDeviceAvailable {
            return "No Device"
        } else if lyricModeManager.isRecording {
            return isPaused ? "Paused" : "Recording"
        } else {
            return "Ready"
        }
    }
    
    private var isAudioDeviceAvailable: Bool {
        if settings.selectedAudioDeviceUID.isEmpty {
            return true // Using system default
        }
        return AudioDeviceManager.shared.availableDevices.contains { $0.uid == settings.selectedAudioDeviceUID }
    }
    
    // MARK: - Transcription Area
    
    private var transcriptionArea: some View {
        Group {
            if isTranslateEnabled {
                // Split view: Speech | Translation
                HSplitView {
                    // Left: Speech output
                    speechContentView
                        .frame(minWidth: 200)
                    
                    // Right: Translation
                    translationContentView
                        .frame(minWidth: 200)
                }
            } else {
                // Single view: Speech only
                speechContentView
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: isTranslateEnabled)
    }
    
    private var speechContentView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if transcriptSegments.isEmpty && partialText.isEmpty && !lyricModeManager.isRecording {
                            emptyState
                        } else {
                            // Display each transcript segment as a paragraph
                            ForEach(Array(transcriptSegments.enumerated()), id: \.offset) { index, segment in
                                VStack(alignment: .leading, spacing: 4) {
                                    TranscriptParagraphView(
                                        text: segment,
                                        fontSize: settings.fontSize,
                                        isLatest: index == transcriptSegments.count - 1 && partialText.isEmpty
                                    )
                                    
                                    // Show translation if enabled and available
                                    if settings.translationEnabled && index < translatedSegments.count && !translatedSegments[index].isEmpty {
                                        Text(translatedSegments[index])
                                            .font(.system(size: settings.fontSize * 0.85))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 31) // Align with paragraph text (16 + 15 for indicator bar)
                                            .padding(.bottom, 4)
                                    }
                                }
                            }
                            
                            // Partial (in-progress) text
                            if !partialText.isEmpty {
                                Text(partialText)
                                    .font(.system(size: settings.fontSize))
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("partial")
                            }
                            
                            // Scroll anchor
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onAppear {
                                    // If bottom appears, user is at bottom -> enable auto-scroll
                                    shouldAutoScroll = true
                                    isProgrammaticScroll = false
                                }
                                .onDisappear {
                                    // If bottom disappears AND we didn't just cause it by auto-scrolling,
                                    // then user scrolled up -> disable auto-scroll
                                    if !isProgrammaticScroll {
                                        shouldAutoScroll = false
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
                .onChange(of: transcriptSegments.count) { _, _ in
                    if shouldAutoScroll {
                        isProgrammaticScroll = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        // Reset flag after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isProgrammaticScroll = false
                        }
                    }
                }
                .onChange(of: partialText) { _, _ in
                    if shouldAutoScroll {
                        isProgrammaticScroll = true
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        // Reset flag after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isProgrammaticScroll = false
                        }
                    }
                }
                
                // Resume Auto-Scroll Button
                if !shouldAutoScroll && (!transcriptSegments.isEmpty || !partialText.isEmpty) {
                    Button(action: {
                        shouldAutoScroll = true
                        isProgrammaticScroll = true
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        // Reset flag after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isProgrammaticScroll = false
                        }
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                            .shadow(radius: 2, y: 1)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
    }
    
    private var translationContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if translatedText.isEmpty {
                    // Empty translation state
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("Translation")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Translated text will appear here")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 60)
                } else {
                    Text(translatedText)
                        .font(.system(size: settings.fontSize))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Transcription")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Text("Press the record button to start transcription")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
    // MARK: - Controls Section
    
    private var controlsSection: some View {
        HStack(spacing: 24) {
            // Timer (compact)
            Text(formattedDuration)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            
            Spacer()
            
            // Record/Pause/Resume button
            Button(action: toggleRecordingOrPause) {
                Circle()
                    .fill(recordButtonColor)
                    .frame(width: 48, height: 48)
                    .overlay {
                        recordButtonOverlay
                    }
                    .shadow(color: recordButtonColor.opacity(0.3), radius: lyricModeManager.isRecording ? 6 : 3)
            }
            .buttonStyle(.plain)
            .help(recordButtonHelp)
            
            Spacer()
            
            // Clear/Reset button (always visible, clears and resets)
            Button(action: clearAndReset) {
                Circle()
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
            }
            .buttonStyle(.plain)
            .disabled(transcriptSegments.isEmpty && !lyricModeManager.isRecording)
            .opacity(transcriptSegments.isEmpty && !lyricModeManager.isRecording ? 0.3 : 1)
            .help("Clear and Reset")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: lyricModeManager.isRecording)
        .animation(.easeInOut(duration: 0.2), value: isPaused)
    }
    
    // MARK: - Record Button Helpers
    
    private var recordButtonColor: Color {
        if isPaused {
            return Color.orange
        } else if lyricModeManager.isRecording {
            return Color.red
        } else {
            return Color.red.opacity(0.8)
        }
    }
    
    @ViewBuilder
    private var recordButtonOverlay: some View {
        if isPaused {
            // Resume icon (play triangle)
            Image(systemName: "play.fill")
                .font(.body)
                .foregroundColor(.white)
        } else if lyricModeManager.isRecording {
            // Pause icon (two bars)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 4, height: 16)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 4, height: 16)
            }
        }
        // When not recording: empty (just the red circle)
    }
    
    private var recordButtonHelp: String {
        if isPaused {
            return "Resume Recording"
        } else if lyricModeManager.isRecording {
            return "Pause Recording"
        } else {
            return "Start Recording"
        }
    }
    
    // MARK: - Helpers
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
    
    private var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let hundredths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
    
    // MARK: - Actions
    
    private func toggleRecordingOrPause() {
        Task {
            if isPaused {
                // Resume recording
                isPaused = false
                lyricModeManager.resumeRecording()
                startTimer()
            } else if lyricModeManager.isRecording {
                // Pause recording - finalize any partial text
                finalizePartialText()
                isPaused = true
                lyricModeManager.pauseRecording()
                stopTimer()
            } else {
                // Start new recording
                do {
                    isPaused = false
                    try await lyricModeManager.startRecording(with: whisperState)
                    subscribeToTranscription()
                    
                    // Show or hide overlay based on auto-show setting
                    if settings.autoShowOverlay {
                        if !lyricModeManager.isOverlayVisible {
                            lyricModeManager.showOverlay()
                        }
                    } else {
                        // Hide overlay if auto-show is disabled
                        if lyricModeManager.isOverlayVisible {
                            lyricModeManager.hideOverlay()
                        }
                    }
                } catch {
                    print("Failed to start recording: \(error)")
                }
            }
        }
    }
    
    private func stopRecording() {
        // Finalize any partial text before stopping
        finalizePartialText()
        // Permanently stop and save
        isPaused = false
        lyricModeManager.stopRecording()
    }
    
    /// Finalize partial text as an unfinished paragraph marked with asterisk
    private func finalizePartialText() {
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            // Mark as unfinished with asterisk
            let unfinishedText = partial + " *"
            transcriptSegments.append(unfinishedText)
            syncTranslatedSegmentsCount()
            translateSegment(at: transcriptSegments.count - 1, text: partial)
        }
        // Reset partial text storage
        partialText = ""
        lyricModeManager.partialText = ""
    }
    
    private func toggleOverlay() {
        lyricModeManager.toggleOverlay()
    }
    
    private func clearAndReset() {
        // Stop recording if active, clear content, return to initial state
        if lyricModeManager.isRecording || isPaused {
            lyricModeManager.stopRecording()
        }
        transcriptSegments = []
        translatedSegments = []
        translationService.clearHistory() // Clear AI context
        partialText = ""
        recordingDuration = 0
        isPaused = false
        lyricModeManager.clear()
        
        // Hide overlay when resetting
        if lyricModeManager.isOverlayVisible {
            lyricModeManager.hideOverlay()
        }
    }
    
    private func closeWindow() {
        if lyricModeManager.isRecording {
            lyricModeManager.stopRecording()
        }
        NSApplication.shared.keyWindow?.close()
    }
    
    private func startTimer() {
        recordingDuration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            recordingDuration += 0.01
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func subscribeToTranscription() {
        // Subscribe to transcription updates from the manager
        lyricModeManager.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [self] text in
                processNewTranscriptSegment(text)
            }
            .store(in: &cancellables)
        
        lyricModeManager.partialTranscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { text in
                partialText = text
            }
            .store(in: &cancellables)
    }
    
    /// Process a new transcript segment with overlap detection and sentence continuity
    private func processNewTranscriptSegment(_ text: String) {
        var trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // Remove overlap with existing content
        let existingText = transcriptSegments.joined(separator: " ")
        if let processedText = TranscriptTextProcessor.removeOverlap(from: trimmedText, existingText: existingText) {
            trimmedText = processedText
        } else {
            return // All content already exists
        }
        
        // Check for duplicates with last segment
        if let lastSegment = transcriptSegments.last {
            if TranscriptTextProcessor.isDuplicate(trimmedText, of: lastSegment) {
                return
            }
            // Handle cumulative update (new text extends last segment)
            if TranscriptTextProcessor.isCumulativeUpdate(trimmedText, of: lastSegment) {
                let lastIndex = transcriptSegments.count - 1
                transcriptSegments[lastIndex] = trimmedText
                // Re-translate the updated segment
                translateSegment(at: lastIndex, text: trimmedText)
                return
            }
        }
        
        // Handle sentence continuity - merge incomplete sentences (if enabled)
        if settings.sentenceContinuityEnabled, let lastIndex = transcriptSegments.indices.last {
            let previousSegment = transcriptSegments[lastIndex]
            
            if let (complete, incomplete) = TranscriptTextProcessor.extractIncompleteSentence(from: previousSegment) {
                // Update previous segment with complete part only
                transcriptSegments[lastIndex] = complete
                translateSegment(at: lastIndex, text: complete)
                // Prepend incomplete part to new segment
                let newText = incomplete + trimmedText
                transcriptSegments.append(newText)
                syncTranslatedSegmentsCount()
                translateSegment(at: transcriptSegments.count - 1, text: newText)
                return
            } else if !TranscriptTextProcessor.endsWithCompleteSentence(previousSegment) {
                // Entire previous segment is incomplete - merge
                let mergedText = previousSegment + trimmedText
                transcriptSegments[lastIndex] = mergedText
                translateSegment(at: lastIndex, text: mergedText)
                return
            }
        }
        
        // Normal case: append as new paragraph
        transcriptSegments.append(trimmedText)
        syncTranslatedSegmentsCount()
        translateSegment(at: transcriptSegments.count - 1, text: trimmedText)
    }
    
    /// Ensure translatedSegments array matches transcriptSegments count
    private func syncTranslatedSegmentsCount() {
        while translatedSegments.count < transcriptSegments.count {
            translatedSegments.append("")
        }
    }
    
    /// Translate a segment at the given index
    private func translateSegment(at index: Int, text: String) {
        guard settings.translationEnabled else { return }
        
        syncTranslatedSegmentsCount()
        
        Task {
            do {
                let translation = try await translationService.translate(text)
                await MainActor.run {
                    if index < translatedSegments.count {
                        translatedSegments[index] = translation
                    }
                }
            } catch {
                print("Translation error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Settings Popup

struct LyricModeSettingsPopup: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var whisperState: WhisperState
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @Environment(\.dismiss) private var dismiss
    
    // Whether recording is currently active
    var isRecording: Bool = false
    
    // Callback when settings are applied
    var onSettingsApplied: ((_ audioDeviceChanged: Bool, _ engineChanged: Bool) -> Void)?
    
    // Local state copies (changes are applied on Done)
    @State private var localEngineType: LyricModeEngineType = .appleSpeech
    @State private var localSelectedLanguage: String = "en-US"
    @State private var localSelectedModelName: String = ""
    @State private var localSelectedAudioDeviceUID: String = ""
    @State private var localFontSize: Double = 24
    @State private var localShowPartialHighlight: Bool = true
    @State private var localAutoShowOverlay: Bool = true
    @State private var localAppleSpeechMode: LyricModeSettings.AppleSpeechMode = .standard
    @State private var localBackgroundOpacity: Double = 0.8
    @State private var localIsClickThroughEnabled: Bool = false
    
    // AI Provider state
    @State private var localAIProvider: String = "ollama"
    @State private var localOllamaBaseURL: String = "http://localhost:11434"
    @State private var localSelectedOllamaModel: String = "mistral"
    @State private var ollamaModels: [OllamaService.OllamaModel] = []
    @State private var isCheckingOllama: Bool = false
    @State private var isEditingOllamaURL: Bool = false
    
    // Translation state
    @State private var localTranslationEnabled: Bool = false
    @State private var localTargetLanguage: String = "Vietnamese"
    
    // Sentence continuity state
    @State private var localSentenceContinuityEnabled: Bool = true
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    audioInputSection
                    
                    Divider()
                    
                    transcriptionSettingsSection
                    
                    Divider()
                    
                    appearanceSection
                    
                    Divider()
                    
                    behaviorSection
                    
                    Divider()
                    
                    aiProviderSection
                }
                .padding(24)
            }
            .frame(width: 450, height: 600)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") { applySettingsAndDismiss() }
                        .disabled(!hasChanges)
                }
            }
            .navigationTitle("Lyric Mode Settings")
        }
        .onAppear {
            // Initialize local state from current settings
            localEngineType = settings.engineType
            localSelectedLanguage = settings.selectedLanguage
            localSelectedModelName = settings.selectedModelName
            localSelectedAudioDeviceUID = settings.selectedAudioDeviceUID
            localFontSize = settings.fontSize
            localShowPartialHighlight = settings.showPartialHighlight
            localAutoShowOverlay = settings.autoShowOverlay
            localAppleSpeechMode = settings.appleSpeechMode
            localBackgroundOpacity = settings.backgroundOpacity
            localIsClickThroughEnabled = settings.isClickThroughEnabled
            
            // AI Provider
            localAIProvider = settings.aiProviderRaw
            localOllamaBaseURL = settings.ollamaBaseURL
            localSelectedOllamaModel = settings.selectedOllamaModel
            
            // Translation
            localTranslationEnabled = settings.translationEnabled
            localTargetLanguage = settings.targetLanguage
            
            // Sentence continuity
            localSentenceContinuityEnabled = settings.sentenceContinuityEnabled
        }
    }
    
    /// Check if any settings have been modified
    private var hasChanges: Bool {
        localEngineType != settings.engineType ||
        localSelectedLanguage != settings.selectedLanguage ||
        localSelectedModelName != settings.selectedModelName ||
        localSelectedAudioDeviceUID != settings.selectedAudioDeviceUID ||
        localFontSize != settings.fontSize ||
        localShowPartialHighlight != settings.showPartialHighlight ||
        localAutoShowOverlay != settings.autoShowOverlay ||
        localAppleSpeechMode != settings.appleSpeechMode ||
        localBackgroundOpacity != settings.backgroundOpacity ||
        localIsClickThroughEnabled != settings.isClickThroughEnabled ||
        localAIProvider != settings.aiProviderRaw ||
        localOllamaBaseURL != settings.ollamaBaseURL ||
        localSelectedOllamaModel != settings.selectedOllamaModel ||
        localTranslationEnabled != settings.translationEnabled ||
        localTargetLanguage != settings.targetLanguage ||
        localSentenceContinuityEnabled != settings.sentenceContinuityEnabled
    }
    
    private func applySettingsAndDismiss() {
        // Check what changed
        let audioDeviceChanged = localSelectedAudioDeviceUID != settings.selectedAudioDeviceUID
        let engineChanged = localEngineType != settings.engineType || 
                           localSelectedLanguage != settings.selectedLanguage ||
                           localSelectedModelName != settings.selectedModelName
        
        // Apply all settings
        settings.engineType = localEngineType
        settings.selectedLanguage = localSelectedLanguage
        settings.selectedModelName = localSelectedModelName
        settings.selectedAudioDeviceUID = localSelectedAudioDeviceUID
        settings.fontSize = localFontSize
        settings.showPartialHighlight = localShowPartialHighlight
        settings.autoShowOverlay = localAutoShowOverlay
        settings.appleSpeechMode = localAppleSpeechMode
        settings.backgroundOpacity = localBackgroundOpacity
        settings.isClickThroughEnabled = localIsClickThroughEnabled
        
        // AI Provider settings
        settings.aiProviderRaw = localAIProvider
        settings.ollamaBaseURL = localOllamaBaseURL
        settings.selectedOllamaModel = localSelectedOllamaModel
        
        // Translation settings
        settings.translationEnabled = localTranslationEnabled
        settings.targetLanguage = localTargetLanguage
        
        // Sentence continuity setting
        settings.sentenceContinuityEnabled = localSentenceContinuityEnabled
        
        // Notify about changes that need recording restart
        onSettingsApplied?(audioDeviceChanged, engineChanged)
        
        dismiss()
    }
    
    // MARK: - Audio Input
    
    private var audioInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Input")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Picker("Microphone", selection: $localSelectedAudioDeviceUID) {
                    Text("System Default")
                        .tag("")
                    ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                        Text(device.name)
                            .tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(isRecording)
                
                if isRecording {
                    Text("Stop recording to change audio input")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if !localSelectedAudioDeviceUID.isEmpty {
                    if let device = audioDeviceManager.availableDevices.first(where: { $0.uid == localSelectedAudioDeviceUID }) {
                        Text("Will use: \(device.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Will use system default input device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Transcription Settings
    
    private var transcriptionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription")
                .font(.headline)
            
            // Engine Type
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("Engine", selection: $localEngineType) {
                    ForEach(LyricModeEngineType.allCases) { type in
                        Label(type.rawValue, systemImage: type.icon)
                            .tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRecording)
                
                if isRecording {
                    Text("Stop recording to change engine")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Engine-specific configuration
            Group {
                switch localEngineType {
                case .whisper:
                    whisperConfigSection
                case .appleSpeech:
                    appleSpeechConfigSection
                case .cloud:
                    cloudConfigSection
                }
            }
            .padding(.top, 8)
            
            // Language (common to all engines)
            VStack(alignment: .leading, spacing: 8) {
                Text("Language")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("Language", selection: $localSelectedLanguage) {
                    Text("Auto Detect").tag("auto")
                    // Support both short codes and full locale codes
                    Text("English").tag("en")
                    Text("English").tag("en-US")
                    Text("Japanese").tag("ja")
                    Text("Japanese").tag("ja-JP")
                    Text("Chinese").tag("zh")
                    Text("Chinese").tag("zh-CN")
                    Text("Korean").tag("ko")
                    Text("Korean").tag("ko-KR")
                    Text("Vietnamese").tag("vi")
                    Text("Vietnamese").tag("vi-VN")
                }
                .labelsHidden()
            }
        }
    }
    
    // MARK: - Whisper Config
    
    private var whisperConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whisper Model")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Picker("Model", selection: $localSelectedModelName) {
                if whisperState.availableModels.isEmpty {
                    Text("No models available").tag("")
                } else {
                    ForEach(whisperState.availableModels, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
            }
            .labelsHidden()
            
            if whisperState.availableModels.isEmpty {
                Text("Download a model from AI Models section")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }
    
    // MARK: - Apple Speech Config
    
    private var appleSpeechConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if #available(macOS 26, *) {
                Text("Recognition Mode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("Mode", selection: $localAppleSpeechMode) {
                    ForEach(LyricModeSettings.AppleSpeechMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                
                Text(localAppleSpeechMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Using SFSpeechRecognizer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Cloud Config
    
    private var cloudConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud Model")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Picker("Model", selection: $settings.selectedCloudModelName) {
                Text("Select a model").tag("")
                // Add cloud models here if available
            }
            .labelsHidden()
            
            Text("Configure cloud API in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Appearance
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.headline)
            
            // Font Size
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font Size")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(localFontSize))pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $localFontSize, in: 14...48, step: 2)
            }
            
            // Background Opacity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Opacity")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(localBackgroundOpacity * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $localBackgroundOpacity, in: 0.3...1.0, step: 0.1)
            }
        }
    }
    
    // MARK: - Behavior
    
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Behavior")
                .font(.headline)
            
            Toggle("Auto-show overlay on recording", isOn: $localAutoShowOverlay)
            
            Toggle("Show partial results highlight", isOn: $localShowPartialHighlight)
            
            Toggle("Click-through overlay", isOn: $localIsClickThroughEnabled)
            
            Toggle("Merge incomplete sentences across paragraphs", isOn: $localSentenceContinuityEnabled)
                .help("When enabled, sentences without proper ending punctuation (。！？) are merged with the next paragraph")
        }
    }
    
    // MARK: - AI Provider Integration
    
    private var aiProviderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Provider Integration")
                .font(.headline)
            
            // Provider Picker
            HStack {
                Picker("Provider", selection: $localAIProvider) {
                    Text("Ollama").tag("ollama")
                }
                .pickerStyle(.automatic)
                
                Spacer()
                
                // Connection status
                if isCheckingOllama {
                    ProgressView()
                        .controlSize(.small)
                } else if !ollamaModels.isEmpty {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Disconnected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Ollama Server URL
            if isEditingOllamaURL {
                HStack {
                    TextField("Base URL", text: $localOllamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Save") {
                        settings.ollamaBaseURL = localOllamaBaseURL
                        checkOllamaConnection()
                        isEditingOllamaURL = false
                    }
                }
            } else {
                HStack {
                    Text("Server: \(localOllamaBaseURL)")
                        .font(.subheadline)
                    Spacer()
                    Button("Edit") { isEditingOllamaURL = true }
                    Button(action: {
                        localOllamaBaseURL = "http://localhost:11434"
                        settings.ollamaBaseURL = localOllamaBaseURL
                        checkOllamaConnection()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("Reset to default")
                }
            }
            
            // Model Picker
            if !ollamaModels.isEmpty {
                Divider()
                
                Picker("Model", selection: $localSelectedOllamaModel) {
                    ForEach(ollamaModels) { model in
                        Text(model.name).tag(model.name)
                    }
                }
            }
            
            Divider()
            
            // Translation Settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Translation", isOn: $localTranslationEnabled)
                
                if localTranslationEnabled {
                    HStack {
                        Text("Target Language")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Picker("Language", selection: $localTargetLanguage) {
                            Text("Vietnamese").tag("Vietnamese")
                            Text("Japanese").tag("Japanese")
                            Text("Korean").tag("Korean")
                            Text("Chinese").tag("Chinese")
                            Text("Spanish").tag("Spanish")
                            Text("French").tag("French")
                            Text("German").tag("German")
                            Text("Portuguese").tag("Portuguese")
                            Text("Russian").tag("Russian")
                            Text("English").tag("English")
                        }
                        .labelsHidden()
                    }
                    
                    Text("Each paragraph will be translated using the selected AI model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            checkOllamaConnection()
        }
    }
    
    private func checkOllamaConnection() {
        isCheckingOllama = true
        
        Task {
            do {
                let url = URL(string: "\(localOllamaBaseURL)/api/tags")!
                let (data, _) = try await URLSession.shared.data(from: url)
                
                struct OllamaTagsResponse: Codable {
                    let models: [OllamaService.OllamaModel]
                }
                
                let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                await MainActor.run {
                    ollamaModels = response.models
                    isCheckingOllama = false
                    
                    // Select first model if current selection is not available
                    // Also update settings to keep hasChanges accurate
                    if !ollamaModels.contains(where: { $0.name == localSelectedOllamaModel }) {
                        if let first = ollamaModels.first {
                            localSelectedOllamaModel = first.name
                            settings.selectedOllamaModel = first.name
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    ollamaModels = []
                    isCheckingOllama = false
                }
            }
        }
    }
}

// MARK: - Transcript Paragraph View

/// A view that displays a single transcript paragraph with improved readability
struct TranscriptParagraphView: View {
    let text: String
    let fontSize: CGFloat
    let isLatest: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Visual indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isLatest ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 3)
            
            // Text content
            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundColor(.primary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isLatest ? Color.accentColor.opacity(0.05) : Color.clear)
        )
    }
}
