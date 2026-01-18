import SwiftUI
import SwiftData
import Combine

/// Main view for Lyric Mode with Notes-style inline transcription
struct LyricModeMainView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    
    @State private var showingSettings = false
    // Generic Toast State
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = ""
    @State private var toastColor: Color = .green
    @State private var translatedText: String = ""
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isPaused = false

    @State private var shouldAutoScroll = true
    @State private var lastAutoScrollTime = Date.distantPast
    @State private var lastDataUpdateTime = Date.distantPast
    
    // Teams Live Captions window selection
    @State private var showingWindowSelection = false
    @StateObject private var teamsService = TeamsLiveCaptionsService()
    
    // Segment management
    @State private var ignoredSegments: Set<Int> = []
    
    // Track segments created by Live Translation mode to avoid duplicates
    @State private var liveTranslationCreatedSegments: Set<String> = []

    
    private let translationService = LyricModeTranslationService()
    
    // Convenience accessors for manager's content state

    private var transcriptSegments: [String] {
        get { lyricModeManager.transcriptSegments }
        nonmutating set { lyricModeManager.transcriptSegments = newValue }
    }
    
    private var translatedSegments: [String] {
        get { lyricModeManager.translatedSegments }
        nonmutating set { lyricModeManager.translatedSegments = newValue }
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
        .overlay(alignment: .bottom) {

            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: toastIcon)
                        .foregroundColor(toastColor)
                    Text(toastMessage)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .cornerRadius(20)
                .shadow(radius: 4)
                .padding(.bottom, 80) // Above control bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showToast = false
                        }
                    }
                }
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
        .sheet(isPresented: $showingWindowSelection) {
            WindowSelectionSheet(
                windows: teamsService.availableWindows,
                onRefresh: { teamsService.refreshAvailableWindows() },
                onSelect: { window in
                    showingWindowSelection = false
                    teamsService.selectedProcessPID = window.pid
                    teamsService.selectedWindowTitle = window.windowTitle
                    settings.teamsSelectedPID = Int(window.pid)
                    settings.teamsSelectedWindowTitle = window.windowTitle
                    // Start recording
                    Task {
                        await startRecordingAfterWindowSelection()
                    }
                },
                onCancel: {
                    showingWindowSelection = false
                }
            )
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
            Button(action: { settings.translationEnabled.toggle() }) {
                Image(systemName: settings.translationEnabled ? "character.book.closed.fill" : "character.book.closed")
                    .font(.title3)
                    .foregroundColor(settings.translationEnabled ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(settings.translationEnabled ? "Hide Translation" : "Show Translation")
            
            // Overlay toggle
            Button(action: { lyricModeManager.toggleOverlay() }) {
                Image(systemName: lyricModeManager.isOverlayVisible ? "text.bubble.fill" : "text.bubble")
                    .font(.title3)
                    .foregroundColor(lyricModeManager.isOverlayVisible ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(lyricModeManager.isOverlayVisible ? "Hide Overlay" : "Show Overlay")
            
            // History button
            Button(action: {
                LyricHistoryWindowController.shared.showHistoryWindow(modelContext: modelContext)
            }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("History")
            
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
        // Single view with inline translation support
        speechContentView
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: settings.translationEnabled)
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
                            // Display each transcript segment as a paragraph
                            ForEach(0..<transcriptSegments.count, id: \.self) { index in
                                let segment = transcriptSegments[index]
                                SegmentRowView(
                                    index: index,
                                    segment: segment,
                                    translation: index < translatedSegments.count ? translatedSegments[index] : "",
                                    fontSize: settings.fontSize,
                                    isLatest: index == transcriptSegments.count - 1 && partialText.isEmpty,
                                    isIgnored: ignoredSegments.contains(index),
                                    translationEnabled: settings.translationEnabled,
                                    onCopy: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(segment, forType: .string)
                                        showToastMessage("Copied to clipboard", icon: "doc.on.doc", color: .blue)
                                    },
                                    onRetranslate: {
                                        retranslateSegment(at: index, text: segment)
                                    },
                                    onToggleIgnore: {
                                        if ignoredSegments.contains(index) {
                                            ignoredSegments.remove(index)
                                            showToastMessage("Segment restored", icon: "eye", color: .green)
                                        } else {
                                            ignoredSegments.insert(index)
                                            showToastMessage("Segment ignored", icon: "eye.slash", color: .orange)
                                        }
                                    }
                                )
                                .equatable() // Explicitly enable Equatable check
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
                                }
                                .onDisappear {
                                    // Robust check: Only disable if it wasn't our own auto-scroll (within last 0.5s)
                                    // AND not caused by a data update pushing content (within last 0.5s)
                                    let now = Date()
                                    let timeSinceScroll = now.timeIntervalSince(lastAutoScrollTime)
                                    let timeSinceData = now.timeIntervalSince(lastDataUpdateTime)
                                    
                                    if timeSinceScroll > 0.5 && timeSinceData > 0.5 {
                                        shouldAutoScroll = false
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
                .onChange(of: transcriptSegments.count) { _, _ in
                    lastDataUpdateTime = Date()
                    if shouldAutoScroll {
                        lastAutoScrollTime = Date()
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: partialText) { _, _ in
                    lastDataUpdateTime = Date()
                    if shouldAutoScroll {
                        lastAutoScrollTime = Date()
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // Resume Auto-Scroll Button
                if !shouldAutoScroll && (!transcriptSegments.isEmpty || !partialText.isEmpty) {
                    Button(action: {
                        shouldAutoScroll = true
                        lastAutoScrollTime = Date()
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
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
        ZStack {
            // Timer (align to leading)
            HStack {
                Text(formattedDuration)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            .padding(.horizontal, 20)
            
            // Buttons (centered)
            HStack(spacing: 32) {
                // Discard Button (X Mark)
                Button(action: discardAndQuit) {
                    Circle()
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "xmark")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                }
                .buttonStyle(.plain)
                .disabled(transcriptSegments.isEmpty && !lyricModeManager.isRecording)
                .opacity(transcriptSegments.isEmpty && !lyricModeManager.isRecording ? 0.3 : 1)
                .help("Discard and Quit (Do not save)")
                
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
                .disabled(isDiscarding)
                .opacity(isDiscarding ? 0.5 : 1.0)
                .help(recordButtonHelp)
                
                // Clear/Reset button (Checkmark)
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
        }
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
            } else if lyricModeManager.isRecording {
                // Pause recording - finalize any partial text
                finalizePartialText()
                isPaused = true
                lyricModeManager.pauseRecording()
            } else {
                // Start new recording
                
                await startRecordingAfterWindowSelection()
            }
        }
    }
    
    /// Start recording (called after window selection for Teams, or directly for other engines)
    private func startRecordingAfterWindowSelection() async {
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
    
    private func stopRecording() {
        // Cancel any pending translation requests immediately
        Task {
            await translationService.cancelPendingRequests()
        }
        
        saveCurrentSession()
        
        // Permanently stop
        isPaused = false
        lyricModeManager.stopRecording()
    }
    
    private func saveCurrentSession() {
        // Finalize any partial text before saving
        finalizePartialText()
        
        // Save Session if there's content
        if !transcriptSegments.isEmpty {
            let session = LyricSession(
                id: UUID(),
                timestamp: Date(),
                duration: lyricModeManager.recordingDuration,
                transcriptSegments: transcriptSegments,
                translatedSegments: translatedSegments,
                audioFilePath: nil, // Future: Add audio file path
                targetLanguage: settings.targetLanguage,
                title: Date().formatted(date: .numeric, time: .shortened)
            )
            
            modelContext.insert(session)
            print("Session saved to SwiftData: \(session.title)")
            
            // Show toast
            toastMessage = "Session Saved"
            toastIcon = "checkmark.circle.fill"
            toastColor = .green
            withAnimation {
                showToast = true
            }
        }
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
        // Save current session before clearing
        saveCurrentSession()
        
        // Stop recording if active, clear content, return to initial state
        resetState()
    }
    
    @State private var isDiscarding = false
    
    private func discardAndQuit() {
        guard !isDiscarding else { return }
        isDiscarding = true
        
        // Use a task to handle graceful cleanup sequence
        Task {
            // 1. Reset state (stops processes, clears data)
            await MainActor.run { resetState() }
            
            // 2. Show feedback
            await MainActor.run {
                toastMessage = "Session Discarded"
                toastIcon = "trash.fill"
                toastColor = .red
                withAnimation { showToast = true }
            }
            
            // 3. Wait for cleanup to settle (prevents rapid-restart races)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // 4. Re-enable UI
            await MainActor.run { isDiscarding = false }
        }
    }
    
    private func resetState() {
        if lyricModeManager.isRecording || isPaused {
            lyricModeManager.stopRecording()
        }
        transcriptSegments = []
        translatedSegments = []
        // Cancel translations
        Task {
             await translationService.cancelPendingRequests()
        }
        translationService.clearHistory()
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
    

    
    private func subscribeToTranscription() {
        // Subscribe to transcription updates from the manager
        lyricModeManager.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [self] text in
                // Skip if this segment was already created by Live Translation mode
                if settings.translateImmediately && liveTranslationCreatedSegments.contains(text) {
                    // Already processed by live translation, just update if needed
                    if let existingIndex = transcriptSegments.firstIndex(where: { 
                        TranscriptTextProcessor.similarityRatio($0, text) > 0.7 
                    }) {
                        // Replace with the final version (more accurate)
                        transcriptSegments[existingIndex] = text
                        translateSegment(at: existingIndex, text: text)
                    }
                    return
                }
                processNewTranscriptSegment(text)
            }
            .store(in: &cancellables)
        
        lyricModeManager.partialTranscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [self] text in
                if settings.translateImmediately {
                   processLiveTranslation(from: text)
                }
                
                // Update partial text display, filtering out already confirmed segments
                let allConfirmed = transcriptSegments.joined(separator: " ")
                if let uniquePartial = TranscriptTextProcessor.removeOverlap(from: text, existingText: allConfirmed) {
                    partialText = uniquePartial
                } else {
                    partialText = "" // Fully overlapped/confirmed
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to transcript segments for display
        lyricModeManager.$transcriptSegments
            .receive(on: DispatchQueue.main)
            .removeDuplicates() // Prevent cascade updates for same content
            .sink { [self] segments in
                // Sync local transcriptSegments with manager
                transcriptSegments = segments
                syncTranslatedSegmentsCount()
            }
            .store(in: &cancellables)
    }
    
    private func processLiveTranslation(from text: String) {
        // Extract complete sentences from the partial text
        let sentences = extractSentences(from: text)
        for sentence in sentences {
            // Check if this sentence is already at the end of our transcript
            if let lastSegment = transcriptSegments.last {
                // If the last segment ends with this sentence, skip it
                if lastSegment.hasSuffix(sentence) {
                    continue
                }
                // If this sentence starts with the last segment main content (overlap), skip
                if sentence.hasPrefix(lastSegment) {
                    continue
                }
            }
            // Double check duplicate with text processor helper
            let allConfirmed = transcriptSegments.joined(separator: " ")
            if TranscriptTextProcessor.isDuplicate(sentence, of: allConfirmed) {
                continue
            }
            
            // Track this sentence as created by live translation
            liveTranslationCreatedSegments.insert(sentence)
            processNewTranscriptSegment(sentence)
        }
    }
    
    private func extractSentences(from text: String) -> [String] {
        var sentences: [String] = []
        let punctuation = TranscriptTextProcessor.sentenceEndingPunctuation
        
        var currentSentence = ""
        for char in text {
            currentSentence.append(char)
            if punctuation.contains(String(char)) {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }
        return sentences
    }
    
    /// Process a new transcript segment with overlap detection and sentence continuity
    private func processNewTranscriptSegment(_ text: String) {
        var trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // 1. Check if this is a replacement/correction of the LAST segment
        // This handles the case where "Live Translate" added a tentative segment (e.g. "Hello world")
        // but now the engine sends the final corrected version (e.g. "Hello, world!")
        if let lastSegment = transcriptSegments.last, let lastIndex = transcriptSegments.indices.last {
            // First check for simple cumulative update (exact prefix match)
            if TranscriptTextProcessor.isCumulativeUpdate(trimmedText, of: lastSegment) {
                transcriptSegments[lastIndex] = trimmedText
                translateSegment(at: lastIndex, text: trimmedText)
                return
            }
            
            // Then check for "fuzzy" replacement (normalized content match)
            if TranscriptTextProcessor.isReplacementOf(trimmedText, existingText: lastSegment) {
                 // It's a correction! Replace the last segment.
                 transcriptSegments[lastIndex] = trimmedText
                 translateSegment(at: lastIndex, text: trimmedText)
                 return
            }
        }
    
        // 2. Remove overlap with existing content (standard flow)
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
        
        // Check if new segment is too similar to any existing segment (>70% similarity)
        // If similar, REPLACE with the longer version instead of skipping
        if let similarIndex = findMostSimilarSegment(trimmedText, threshold: 0.7) {
            // Replace with the longer version
            if trimmedText.count >= transcriptSegments[similarIndex].count {
                transcriptSegments[similarIndex] = trimmedText
                translateSegment(at: similarIndex, text: trimmedText)
            }
            return
        }
        
        // Normal case: append as new paragraph
        transcriptSegments.append(trimmedText)
        syncTranslatedSegmentsCount()
        translateSegment(at: transcriptSegments.count - 1, text: trimmedText)
    }
    
    /// Find the index of the most similar existing segment above threshold
    private func findMostSimilarSegment(_ newText: String, threshold: Double) -> Int? {
        var bestMatch: (Int, Double)? = nil
        
        for (index, segment) in transcriptSegments.enumerated() {
            let similarity = TranscriptTextProcessor.similarityRatio(newText, segment)
            if similarity > threshold {
                if bestMatch == nil || similarity > bestMatch!.1 {
                    bestMatch = (index, similarity)
                }
            }
        }
        
        return bestMatch?.0
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
        guard lyricModeManager.isRecording && !isPaused else { return }
        
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
    
    /// Retranslate a segment (forces re-translation by clearing first)
    private func retranslateSegment(at index: Int, text: String) {
        guard settings.translationEnabled else { return }
        guard lyricModeManager.isRecording && !isPaused else { return }
        
        syncTranslatedSegmentsCount()
        
        // Clear existing translation first
        if index < translatedSegments.count {
            translatedSegments[index] = ""
        }
        
        // Show toast
        showToastMessage("Retranslating...", icon: "arrow.triangle.2.circlepath", color: .blue)
        
        Task {
            do {
                let translation = try await translationService.translate(text)
                await MainActor.run {
                    if index < translatedSegments.count {
                        translatedSegments[index] = translation
                        showToastMessage("Retranslated", icon: "checkmark.circle", color: .green)
                    }
                }
            } catch {
                await MainActor.run {
                    showToastMessage("Translation failed", icon: "xmark.circle", color: .red)
                }
                print("Retranslation error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Show a toast message with icon and color
    private func showToastMessage(_ message: String, icon: String, color: Color) {
        toastMessage = message
        toastIcon = icon
        toastColor = color
        showToast = true
        
        // Auto-dismiss after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toastMessage == message {
                showToast = false
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
    @State private var localSpeakerDiarizationEnabled: Bool = false
    @State private var localDiarizationBackend: DiarizationBackend = .fluidAudio
    
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
    @State private var localTranslateImmediately: Bool = false
    
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
                    
                    // Behavior section not needed for Teams mode
                    if true {  // Always show behavior section
                        Divider()
                        behaviorSection
                    }
                    
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
            localTranslateImmediately = settings.translateImmediately
            
            // Sentence continuity
            localSentenceContinuityEnabled = settings.sentenceContinuityEnabled
            
            // Speaker diarization
            localSpeakerDiarizationEnabled = settings.speakerDiarizationEnabled
            localDiarizationBackend = settings.diarizationBackend
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
        localTranslateImmediately != settings.translateImmediately ||
        localSentenceContinuityEnabled != settings.sentenceContinuityEnabled ||
        localSpeakerDiarizationEnabled != settings.speakerDiarizationEnabled ||
        localDiarizationBackend != settings.diarizationBackend
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
        settings.translateImmediately = localTranslateImmediately
        
        // Sentence continuity setting
        settings.sentenceContinuityEnabled = localSentenceContinuityEnabled
        
        // Speaker diarization setting
        settings.speakerDiarizationEnabled = localSpeakerDiarizationEnabled
        settings.diarizationBackend = localDiarizationBackend
        
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
            
            // Engine-specific configuration (Apple Speech only)
            Group {
                appleSpeechConfigSection
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
    
    // MARK: - WhisperKit Config
    
    private var whisperKitConfigSection: some View {
        WhisperKitQuickSetupView(settings: settings)
    }
}

// MARK: - WhisperKit Quick Setup View

struct WhisperKitQuickSetupView: View {
    @ObservedObject var settings: LyricModeSettings
    @StateObject private var modelManager = WhisperKitModelManager.shared
    @State private var showingDeleteConfirmation = false
    
    // Combined list of all unique models (downloaded + available)
    private var allModels: [String] {
        let downloadedNames = Set(modelManager.downloadedModels.map { $0.name })
        let availableNames = Set(modelManager.availableModels)
        var models = Array(downloadedNames)
        models.append(contentsOf: availableNames.subtracting(downloadedNames))
        
        return models.sorted { name1, name2 in
            if name1 == modelManager.recommendedModel { return true }
            if name2 == modelManager.recommendedModel { return false }
            return name1 < name2
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Label + Spacer + Picker
            HStack {
                Text("WhisperKit Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if modelManager.isLoadingModels && modelManager.availableModels.isEmpty {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Picker("Model", selection: $settings.selectedWhisperKitModel) {
                        if settings.selectedWhisperKitModel.isEmpty {
                            Text("Select a model").tag("")
                        }
                        
                        ForEach(allModels, id: \.self) { modelName in
                            HStack {
                                Text(modelName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(estimateSize(modelName))
                                    .foregroundColor(.secondary)
                                if modelManager.isModelDownloaded(modelName) {
                                    Image(systemName: "checkmark.circle")
                                } else if modelName == modelManager.recommendedModel {
                                    Image(systemName: "star.fill")
                                }
                            }
                            .tag(modelName)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            
            // Dynamic Action Button (Full width)
            if !settings.selectedWhisperKitModel.isEmpty {
                actionButtonForSelectedModel
            } else if let recommended = modelManager.recommendedModel, 
                      !modelManager.isModelDownloaded(recommended) {
                 // Suggestion if nothing selected
                 Button(action: {
                     Task { try? await modelManager.downloadModel(recommended, from: settings.whisperKitModelRepo) }
                 }) {
                     HStack {
                         Text("Recommended: \(recommended)")
                         Spacer()
                         Image(systemName: "arrow.down.circle")
                     }
                 }
                 .buttonStyle(.plain)
                 .font(.caption)
                 .foregroundColor(.accentColor)
                 .padding(.vertical, 4)
            }
            
            // Error Message
            if let error = modelManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Dismiss") { modelManager.errorMessage = nil }
                        .font(.caption)
                }
            }
        }
        .onAppear {
            modelManager.loadDownloadedModels()
            if modelManager.availableModels.isEmpty {
                Task { await modelManager.fetchAvailableModels(from: settings.whisperKitModelRepo) }
            }
        }
        .alert("Delete Model?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                modelManager.deleteModel(settings.selectedWhisperKitModel)
            }
        } message: {
            Text("Are you sure you want to delete '\(settings.selectedWhisperKitModel)'?")
        }
    }
    
    @ViewBuilder
    private var actionButtonForSelectedModel: some View {
        let selectedModel = settings.selectedWhisperKitModel
        let isDownloaded = modelManager.isModelDownloaded(selectedModel)
        let isDownloading = modelManager.downloadingModels.contains(selectedModel)
        
        if isDownloading {
            HStack {
                ProgressView().scaleEffect(0.6)
                Text("Downloading... \(Int((modelManager.downloadProgress[selectedModel] ?? 0) * 100))%")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        } else if isDownloaded {
            Button(action: { showingDeleteConfirmation = true }) {
                HStack {
                    Image(systemName: "trash")
                    Text("Remove Model")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.regular)
        } else {
            Button(action: {
                Task {
                    try? await modelManager.downloadModel(selectedModel, from: settings.whisperKitModelRepo)
                }
            }) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download \(estimateSize(selectedModel))")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
    
    private func estimateSize(_ name: String) -> String {
        if name.contains("large") { return "~3 GB" }
        else if name.contains("medium") { return "~1.5 GB" }
        else if name.contains("small") { return "~500 MB" }
        else if name.contains("base") { return "~150 MB" }
        else if name.contains("tiny") { return "~75 MB" }
        return ""
    }
}

// MARK: - LyricModeSettingsPopup Additional Views

extension LyricModeSettingsPopup {
    // MARK: - Apple Speech Config
    
    var appleSpeechConfigSection: some View {
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
                
                Divider()
                
                // Speaker Diarization Toggle
                Toggle(isOn: $localSpeakerDiarizationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker Diarization")
                            .font(.subheadline)
                        Text("Identify different speakers (experimental)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                // Diarization Backend Picker (shown when diarization is enabled)
                if localSpeakerDiarizationEnabled {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Diarization Backend")
                                .font(.subheadline)
                            Text(localDiarizationBackend.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $localDiarizationBackend) {
                            ForEach(DiarizationBackend.allCases) { backend in
                                Label(backend.rawValue, systemImage: backend.icon)
                                    .tag(backend)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                }
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
    
    // MARK: - Teams Live Captions Config
    
    private var teamsLiveCaptionsConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Teams Live Captions")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Reads Live Captions from Microsoft Teams meetings using Accessibility API")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if !TeamsLiveCaptionsService.isAccessibilityEnabled() {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Accessibility permission required")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
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
            
            Toggle("Translate Immediately (Live Feel)", isOn: $localTranslateImmediately)
            
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

// MARK: - Segment Row View (with hover actions)

/// A view that displays a segment with hover-revealed action buttons
struct SegmentRowView: View, Equatable {
    let index: Int
    let segment: String
    let translation: String
    let fontSize: CGFloat
    let isLatest: Bool
    let isIgnored: Bool
    let translationEnabled: Bool
    
    // Use stored closures that don't capture View state to allow equality checks
    let onCopy: () -> Void
    let onRetranslate: () -> Void
    let onToggleIgnore: () -> Void
    
    @State private var isHovering = false
    
    static func == (lhs: SegmentRowView, rhs: SegmentRowView) -> Bool {
        return lhs.index == rhs.index &&
               lhs.segment == rhs.segment &&
               lhs.translation == rhs.translation &&
               lhs.fontSize == rhs.fontSize &&
               lhs.isLatest == rhs.isLatest &&
               lhs.isIgnored == rhs.isIgnored &&
               lhs.translationEnabled == rhs.translationEnabled
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Main content
            VStack(alignment: .leading, spacing: 4) {
                TranscriptParagraphView(
                    text: segment,
                    fontSize: fontSize,
                    isLatest: isLatest
                )
                .opacity(isIgnored ? 0.5 : 1.0)
                
                // Show translation if enabled and available
                if translationEnabled && !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: fontSize * 0.85))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 31)
                        .padding(.bottom, 4)
                        .opacity(isIgnored ? 0.5 : 1.0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Action buttons container (always present for consistent hover area)
            HStack(spacing: 4) {
                // Copy button
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
                
                // Retranslate button (only if translation enabled)
                if translationEnabled {
                    Button(action: onRetranslate) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Retranslate")
                }
                
                // Ignore/Unignore button
                Button(action: onToggleIgnore) {
                    Image(systemName: isIgnored ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundColor(isIgnored ? .green : .secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isIgnored ? "Unignore segment" : "Ignore segment")
            }
            .padding(.trailing, 8)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle()) // Make entire row hoverable
        .onHover { hovering in
            isHovering = hovering
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

// MARK: - Window Selection Sheet

/// A sheet view for selecting a window to read captions from
struct WindowSelectionSheet: View {
    let windows: [TeamsLiveCaptionsService.WindowInfo]
    let onRefresh: () -> Void
    let onSelect: (TeamsLiveCaptionsService.WindowInfo) -> Void
    let onCancel: () -> Void
    
    @State private var searchText = ""
    
    private var filteredWindows: [TeamsLiveCaptionsService.WindowInfo] {
        // Only show Teams-related windows
        let teamsWindows = windows.filter { $0.isTeamsCaptionWindow }
        
        if searchText.isEmpty {
            return teamsWindows
        }
        return teamsWindows.filter { window in
            window.displayName.localizedCaseInsensitiveContains(searchText) ||
            window.appName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Caption Window")
                    .font(.headline)
                
                Spacer()
                
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh window list")
            }
            .padding()
            
            Divider()
            
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search windows...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Window list
            if filteredWindows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No windows found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Make sure Microsoft Teams is running\nwith Live Captions enabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(filteredWindows) { window in
                    Button(action: { onSelect(window) }) {
                        HStack(spacing: 12) {
                            // App icon indicator
                            if window.isTeamsCaptionWindow {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .help("Recommended - Teams/Caption window")
                            } else {
                                Image(systemName: "macwindow")
                                    .foregroundColor(.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.windowTitle)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(window.appName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("\(filteredWindows.count) window(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .frame(width: 450, height: 400)
    }
}
