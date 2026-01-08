import Foundation
import Combine
import os

/// Real-time transcription engine that coordinates audio streaming, VAD, and whisper inference
/// Implements text stabilization to prevent flicker in displayed transcriptions
@MainActor
final class RealtimeTranscriptionEngine: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isRunning = false
    @Published private(set) var confirmedLines: [String] = []
    @Published private(set) var partialLine: String = ""
    @Published private(set) var allText: String = ""
    
    // MARK: - Services
    
    private let audioStream: RealtimeAudioStreamService
    private let vadService: RealtimeVADService
    private var whisperContext: WhisperContext?
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Number of consecutive matches required to confirm text
        var confirmationThreshold: Int = 2
        /// Maximum provisional history to track
        var maxProvisionalHistory: Int = 3
        /// Minimum word count to consider for confirmation
        var minWordsForConfirmation: Int = 2
    }
    
    var configuration = Configuration()
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RealtimeTranscription")
    private var cancellables = Set<AnyCancellable>()
    
    // Text stabilization state
    private var provisionalHistory: [String] = []
    private var currentSegmentSamples: [Float] = []
    private var segmentStartTime: Date?
    private var isProcessingChunk = false
    
    // Transcription queue (serial to prevent overlapping inference)
    private let transcriptionQueue = DispatchQueue(label: "com.voiceink.transcription", qos: .userInitiated)
    
    // MARK: - Initialization
    
    init(audioStream: RealtimeAudioStreamService, vadService: RealtimeVADService) {
        self.audioStream = audioStream
        self.vadService = vadService
    }
    
    // MARK: - Public Methods
    
    func start(with whisperContext: WhisperContext) async throws {
        guard !isRunning else { return }
        
        self.whisperContext = whisperContext
        
        // Reset state
        confirmedLines = []
        partialLine = ""
        allText = ""
        provisionalHistory = []
        currentSegmentSamples = []
        segmentStartTime = nil
        
        // Connect to audio stream
        setupAudioChunkProcessing()
        setupVADStateHandling()
        
        // Start audio streaming
        try audioStream.startStreaming()
        vadService.connect(to: audioStream)
        
        isRunning = true
        logger.info("Real-time transcription engine started")
    }
    
    func stop() {
        guard isRunning else { return }
        
        vadService.disconnect()
        audioStream.stopStreaming()
        cancellables.removeAll()
        
        // Finalize any pending segment
        if !currentSegmentSamples.isEmpty {
            finalizeCurrentSegment()
        }
        
        isRunning = false
        logger.info("Real-time transcription engine stopped")
    }
    
    func clear() {
        confirmedLines = []
        partialLine = ""
        allText = ""
        provisionalHistory = []
        currentSegmentSamples = []
    }
    
    // MARK: - Private Methods
    
    private func setupAudioChunkProcessing() {
        audioStream.audioChunkPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                self?.handleAudioChunk(chunk)
            }
            .store(in: &cancellables)
    }
    
    private func setupVADStateHandling() {
        vadService.stateChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleVADStateChange(state)
            }
            .store(in: &cancellables)
    }
    
    private func handleAudioChunk(_ chunk: AudioChunk) {
        // Accumulate samples for current segment
        if vadService.isSpeaking || !currentSegmentSamples.isEmpty {
            if segmentStartTime == nil {
                segmentStartTime = chunk.timestamp
            }
            currentSegmentSamples.append(contentsOf: chunk.samples)
            
            // Trigger incremental transcription if we have enough samples
            let minSamplesForTranscription = Int(RealtimeAudioStreamService.Configuration.targetSampleRate * 0.5) // 500ms
            if currentSegmentSamples.count >= minSamplesForTranscription && !isProcessingChunk {
                processCurrentSegment()
            }
        }
    }
    
    private func handleVADStateChange(_ state: RealtimeVADService.SpeechState) {
        switch state {
        case .speechStart:
            // Start new segment
            if currentSegmentSamples.isEmpty {
                segmentStartTime = Date()
            }
            
        case .speechEnd:
            // Finalize current segment
            finalizeCurrentSegment()
            
        case .silence, .speaking:
            break
        }
    }
    
    private func processCurrentSegment() {
        guard !isProcessingChunk, !currentSegmentSamples.isEmpty else { return }
        guard let context = whisperContext else { return }
        
        isProcessingChunk = true
        let samplesToProcess = currentSegmentSamples
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Run whisper inference
            let success = await context.fullTranscribe(samples: samplesToProcess)
            
            if success {
                let transcription = await context.getTranscription()
                let cleanedText = self.cleanTranscription(transcription)
                
                await MainActor.run {
                    self.updateWithProvisionalText(cleanedText)
                    self.isProcessingChunk = false
                }
            } else {
                await MainActor.run {
                    self.isProcessingChunk = false
                }
            }
        }
    }
    
    private func finalizeCurrentSegment() {
        guard !currentSegmentSamples.isEmpty else { return }
        guard let context = whisperContext else {
            currentSegmentSamples = []
            segmentStartTime = nil
            return
        }
        
        let samplesToProcess = currentSegmentSamples
        currentSegmentSamples = []
        segmentStartTime = nil
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let success = await context.fullTranscribe(samples: samplesToProcess)
            
            if success {
                let transcription = await context.getTranscription()
                let cleanedText = self.cleanTranscription(transcription)
                
                await MainActor.run {
                    self.confirmText(cleanedText)
                }
            }
        }
    }
    
    private func updateWithProvisionalText(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Add to provisional history
        provisionalHistory.append(text)
        if provisionalHistory.count > configuration.maxProvisionalHistory {
            provisionalHistory.removeFirst()
        }
        
        // Find stable prefix across provisional results
        let stablePrefix = findStablePrefix()
        
        // Update partial line with latest provisional text
        if let stablePrefix = stablePrefix, !stablePrefix.isEmpty {
            // Show stable prefix as part of the line, rest as partial
            let remainingText = text.hasPrefix(stablePrefix) 
                ? String(text.dropFirst(stablePrefix.count)).trimmingCharacters(in: .whitespaces)
                : text
            partialLine = stablePrefix + (remainingText.isEmpty ? "" : " " + remainingText)
        } else {
            partialLine = text
        }
        
        updateAllText()
    }
    
    private func confirmText(_ text: String) {
        guard !text.isEmpty else { return }
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // Add to confirmed lines
        confirmedLines.append(trimmedText)
        
        // Clear provisional state
        partialLine = ""
        provisionalHistory = []
        
        updateAllText()
        
        logger.debug("Confirmed text: \(trimmedText)")
    }
    
    private func findStablePrefix() -> String? {
        guard provisionalHistory.count >= configuration.confirmationThreshold else { return nil }
        
        // Get words from each provisional result
        let wordArrays = provisionalHistory.map { $0.split(separator: " ").map(String.init) }
        
        guard let firstWords = wordArrays.first, !firstWords.isEmpty else { return nil }
        
        var stableWords: [String] = []
        
        for (index, word) in firstWords.enumerated() {
            // Check if this word appears at the same position in all provisional results
            let appearsInAll = wordArrays.allSatisfy { words in
                index < words.count && words[index].lowercased() == word.lowercased()
            }
            
            if appearsInAll {
                stableWords.append(word)
            } else {
                break
            }
        }
        
        guard stableWords.count >= configuration.minWordsForConfirmation else { return nil }
        
        return stableWords.joined(separator: " ")
    }
    
    nonisolated private func cleanTranscription(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common whisper artifacts
        let artifactsToRemove = [
            "[BLANK_AUDIO]",
            "(BLANK_AUDIO)",
            "[MUSIC]",
            "[music]",
            "[ Silence ]",
            "[silence]",
            "(music)",
            "(silence)"
        ]
        
        for artifact in artifactsToRemove {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }
        
        // Collapse multiple spaces
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func updateAllText() {
        var lines = confirmedLines
        if !partialLine.isEmpty {
            lines.append(partialLine)
        }
        allText = lines.joined(separator: "\n")
    }
}
