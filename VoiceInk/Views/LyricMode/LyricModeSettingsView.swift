import SwiftUI
import SwiftData

/// Settings view for configuring Lyric Mode appearance and behavior
struct LyricModeSettingsView: View {
    @ObservedObject var settings: LyricModeSettings
    @ObservedObject var lyricModeManager: LyricModeWindowManager
    @ObservedObject var whisperState: WhisperState
    
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
                .disabled(isStarting || whisperState.currentTranscriptionModel == nil)
                
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
            
            if whisperState.currentTranscriptionModel == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Please select an AI model first")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
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
        guard let model = whisperState.currentTranscriptionModel,
              let context = whisperState.loadedLocalModel else {
            return
        }
        
        Task {
            isStarting = true
            defer { isStarting = false }
            
            do {
                // Need to load or get whisper context
                // For now, we'll create a basic toggle that uses the existing model
                if lyricModeManager.isVisible {
                    lyricModeManager.hide()
                } else {
                    // Create whisper context from current model
                    if let modelPath = whisperState.getModelPath(for: model) {
                        let context = try await WhisperContext.createContext(path: modelPath)
                        try await lyricModeManager.show(with: context)
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
