import SwiftUI
import Combine

/// Main view for Lyric Mode with Notes-style inline transcription
struct LyricModeMainView: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    
    @State private var showingSettings = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var transcriptText: String = ""
    @State private var partialText: String = ""
    @State private var translatedText: String = ""
    @State private var timer: Timer?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isPaused = false
    @State private var isTranslateEnabled = false
    
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
            LyricModeSettingsPopup(settings: settings, whisperState: whisperState)
        }
        .onChange(of: lyricModeManager.isRecording) { _, isRecording in
            if isRecording {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lyric Mode")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                // Current settings info
                HStack(spacing: 8) {
                    Label(settings.engineType.rawValue, systemImage: settings.engineType.icon)
                    Text("•")
                    Text(settings.selectedLanguage == "auto" ? "Auto" : settings.selectedLanguage.uppercased())
                }
                .font(.caption)
                .foregroundColor(.secondary)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if transcriptText.isEmpty && partialText.isEmpty && !lyricModeManager.isRecording {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if !transcriptText.isEmpty {
                                Text(transcriptText)
                                    .font(.system(size: settings.fontSize))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            
                            if !partialText.isEmpty {
                                Text(partialText)
                                    .font(.system(size: settings.fontSize))
                                    .foregroundColor(.cyan)
                                    .id("partial")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
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
                .frame(width: 80)
            
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
            .disabled(transcriptText.isEmpty && !lyricModeManager.isRecording)
            .opacity(transcriptText.isEmpty && !lyricModeManager.isRecording ? 0.3 : 1)
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
                // Pause recording
                isPaused = true
                lyricModeManager.pauseRecording()
                stopTimer()
            } else {
                // Start new recording
                do {
                    isPaused = false
                    try await lyricModeManager.startRecording(with: whisperState)
                    subscribeToTranscription()
                    
                    // Show overlay if enabled
                    if lyricModeManager.isOverlayVisible == false {
                        lyricModeManager.showOverlay()
                    }
                } catch {
                    print("Failed to start recording: \(error)")
                }
            }
        }
    }
    
    private func stopRecording() {
        // Permanently stop and save
        isPaused = false
        lyricModeManager.stopRecording()
    }
    
    private func toggleOverlay() {
        lyricModeManager.toggleOverlay()
    }
    
    private func clearAndReset() {
        // Stop recording if active, clear content, return to initial state
        if lyricModeManager.isRecording || isPaused {
            lyricModeManager.stopRecording()
        }
        transcriptText = ""
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
            .sink { text in
                transcriptText += text + " "
            }
            .store(in: &cancellables)
        
        lyricModeManager.partialTranscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { text in
                partialText = text
            }
            .store(in: &cancellables)
    }
}

// MARK: - Settings Popup

struct LyricModeSettingsPopup: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var whisperState: WhisperState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    transcriptionSettingsSection
                    
                    Divider()
                    
                    appearanceSection
                    
                    Divider()
                    
                    behaviorSection
                }
                .padding(24)
            }
            .frame(width: 450, height: 500)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Lyric Mode Settings")
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
                
                Picker("Engine", selection: $settings.engineType) {
                    ForEach(LyricModeEngineType.allCases) { type in
                        Label(type.rawValue, systemImage: type.icon)
                            .tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            // Engine-specific configuration
            Group {
                switch settings.engineType {
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
                
                Picker("Language", selection: $settings.selectedLanguage) {
                    Text("Auto Detect").tag("auto")
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Vietnamese").tag("vi")
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
            
            Picker("Model", selection: $settings.selectedModelName) {
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
                
                Picker("Mode", selection: $settings.appleSpeechMode) {
                    ForEach(LyricModeSettings.AppleSpeechMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                
                Text(settings.appleSpeechMode.description)
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
                    
                    Text("\(Int(settings.fontSize))pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $settings.fontSize, in: 14...48, step: 2)
            }
            
            // Background Opacity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Opacity")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(settings.backgroundOpacity * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $settings.backgroundOpacity, in: 0.3...1.0, step: 0.1)
            }
        }
    }
    
    // MARK: - Behavior
    
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Behavior")
                .font(.headline)
            
            Toggle("Show partial results highlight", isOn: $settings.showPartialHighlight)
            
            Toggle("Click-through overlay", isOn: $settings.isClickThroughEnabled)
        }
    }
}
