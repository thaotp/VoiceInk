import SwiftUI

/// SwiftUI view for displaying transcribed text in lyric/karaoke style
/// Shows last N lines with current line highlighted and smooth animations
struct LyricModeOverlayView: View {
    @ObservedObject var transcriptionEngine: RealtimeTranscriptionEngine
    @ObservedObject var settings: LyricModeSettings
    
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isHovering = false
    @State private var shouldAutoScroll = true
    @State private var lastAutoScrollTime = Date.distantPast
    @State private var lastDataUpdateTime = Date.distantPast
    
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
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
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
                        
                        // Anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear {
                                shouldAutoScroll = true
                            }
                            .onDisappear {
                                let now = Date()
                                let timeSinceAutoScroll = now.timeIntervalSince(lastAutoScrollTime)
                                let timeSinceData = now.timeIntervalSince(lastDataUpdateTime)
                                
                                if timeSinceAutoScroll > 0.5 && timeSinceData > 0.5 {
                                    shouldAutoScroll = false
                                }
                            }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    scrollProxy = proxy
                }
                .onChange(of: transcriptionEngine.confirmedLines.count) { _, _ in
                    lastDataUpdateTime = Date()
                    if shouldAutoScroll {
                        lastAutoScrollTime = Date()
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: transcriptionEngine.partialLine) { _, _ in
                    lastDataUpdateTime = Date()
                    if shouldAutoScroll {
                        lastAutoScrollTime = Date()
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // Resume Button
                if !shouldAutoScroll && (!transcriptionEngine.confirmedLines.isEmpty || !transcriptionEngine.partialLine.isEmpty) {
                    Button(action: {
                        shouldAutoScroll = true
                        lastAutoScrollTime = Date()
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Resume")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.15))
                        )
                        .padding(12)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
    }
    
    // MARK: - Line Views
    
    private func confirmedLineView(_ text: String, isLatest: Bool) -> some View {
        Text(text)
            .font(.system(size: settings.fontSize, weight: isLatest ? .semibold : .regular))
            .foregroundColor(isLatest ? .white : .white.opacity(0.7))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.3), value: text)
    }
    
    private var partialLineView: some View {
        HStack(spacing: 4) {
            Text(transcriptionEngine.partialLine)
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
