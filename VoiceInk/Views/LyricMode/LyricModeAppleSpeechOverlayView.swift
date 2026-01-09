import SwiftUI

/// SwiftUI view for displaying transcribed text from Apple Speech with sentence breaks
struct LyricModeAppleSpeechOverlayView: View {
    @ObservedObject var speechService: AppleSpeechRealtimeService
    @ObservedObject var settings: LyricModeSettings
    
    @State private var confirmedLines: [String] = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isHovering = false
    
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
                
                // Transcription content
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
        .onReceive(speechService.transcriptionPublisher) { newText in
            processTranscription(newText)
        }
    }
    
    // MARK: - Sentence Processing
    
    /// Process transcription text and split into sentences for display
    private func processTranscription(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Remove overlap with existing content
        let existingText = confirmedLines.joined(separator: " ")
        guard let processedText = TranscriptTextProcessor.removeOverlap(from: text, existingText: existingText) else {
            return // All content already exists
        }
        
        // Split text into sentences using punctuation
        let sentences = splitIntoSentences(processedText)
        
        withAnimation(.easeOut(duration: 0.3)) {
            for sentence in sentences {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                
                // Check for duplicates
                if let lastLine = confirmedLines.last {
                    if TranscriptTextProcessor.isDuplicate(trimmed, of: lastLine) {
                        continue
                    }
                    // Handle cumulative update
                    if TranscriptTextProcessor.isCumulativeUpdate(trimmed, of: lastLine) {
                        confirmedLines[confirmedLines.count - 1] = trimmed
                        continue
                    }
                }
                
                confirmedLines.append(trimmed)
            }
        }
    }
    
    /// Split text into sentences based on punctuation marks
    private func splitIntoSentences(_ text: String) -> [String] {
        // Match sentence-ending punctuation: .!?。？！
        let pattern = "(?<=[.!?。？！])\\s*"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let results = regex.matches(in: text, options: [], range: range)
            
            if results.isEmpty {
                // No sentence breaks found, return as single item
                return [text]
            }
            
            var sentences: [String] = []
            var lastEnd = text.startIndex
            
            for match in results {
                if let range = Range(match.range, in: text) {
                    let sentence = String(text[lastEnd..<range.lowerBound])
                    if !sentence.trimmingCharacters(in: .whitespaces).isEmpty {
                        sentences.append(sentence)
                    }
                    lastEnd = range.upperBound
                }
            }
            
            // Add remaining text after last punctuation
            let remaining = String(text[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(remaining)
            }
            
            return sentences.isEmpty ? [text] : sentences
        }
        
        return [text]
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
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 10))
                Text("Apple Speech")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.6))
            
            Spacer()
            
            // Status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(speechService.isListening ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(speechService.isListening ? "Listening" : "Stopped")
                    .font(.system(size: 10))
                    .foregroundColor(speechService.isListening ? .green : .gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - Transcription Content
    
    private var transcriptionContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Show confirmed lines (limited to visible count)
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: settings.fontSize, weight: index == visibleLines.count - 1 ? .semibold : .regular))
                            .foregroundColor(index == visibleLines.count - 1 ? .white : .white.opacity(0.7))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("line-\(confirmedLines.count - visibleLines.count + index)")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    
                    // Current partial text with typing indicator (live updates)
                    if !speechService.partialTranscript.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Text(speechService.partialTranscript)
                                .font(.system(size: settings.fontSize, weight: .semibold))
                                .foregroundColor(settings.showPartialHighlight ? .cyan : .white)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .animation(.easeOut(duration: 0.1), value: speechService.partialTranscript)  // Smooth text updates
                            
                            if speechService.isListening {
                                TypingIndicator()
                                    .foregroundColor(.cyan.opacity(0.8))
                            }
                        }
                        .id("partial")
                        .transition(.opacity)  // Fade in/out smoothly
                    } else if speechService.isListening && confirmedLines.isEmpty {
                        // Show typing indicator when listening but no text yet
                        HStack(spacing: 4) {
                            Text("Listening...")
                                .font(.system(size: settings.fontSize * 0.7, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            TypingIndicator()
                                .foregroundColor(.cyan.opacity(0.6))
                        }
                        .id("waiting")
                    }
                    
                    // Anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollProxy = proxy
            }
            .onChange(of: confirmedLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: speechService.partialTranscript) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var visibleLines: [String] {
        if confirmedLines.count <= settings.maxVisibleLines {
            return confirmedLines
        }
        return Array(confirmedLines.suffix(settings.maxVisibleLines))
    }
}
