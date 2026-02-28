import SwiftUI

/// SwiftUI view for displaying transcribed text in lyric/karaoke style
/// Shows last N lines with current line highlighted and smooth animations
struct LyricModeOverlayView: View {
    @ObservedObject var transcriptionEngine: RealtimeTranscriptionEngine
    @ObservedObject var settings: LyricModeSettings
    
    @State private var isHovering = false
    
    // MeCab-formatted display text cache (display-only, keyed by original text)
    @State private var mecabFormattedLines: [String: String] = [:]
    @State private var mecabFormattedPartial: String = ""
    
    var body: some View {
        ZStack {
            // Background
            backgroundView
            
            // Content
            VStack(spacing: 0) {
                // Header with controls (visible on hover)
                if isHovering {
                    headerView
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // Transcription lines
                transcriptionContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 300, minHeight: 150)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(settings.backgroundOpacity * 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Lyric Mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            
            Spacer()
            
            // Settings indicator
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundColor(transcriptionEngine.isRunning ? .green : .gray)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - Transcription Content
    
    private var transcriptionContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                // Confirmed lines
                ForEach(Array(visibleConfirmedLines.enumerated()), id: \.offset) { index, line in
                    confirmedLineView(line, isLatest: index == visibleConfirmedLines.count - 1)
                        .id("confirmed-\(index)")
                }
                
                // Partial/current line
                if !transcriptionEngine.partialLine.isEmpty {
                    partialLineView
                        .id("partial")
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: transcriptionEngine.confirmedLines.count) { _, _ in
            // MeCab formatting for new confirmed lines (bunsetsu spacing)
            // Skip when using Gemini - it returns spaced Japanese via its own API
            if MeCabFormatterService.isJapanese(settings.selectedLanguage) && settings.translationProvider != .gemini {
                let formatter = MeCabFormatterService.shared
                for line in transcriptionEngine.confirmedLines {
                    if mecabFormattedLines[line] == nil {
                        Task {
                            let formatted = await formatter.formatPlain(line)
                            mecabFormattedLines[line] = formatted
                        }
                    }
                }
            }
        }
        .onChange(of: transcriptionEngine.partialLine) { _, newPartial in
            // MeCab formatting for partial line (bunsetsu spacing)
            // Skip when using Gemini - it returns spaced Japanese via its own API
            if MeCabFormatterService.isJapanese(settings.selectedLanguage) && settings.translationProvider != .gemini && !newPartial.isEmpty {
                Task {
                    let formatted = await MeCabFormatterService.shared.formatPlain(newPartial)
                    mecabFormattedPartial = formatted
                }
            } else {
                mecabFormattedPartial = ""
            }
        }
    }
    
    // MARK: - Line Views
    
    private func confirmedLineView(_ text: String, isLatest: Bool) -> some View {
        let displayText = mecabFormattedLines[text] ?? text
        return Text(displayText)
            .font(.system(size: settings.fontSize, weight: isLatest ? .semibold : .regular))
            .foregroundColor(isLatest ? .white : .white.opacity(0.7))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.3), value: displayText)
    }
    
    private var partialLineView: some View {
        let displayPartial = MeCabFormatterService.isJapanese(settings.selectedLanguage) && settings.translationProvider != .gemini && !mecabFormattedPartial.isEmpty
            ? mecabFormattedPartial
            : transcriptionEngine.partialLine
        return HStack(spacing: 4) {
            Text(displayPartial)
                .font(.system(size: settings.fontSize, weight: .semibold))
                .foregroundColor(settings.showPartialHighlight ? .cyan : .white)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
            
            // Typing indicator
            if transcriptionEngine.isRunning {
                TypingIndicator()
                    .foregroundColor(.cyan.opacity(0.8))
            }
        }
        .transition(.opacity)
    }
    
    // MARK: - Helpers
    
    private var visibleConfirmedLines: [String] {
        let lines = transcriptionEngine.confirmedLines
        if lines.count <= settings.maxVisibleLines {
            return lines
        }
        return Array(lines.suffix(settings.maxVisibleLines))
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.primary)
                    .frame(width: 4, height: 4)
                    .opacity(animationPhase == index ? 1.0 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                animationPhase = 2
            }
            
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                animationPhase = (animationPhase + 1) % 3
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let audioStream = RealtimeAudioStreamService()
    let vadService = RealtimeVADService()
    let engine = RealtimeTranscriptionEngine(audioStream: audioStream, vadService: vadService)
    
    return LyricModeOverlayView(
        transcriptionEngine: engine,
        settings: LyricModeSettings.shared
    )
    .frame(width: 400, height: 250)
    .background(Color.black)
}
