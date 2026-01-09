import SwiftUI
import SwiftData

/// Settings view for configuring Lyric Mode appearance and behavior
struct LyricModeSettingsView: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    
    @State private var isStarting = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection
                
                Divider()
                
                // Control Section
                controlSection
                
                Divider()
                
                // Transcription Settings (Lyrics-specific)
                transcriptionSettingsSection
                
                Divider()
                
                // Appearance Settings
                appearanceSection
                
                Divider()
                
                // Behavior Settings
                behaviorSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lyric Mode")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Real-time transcription overlay")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Text("Display your speech as text in real-time with a floating overlay. Perfect for presentations, meetings, or accessibility.")
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }
    
    // MARK: - Control Section
    
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Controls")
                .font(.headline)
            
            HStack(spacing: 16) {
                // Start/Stop Button
                Button(action: toggleLyricMode) {
                    HStack(spacing: 8) {
                        if isStarting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: lyricModeManager.isVisible ? "stop.fill" : "play.fill")
                        }
                        Text(lyricModeManager.isVisible ? "Stop Lyric Mode" : "Start Lyric Mode")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(lyricModeManager.isVisible ? .red : .blue)
                .disabled(isStarting || selectedModel == nil)
                
                // Clear Button
                if lyricModeManager.isVisible {
                    Button(action: { lyricModeManager.clear() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(lyricModeManager.isVisible ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                
                Text(lyricModeManager.isVisible ? "Listening..." : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if whisperState.availableModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("No local models available. Please download a model first.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
    
    // MARK: - Transcription Settings Section
    
    /// The currently selected model for Lyrics mode
    private var selectedModel: WhisperModel? {
        if settings.selectedModelName.isEmpty {
            return whisperState.availableModels.first
        }
        return whisperState.availableModels.first { $0.name == settings.selectedModelName }
    }
    
    /// Available languages for the selected model (Whisper supports these)
    private var availableLanguages: [(code: String, name: String)] {
        [
            ("auto", "Auto Detect"),
            ("en", "English"),
            ("zh", "Chinese"),
            ("de", "German"),
            ("es", "Spanish"),
            ("ru", "Russian"),
            ("ko", "Korean"),
            ("fr", "French"),
            ("ja", "Japanese"),
            ("pt", "Portuguese"),
            ("tr", "Turkish"),
            ("pl", "Polish"),
            ("ca", "Catalan"),
            ("nl", "Dutch"),
            ("ar", "Arabic"),
            ("sv", "Swedish"),
            ("it", "Italian"),
            ("id", "Indonesian"),
            ("hi", "Hindi"),
            ("fi", "Finnish"),
            ("vi", "Vietnamese"),
            ("he", "Hebrew"),
            ("uk", "Ukrainian"),
            ("el", "Greek"),
            ("ms", "Malay"),
            ("cs", "Czech"),
            ("ro", "Romanian"),
            ("da", "Danish"),
            ("hu", "Hungarian"),
            ("ta", "Tamil"),
            ("no", "Norwegian"),
            ("th", "Thai")
        ]
    }
    
    private var transcriptionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Transcription Settings")
                .font(.headline)
            
            // Engine Type Picker
            VStack(spacing: 12) {
                HStack {
                    Label("Engine", systemImage: "gearshape.2")
                        .foregroundColor(.primary)
                        .frame(width: 120, alignment: .leading)
                    
                    Spacer()
                    
                    Picker("Engine", selection: $settings.engineType) {
                        ForEach(LyricModeEngineType.allCases) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                
                Text(settings.engineType.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // Model & Audio Input Group
            VStack(spacing: 12) {
                // Model Row - conditional based on engine type
                if settings.engineType == .whisper {
                    HStack {
                        Label("Model", systemImage: "cpu")
                            .foregroundColor(.primary)
                            .frame(width: 120, alignment: .leading)
                        
                        Spacer()
                        
                        if whisperState.availableModels.isEmpty {
                            Text("No models")
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Model", selection: $settings.selectedModelName) {
                                ForEach(whisperState.availableModels, id: \.name) { model in
                                    Text(model.name).tag(model.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 200)
                            .onAppear {
                                if settings.selectedModelName.isEmpty, let first = whisperState.availableModels.first {
                                    settings.selectedModelName = first.name
                                }
                            }
                        }
                    }
                } else if settings.engineType == .cloud {
                    HStack {
                        Label("Cloud Model", systemImage: "cloud")
                            .foregroundColor(.primary)
                            .frame(width: 120, alignment: .leading)
                        
                        Spacer()
                        
                        let verifiedCloudModels = whisperState.usableModels.filter { 
                            [.groq, .deepgram, .elevenLabs, .mistral, .gemini, .soniox, .custom].contains($0.provider)
                        }
                        
                        if verifiedCloudModels.isEmpty {
                            Text("No verified models")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            Picker("Cloud Model", selection: $settings.selectedCloudModelName) {
                                ForEach(verifiedCloudModels, id: \.name) { model in
                                    Text(model.displayName).tag(model.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 200)
                            .onAppear {
                                if settings.selectedCloudModelName.isEmpty, let first = verifiedCloudModels.first {
                                    settings.selectedCloudModelName = first.name
                                }
                            }
                        }
                    }
                } else {
                    // Apple Speech - no model selection needed
                    HStack {
                        Label("Model", systemImage: "apple.logo")
                            .foregroundColor(.primary)
                            .frame(width: 120, alignment: .leading)
                        
                        Spacer()
                        
                        Text("Apple Speech Recognition")
                            .foregroundColor(.secondary)
                    }
                }
                
                // Audio Input Row
                HStack {
                    Label("Audio Input", systemImage: "mic")
                        .foregroundColor(.primary)
                        .frame(width: 120, alignment: .leading)
                    
                    Spacer()
                    
                    Picker("Audio Input", selection: $settings.selectedAudioDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                
                // Language Row
                HStack {
                    Label("Language", systemImage: "globe")
                        .foregroundColor(.primary)
                        .frame(width: 120, alignment: .leading)
                    
                    Spacer()
                    
                    Picker("Language", selection: $settings.selectedLanguage) {
                        ForEach(availableLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // Advanced Settings Group - Only for Whisper engine
            if settings.engineType == .whisper {
                VStack(spacing: 16) {
                    // Temperature
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Temperature", systemImage: "thermometer.medium")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(String(format: "%.2f", settings.temperature))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        
                        Slider(value: $settings.temperature, in: 0.0...1.0, step: 0.05)
                        
                        Text("Lower = deterministic, Higher = varied")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Beam Size
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Beam Size", systemImage: "arrow.triangle.branch")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(settings.beamSize)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        
                        Picker("", selection: $settings.beamSize) {
                            Text("1 (Fast)").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("5 (Quality)").tag(5)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    
                    Divider()
                    
                    // Soft Timeout (Pause Duration)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Soft Timeout", systemImage: "pause.circle")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(String(format: "%.1fs", settings.softTimeout))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        
                        Slider(value: $settings.softTimeout, in: 0.3...3.0, step: 0.1)
                        
                        Text("Time to wait when silence is detected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Hard Timeout
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Hard Timeout", systemImage: "exclamationmark.circle")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(String(format: "%.1fs", settings.hardTimeout))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        
                        Slider(value: $settings.hardTimeout, in: 1.0...10.0, step: 0.5)
                        
                        Text("Force break even with background noise")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Whisper Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Prompt", systemImage: "text.quote")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        
                        TextField("e.g., Technical terms, names...", text: $settings.whisperPrompt)
                            .textFieldStyle(.roundedBorder)
                        
                        Text("Guide transcription with context, vocabulary, or style hints")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Appearance Section
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.headline)
            
            // Max Visible Lines
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Visible Lines")
                    Spacer()
                    Text("\(settings.maxVisibleLines)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Slider(
                    value: Binding(
                        get: { Double(settings.maxVisibleLines) },
                        set: { settings.maxVisibleLines = Int($0) }
                    ),
                    in: 3...10,
                    step: 1
                )
            }
            
            // Font Size
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Slider(
                    value: $settings.fontSize,
                    in: 12...48,
                    step: 2
                )
            }
            
            // Background Opacity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Opacity")
                    Spacer()
                    Text("\(Int(settings.backgroundOpacity * 100))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Slider(
                    value: $settings.backgroundOpacity,
                    in: 0.3...1.0,
                    step: 0.1
                )
            }
        }
    }
    
    // MARK: - Behavior Section
    
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Behavior")
                .font(.headline)
            
            Toggle(isOn: $settings.isClickThroughEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Click-Through Mode")
                    Text("Allow clicks to pass through the overlay to apps behind it")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: settings.isClickThroughEnabled) { _, newValue in
                lyricModeManager.updateClickThrough(newValue)
            }
            
            Toggle(isOn: $settings.showPartialHighlight) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlight Partial Text")
                    Text("Show in-progress transcription in a different color")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func toggleLyricMode() {
        Task {
            isStarting = true
            defer { isStarting = false }
            
            do {
                if lyricModeManager.isVisible {
                    lyricModeManager.hide()
                } else {
                    switch settings.engineType {
                    case .whisper:
                        guard let model = selectedModel else { return }
                        
                        // Create whisper context from Lyrics-specific model
                        let context = try await WhisperContext.createContext(path: model.url.path)
                        
                        // Set language override for Lyrics mode
                        let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage
                        await context.setLanguageOverride(language)
                        
                        // Set temperature and beam size overrides
                        await context.setTemperatureOverride(Float(settings.temperature))
                        if settings.beamSize > 1 {
                            await context.setBeamSizeOverride(Int32(settings.beamSize))
                        }
                        
                        // Set whisper prompt if provided
                        if !settings.whisperPrompt.isEmpty {
                            await context.setPrompt(settings.whisperPrompt)
                        }
                        
                        try await lyricModeManager.show(with: context)
                        
                    case .appleSpeech:
                        try await lyricModeManager.showWithAppleSpeech()
                        
                    case .cloud:
                        // Cloud models use the same Whisper infrastructure but with cloud transcription
                        // For now, show an alert that cloud is not yet supported in Lyric Mode
                        // TODO: Implement cloud streaming when API supports it
                        print("Cloud transcription in Lyric Mode not yet implemented")
                    }
                }
            } catch {
                print("Failed to toggle Lyric Mode: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Preview

// Preview requires a WhisperState with proper ModelContext, so we skip the live preview
// #Preview {
//     LyricModeSettingsView(...)
// }
