import SwiftUI
import SwiftData

/// Settings view for configuring Lyric Mode appearance and behavior
struct LyricModeSettingsView: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    
    @State private var isStarting = false
    @State private var hoverEngine: LyricModeEngineType?
    
    // Teams Live Captions state
    @StateObject private var teamsService = TeamsLiveCaptionsService()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 32) {
                    // 1. Live Preview Section (Hero)
                    VStack(spacing: 16) {
                        Text("Live Preview")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                        
                        LyricPreviewView(settings: settings)
                            .frame(height: 140)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 24)
                    
                    // 2. Transcription Engine Selection
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Transcription Engine")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 24)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                Spacer().frame(width: 12) // Leading padding
                                ForEach(LyricModeEngineType.allCases) { type in
                                    EngineSelectionCard(
                                        type: type,
                                        isSelected: settings.engineType == type,
                                        action: { settings.engineType = type }
                                    )
                                }
                                Spacer().frame(width: 12) // Trailing padding
                            }
                        }
                    }
                    
                    // 3. Engine Specific Settings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Configuration")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 24)
                        
                        SettingsCard {
                            engineSpecificSettings
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // 4. Appearance & Behavior Grid
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Customization")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 24)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            // Appearance Card
                            SettingsCard(title: "Appearance", icon: "paintbrush") {
                                appearanceSettingsContent
                            }
                            
                            // Behavior Card
                            SettingsCard(title: "Behavior", icon: "gearshape.2") {
                                behaviorSettingsContent
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // Spacer for bottom bar
                    Spacer().frame(height: 100)
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            // 5. Floating Action Bar
            controlBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Control Bar
    
    private var controlBar: some View {
        HStack {
            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(lyricModeManager.isVisible ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: (lyricModeManager.isVisible ? Color.green : Color.red).opacity(0.5), radius: 4)
                
                Text(lyricModeManager.isVisible ? "Listening Active" : "Ready to Start")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            
            Spacer()
            
            if lyricModeManager.isVisible {
                Button(action: { lyricModeManager.clear() }) {
                    Label("Clear Text", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            Button(action: toggleLyricMode) {
                HStack(spacing: 8) {
                    if isStarting {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 16, height: 16)
                            .colorInvert()
                    } else {
                        Image(systemName: lyricModeManager.isVisible ? "stop.fill" : "play.fill")
                    }
                    Text(lyricModeManager.isVisible ? "Stop Recording" : "Start Recording")
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(lyricModeManager.isVisible ? .red : .accentColor)
            .disabled(isStarting)
        }
        .padding(24)
        .background(.regularMaterial)
        .overlay(Divider().frame(maxWidth: .infinity, maxHeight: 1), alignment: .top)
    }
    
    // MARK: - Transcription Settings
    
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
    
    @ViewBuilder
    private var engineSpecificSettings: some View {
        // Only Apple Speech engine is supported
        appleSpeechSettings
    }
    
    private var whisperSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Model Selection
            CustomPicker("Model", selection: $settings.selectedModelName) {
                if whisperState.availableModels.isEmpty {
                    Text("No models available").tag("")
                } else {
                    ForEach(whisperState.availableModels, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
            }
            .onAppear {
                if settings.selectedModelName.isEmpty, let first = whisperState.availableModels.first {
                    settings.selectedModelName = first.name
                }
            }
            
            Divider()
            
            // Audio Input
            CustomPicker("Microphone", selection: $settings.selectedAudioDeviceUID) {
                Text("System Default").tag("")
                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            
            Divider()
            
            // Language
            CustomPicker("Language", selection: $settings.selectedLanguage) {
                ForEach(availableLanguages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            
            Divider()
            
            // Advanced Toggle
            DisclosureGroup("Advanced Parameters") {
                VStack(spacing: 16) {
                    CustomSlider(
                        label: "Temperature",
                        value: $settings.temperature,
                        range: 0.0...1.0,
                        step: 0.05,
                        format: "%.2f"
                    )
                    
                    CustomSlider(
                        label: "Soft Timeout",
                        value: $settings.softTimeout,
                        range: 0.3...3.0,
                        step: 0.1,
                        format: "%.1fs"
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context Prompt")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("Technical terms, names...", text: $settings.whisperPrompt)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                    }
                }
                .padding(.top, 16)
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }
    
    private var cloudSettings: some View {
        VStack(spacing: 20) {
            let verifiedCloudModels = whisperState.usableModels.filter {
                [.groq, .deepgram, .elevenLabs, .mistral, .gemini, .soniox, .custom].contains($0.provider)
            }
            
            if verifiedCloudModels.isEmpty {
                Text("No verified cloud models available. Please configure them in settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                CustomPicker("Cloud Model", selection: $settings.selectedCloudModelName) {
                    ForEach(verifiedCloudModels, id: \.name) { model in
                        Text(model.displayName).tag(model.name)
                    }
                }
                .onAppear {
                    if settings.selectedCloudModelName.isEmpty, let first = verifiedCloudModels.first {
                        settings.selectedCloudModelName = first.name
                    }
                }
            }
            
            Text("Cloud transcription requires an active internet connection and API key.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private var appleSpeechSettings: some View {
        VStack(spacing: 20) {
            if #available(macOS 26, *) {
                // Using picker directly for simplicity in custom views
                HStack {
                    Text("Recognition Mode")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $settings.appleSpeechMode) {
                        ForEach(LyricModeSettings.AppleSpeechMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                
                Divider()
                
                // Speaker Diarization Toggle
                CustomToggle(
                    title: "Speaker Diarization",
                    subtitle: "Identify and label different speakers (experimental)",
                    isOn: $settings.speakerDiarizationEnabled
                )
                
                Divider()
                
                Text(settings.appleSpeechMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Standard on-device speech recognition.")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var teamsLiveCaptionsSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Permissions
            HStack {
                Text("Accessibility Access")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if TeamsLiveCaptionsService.isAccessibilityEnabled() {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        TeamsLiveCaptionsService.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            Divider()
            
            // Window Selector
            HStack {
                Text("Target Window")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                
                HStack {
                    if teamsService.availableTeamsProcesses.isEmpty {
                        Text("No Teams found").foregroundColor(.secondary).italic().font(.caption)
                    } else {
                        Picker("", selection: $teamsService.selectedProcessPID) {
                            Text("Select Window").tag(nil as pid_t?)
                            ForEach(teamsService.availableTeamsProcesses) { process in
                                Text(process.displayName).tag(process.pid as pid_t?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    
                    Button(action: { Task { await teamsService.refreshTeamsProcesses() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            
            if let error = teamsService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    private var appearanceSettingsContent: some View {
        VStack(spacing: 20) {
            CustomSlider(
                label: "Font Size",
                value: $settings.fontSize,
                range: 12...64,
                step: 2,
                format: "%.0f pt"
            )
            
            CustomSlider(
                label: "Visible Lines",
                value: Binding(get: { Double(settings.maxVisibleLines) }, set: { settings.maxVisibleLines = Int($0) }),
                range: 1...10,
                step: 1,
                format: "%.0f"
            )
            
            CustomSlider(
                label: "Opacity",
                value: $settings.backgroundOpacity,
                range: 0.1...1.0,
                step: 0.1,
                format: "%.0f%%",
                displayMultiplier: 100
            )
        }
    }
    
    private var behaviorSettingsContent: some View {
        VStack(spacing: 16) {
            CustomToggle(
                title: "Click-Through",
                subtitle: "Ignore mouse clicks on overlay",
                isOn: $settings.isClickThroughEnabled
            )
            .onChange(of: settings.isClickThroughEnabled) { _, newValue in
                lyricModeManager.updateClickThrough(newValue)
            }
            
            Divider()
            
            CustomToggle(
                title: "Partial Highlight",
                subtitle: "Colorize incoming text",
                isOn: $settings.showPartialHighlight
            )
            
            Divider()
            
            CustomToggle(
                title: "Live Translation",
                subtitle: "Translate sentences instantly",
                isOn: $settings.translateImmediately
            )
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
                    try await lyricModeManager.show()
                }
            } catch {
                print("Failed to toggle Lyric Mode: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Components

struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var content: Content
    
    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title = title {
                HStack(spacing: 8) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .foregroundColor(.accentColor)
                    }
                    Text(title)
                        .font(.headline)
                }
                .padding(.bottom, 4)
            }
            
            content
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct EngineSelectionCard: View {
    let type: LyricModeEngineType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: type.icon)
                        .font(.title2)
                        .foregroundColor(isSelected ? .white : .accentColor)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                    }
                }
                
                Spacer()
                
                Text(type.rawValue)
                    .font(.headline)
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text(type.description)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 160, height: 140)
            .background(
                ZStack {
                    if isSelected {
                        Color.accentColor
                    } else {
                        Color(NSColor.controlBackgroundColor)
                    }
                }
            )
            .cornerRadius(16)
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
                radius: isHovering ? 8 : 4,
                y: isHovering ? 4 : 2
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct LyricPreviewView: View {
    @ObservedObject var settings: LyricModeSettings
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(settings.backgroundOpacity))
                .shadow(radius: 10)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text("Simulated previous line")
                    .foregroundColor(.white.opacity(0.6))
                
                Text("This is how your text will look")
                    .foregroundColor(.white)
                    .fontWeight(.bold)
                
                Text("Real-time transcription preview")
                    .foregroundColor(settings.showPartialHighlight ? .cyan : .white.opacity(0.8))
            }
            .font(.system(size: settings.fontSize * 0.8)) // Scale down slightly for preview fits
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct CustomSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var displayMultiplier: Double = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value * displayMultiplier))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            
            Slider(value: $value, in: range, step: step)
                .tint(.accentColor)
        }
    }
}

struct CustomPicker<Content: View>: View {
    let label: String
    @Binding var selection: String
    let content: Content
    
    init(_ label: String, selection: Binding<String>, @ViewBuilder content: () -> Content) {
        self.label = label
        self._selection = selection
        self.content = content()
    }
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: $selection) {
                content
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        }
    }
}

struct CustomToggle: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
    }
}

// MARK: - WhisperKit Settings (Preserved functionality)

struct WhisperKitSettingsSection: View {
    @ObservedObject var settings: LyricModeSettings
    @StateObject private var modelManager = WhisperKitModelManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: WhisperKitModelInfo?
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header Action
            HStack {
                Text("Model Manager")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: { Task { await modelManager.fetchAvailableModels(from: settings.whisperKitModelRepo) } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(modelManager.isLoadingModels)
            }
            
            // Tab Picker
            Picker("", selection: $selectedTab) {
                Text("Downloaded (\(modelManager.downloadedModels.count))").tag(0)
                Text("Available").tag(1)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTab) { _, newValue in
                if newValue == 1 && modelManager.availableModels.isEmpty {
                    Task { await modelManager.fetchAvailableModels(from: settings.whisperKitModelRepo) }
                }
            }
            
            // Content
            Group {
                if selectedTab == 0 {
                    downloadedModelsList
                } else {
                    availableModelsList
                }
            }
            .frame(height: 200)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            )
            
            if let error = modelManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).font(.caption).foregroundColor(.orange)
                    Spacer()
                    Button("Dismiss") { modelManager.errorMessage = nil }.font(.caption)
                }
            }
        }
        .onAppear { modelManager.loadDownloadedModels() }
        .alert("Delete Model?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    modelManager.deleteModel(model.name)
                    if settings.selectedWhisperKitModel == model.name { settings.selectedWhisperKitModel = "" }
                }
            }
        } message: {
            if let model = modelToDelete {
                Text("Delete \(model.name)? Frees \(model.sizeString).")
            }
        }
    }
    
    private var downloadedModelsList: some View {
        VStack {
            if modelManager.downloadedModels.isEmpty {
                ContentUnavailableView("No Models Downloaded", systemImage: "tray", description: Text("Download a model from the Available tab"))
            } else {
                List(selection: $settings.selectedWhisperKitModel) {
                    ForEach(modelManager.downloadedModels) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(model.name).fontWeight(.medium)
                                    if model.isRecommended { Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption) }
                                }
                                Text(model.sizeString).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if settings.selectedWhisperKitModel == model.name {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                            Button(action: { modelToDelete = model; showingDeleteConfirmation = true }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .tag(model.name)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.selectedWhisperKitModel = model.name
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    private var availableModelsList: some View {
        VStack {
            if modelManager.isLoadingModels {
                ProgressView("Loading available models...")
            } else if modelManager.availableModels.isEmpty {
                ContentUnavailableView("No Connection", systemImage: "wifi.slash", description: Text("Could not fetch models"))
            } else {
                List {
                    ForEach(modelManager.availableModels, id: \.self) { modelName in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(modelName).fontWeight(.medium)
                                if modelName == modelManager.recommendedModel {
                                    Text("Recommended").font(.caption).foregroundColor(.green)
                                }
                            }
                            Spacer()
                            
                            if modelManager.isModelDownloaded(modelName) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            } else if modelManager.downloadingModels.contains(modelName) {
                                ProgressView().scaleEffect(0.5)
                            } else {
                                Button("Get") {
                                    Task { try? await modelManager.downloadModel(modelName, from: settings.whisperKitModelRepo) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
