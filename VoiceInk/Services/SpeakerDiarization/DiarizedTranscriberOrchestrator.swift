import Foundation
import AVFoundation
import Speech
import Combine
import os

/// Orchestrates real-time transcription with speaker diarization
/// Merges Apple Speech transcription with FluidAudio diarization into chat-like segments
@MainActor
final class DiarizedTranscriberOrchestrator: ObservableObject {
    
    // MARK: - Published Output
    
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var currentSpeaker: SpeakerLabel = .unknown
    @Published private(set) var isProcessing = false
    @Published private(set) var error: Error?
    
    // MARK: - Public Streams
    
    /// Stream of merged transcript updates for external consumers
    private(set) var transcriptStream: AsyncStream<TranscriptUpdate>!
    private var transcriptContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DiarizedOrchestrator")
    
    // Core components
    private var audioEngine: AVAudioEngine?
    private let audioSplitter = AudioSplitter()
    private var diarizationService: any DiarizationServiceProtocol
    private let diarizationMerger = DiarizationMergerActor()
    private var transcriptionMerger: TranscriptionMergerActor!
    private let diarizationBuffer: DiarizationBufferActor
    
    // Tasks
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    
    // Stream continuations
    private var speechInputContinuation: AsyncStream<AudioSplitter.SpeechAudioInput>.Continuation?
    private var diarizationInputContinuation: AsyncStream<DiarizationChunk>.Continuation?
    
    // Configuration
    private var locale: Locale = Locale(identifier: "en-US")
    
    // Performance monitoring
    private var processedWindowCount = 0
    private var lastThrottleCheck = Date()
    private var shouldThrottle = false
    
    // MARK: - Initialization
    
    init(diarizationService: (any DiarizationServiceProtocol)? = nil, windowDuration: TimeInterval = 0.5, hopDuration: TimeInterval = 0.25) {
        // Use provided service or default to mock for development
        self.diarizationService = diarizationService ?? MockDiarizationService()
        self.diarizationBuffer = DiarizationBufferActor(windowDuration: windowDuration, hopDuration: hopDuration)
        self.transcriptionMerger = TranscriptionMergerActor(diarizationActor: diarizationMerger)
        
        // Create output stream
        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        self.transcriptStream = stream
        self.transcriptContinuation = continuation
    }
    
    // MARK: - Public Methods
    
    /// Set the transcription language
    func setLanguage(_ languageCode: String) {
        let localeMapping: [String: String] = [
            "auto": "en-US", "en": "en-US", "es": "es-ES", "fr": "fr-FR",
            "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
            "zh": "zh-CN", "pt": "pt-BR", "ru": "ru-RU", "vi": "vi-VN"
        ]
        let identifier = localeMapping[languageCode] ?? "en-US"
        locale = Locale(identifier: identifier)
    }
    
    /// Start transcription with diarization
    func start() async throws {
        guard !isProcessing else { return }
        
        logger.info("Starting diarized transcription")
        
        // Initialize diarization service
        try await diarizationService.initialize()
        
        // Setup audio engine
        let engine = AVAudioEngine()
        audioEngine = engine
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Get best audio format for speech recognition on macOS 26+
        var speechFormat: AVAudioFormat? = nil
        if #available(macOS 26, *) {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            speechFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            if let format = speechFormat {
                print("[DiarizedOrchestrator] Using analyzer format: \(format)")
            } else {
                print("[DiarizedOrchestrator] Warning: Could not get bestAvailableAudioFormat, using default")
            }
        }
        
        // Create input streams
        let (speechStream, speechContinuation) = AsyncStream<AudioSplitter.SpeechAudioInput>.makeStream()
        let (diarizationStream, diarizationContinuation) = AsyncStream<DiarizationChunk>.makeStream()
        
        self.speechInputContinuation = speechContinuation
        self.diarizationInputContinuation = diarizationContinuation
        
        // Configure audio splitter with the correct speech format
        audioSplitter.configure(
            speechContinuation: speechContinuation,
            diarizationContinuation: diarizationContinuation
        )
        audioSplitter.installTap(on: inputNode, inputFormat: inputFormat, speechFormat: speechFormat)
        
        // Start diarization processing
        diarizationTask = Task(priority: .userInitiated) { [weak self] in
            await self?.processDiarizationStream(diarizationStream)
        }
        
        // Start transcription (Apple Speech)
        if #available(macOS 26, *) {
            transcriptionTask = Task(priority: .userInitiated) { [weak self] in
                await self?.processTranscriptionWithSpeechTranscriber(speechStream)
            }
        } else {
            // Fallback for older macOS - use SFSpeechRecognizer
            transcriptionTask = Task(priority: .userInitiated) { [weak self] in
                await self?.processTranscriptionWithSFSpeechRecognizer(speechStream, inputFormat: inputFormat)
            }
        }
        
        // Start audio engine
        try engine.start()
        
        isProcessing = true
        logger.info("Diarized transcription started")
    }
    
    /// Stop transcription
    func stop() {
        guard isProcessing else { return }
        
        logger.info("Stopping diarized transcription")
        
        // Cancel tasks
        transcriptionTask?.cancel()
        diarizationTask?.cancel()
        
        // Remove audio tap
        audioSplitter.removeTap()
        
        // Stop audio engine
        audioEngine?.stop()
        audioEngine = nil
        
        // Finish continuations
        speechInputContinuation?.finish()
        diarizationInputContinuation?.finish()
        
        isProcessing = false
        logger.info("Diarized transcription stopped")
    }
    
    /// Pause transcription (stops audio engine but keeps state)
    func pause() {
        guard isProcessing else { return }
        logger.info("Pausing diarized transcription")
        audioEngine?.pause()
    }
    
    /// Resume transcription after pause
    func resume() {
        guard isProcessing else { return }
        logger.info("Resuming diarized transcription")
        try? audioEngine?.start()
    }
    
    /// Clear all segments
    func clear() async {
        segments.removeAll()
        currentSpeaker = .unknown
        await transcriptionMerger.clear()
        await diarizationMerger.clear()
        await diarizationBuffer.clear()
    }
    
    // MARK: - Private Methods
    
    private func processDiarizationStream(_ stream: AsyncStream<DiarizationChunk>) async {
        for await chunk in stream {
            guard !Task.isCancelled else { break }
            
            // Check throttling (skip every other window under high CPU)
            if shouldThrottle {
                processedWindowCount += 1
                if processedWindowCount % 2 == 0 {
                    continue
                }
            }
            
            // Buffer until we have a full window
            if let window = await diarizationBuffer.append(chunk: chunk) {
                // Run diarization inference
                if let segments = await diarizationService.process(window: window) {
                    for segment in segments {
                        await diarizationMerger.addSegment(segment)
                    }
                }
            }
            
            // Update throttle state periodically
            if Date().timeIntervalSince(lastThrottleCheck) > 5.0 {
                updateThrottleState()
            }
        }
    }
    
    @available(macOS 26, *)
    private func processTranscriptionWithSpeechTranscriber(_ stream: AsyncStream<AudioSplitter.SpeechAudioInput>) async {
        do {
            // Create transcriber with optimized settings for real-time
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            
            // Convert speech input stream to AnalyzerInput stream
            let analyzerStream = stream.map { input -> AnalyzerInput in
                AnalyzerInput(buffer: input.buffer)
            }
            
            // Record stream start time for timestamp calculation
            let streamStartTime = Date()
            
            print("[DiarizedOrchestrator] Starting SpeechAnalyzer with concurrent result processing")
            
            // Use TaskGroup to run analyzer and result processing concurrently
            // analyzer.start() blocks until stream ends, so we need parallel execution
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Run the analyzer (this drives the transcription)
                group.addTask {
                    try await analyzer.start(inputSequence: analyzerStream)
                    print("[DiarizedOrchestrator] Analyzer finished")
                }
                
                // Task 2: Process results as they arrive
                group.addTask { [self] in
                    var currentSegmentId: UUID? = nil
                    var lastFinalizedText: String = ""
                    
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { break }
                        
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        
                        let timestamp = Date().timeIntervalSince(streamStartTime)
                        
                        // Lookup current speaker from diarization
                        let speakerResult = await diarizationMerger.lookupSpeaker(at: timestamp)
                        let speakerLabel = speakerResult.toLabel
                        
                        // DEBUG: Print transcription result
                        print("[DiarizedOrchestrator] Received: '\(text)' isFinal=\(result.isFinal) speaker=\(speakerLabel.displayName)")
                        
                        if result.isFinal {
                            // Finalize current segment with final text
                            let newText = text.hasPrefix(lastFinalizedText) 
                                ? String(text.dropFirst(lastFinalizedText.count)).trimmingCharacters(in: .whitespaces)
                                : text
                            
                            if !newText.isEmpty {
                                let segment = TranscriptSegment(
                                    id: currentSegmentId ?? UUID(),
                                    speaker: speakerLabel,
                                    words: [],
                                    text: newText,
                                    startTime: timestamp,
                                    endTime: timestamp,
                                    isFinal: true
                                )
                                
                                await MainActor.run {
                                    if let existingIndex = self.segments.firstIndex(where: { $0.id == segment.id }) {
                                        self.segments[existingIndex] = segment
                                    } else {
                                        self.segments.append(segment)
                                    }
                                    print("[DiarizedOrchestrator] Finalized segment: '\(segment.text)' total=\(self.segments.count)")
                                    self.transcriptContinuation?.yield(.segmentFinalized(segment))
                                }
                                
                                lastFinalizedText = text
                            }
                            currentSegmentId = nil
                        } else {
                            // Update or create partial segment
                            let partialText = text.hasPrefix(lastFinalizedText)
                                ? String(text.dropFirst(lastFinalizedText.count)).trimmingCharacters(in: .whitespaces)
                                : text
                            
                            if !partialText.isEmpty {
                                let segmentId = currentSegmentId ?? UUID()
                                currentSegmentId = segmentId
                                
                                let segment = TranscriptSegment(
                                    id: segmentId,
                                    speaker: speakerLabel,
                                    words: [],
                                    text: partialText,
                                    startTime: timestamp,
                                    endTime: timestamp,
                                    isFinal: false
                                )
                                
                                await MainActor.run {
                                    if let existingIndex = self.segments.firstIndex(where: { $0.id == segmentId }) {
                                        self.segments[existingIndex] = segment
                                        self.transcriptContinuation?.yield(.segmentUpdated(segment))
                                    } else {
                                        self.segments.append(segment)
                                        self.transcriptContinuation?.yield(.newSegmentStarted(segment))
                                    }
                                    print("[DiarizedOrchestrator] Partial segment: '\(segment.text)' total=\(self.segments.count)")
                                }
                            }
                        }
                    }
                    print("[DiarizedOrchestrator] Result processing finished")
                }
                
                // Wait for all tasks to complete
                try await group.waitForAll()
            }
        } catch {
            logger.error("SpeechTranscriber error: \(error.localizedDescription)")
            print("[DiarizedOrchestrator] Error: \(error.localizedDescription)")
            await MainActor.run {
                self.error = error
            }
        }
    }
    
    private func processTranscriptionWithSFSpeechRecognizer(_ stream: AsyncStream<AudioSplitter.SpeechAudioInput>, inputFormat: AVAudioFormat) async {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer not available for locale: \(self.locale.identifier)")
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        // Note: SFSpeechRecognizer doesn't provide word-level timestamps as reliably
        // We'll approximate based on transcription timing
        var lastTranscriptLength = 0
        let streamStartTime = Date()
        
        let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, let result = result else { return }
            
            let fullText = result.bestTranscription.formattedString
            if fullText.count > lastTranscriptLength {
                let newText = String(fullText.dropFirst(lastTranscriptLength))
                lastTranscriptLength = fullText.count
                
                // Create approximate word with timestamp
                let timestamp = Date().timeIntervalSince(streamStartTime)
                let word = TranscribedWord(
                    text: newText,
                    timestamp: timestamp,
                    duration: 0.1,
                    confidence: Double(result.bestTranscription.segments.last?.confidence ?? 0.5),
                    isFinal: result.isFinal
                )
                
                Task {
                    await self.processWord(word)
                }
            }
        }
        
        // Feed audio buffers to recognition request
        for await input in stream {
            guard !Task.isCancelled else { break }
            request.append(input.buffer)
        }
        
        request.endAudio()
        recognitionTask.cancel()
    }
    
    private func processWord(_ word: TranscribedWord) async {
        let update = await transcriptionMerger.processWord(word)
        await handleTranscriptUpdate(update)
    }
    
    private func handleTranscriptUpdate(_ update: TranscriptUpdate) async {
        await MainActor.run {
            switch update {
            case .newSegmentStarted(let segment):
                segments.append(segment)
                currentSpeaker = segment.speaker
            case .segmentUpdated(let segment):
                if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                    segments[index] = segment
                }
            case .segmentFinalized(let segment):
                if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                    segments[index] = segment
                }
            }
            
            // Emit to stream
            transcriptContinuation?.yield(update)
        }
    }
    
    private func updateThrottleState() {
        lastThrottleCheck = Date()
        
        // Check thermal state
        let thermalState = ProcessInfo.processInfo.thermalState
        shouldThrottle = thermalState == .serious || thermalState == .critical
        
        if shouldThrottle {
            logger.warning("High thermal state detected, throttling diarization")
        }
    }
    
    deinit {
        transcriptionTask?.cancel()
        diarizationTask?.cancel()
        transcriptContinuation?.finish()
    }
}

// MARK: - Convenience Extensions

extension DiarizedTranscriberOrchestrator {
    /// Create with the selected diarization backend from settings
    static func withSelectedBackend() -> DiarizedTranscriberOrchestrator {
        let settings = LyricModeSettings.shared
        switch settings.diarizationBackend {
        case .sherpaOnnx:
            print("[DiarizedOrchestrator] Using Sherpa-Onnx diarization backend (10s windows)")
            // Sherpa-Onnx offline diarization needs longer audio windows (10s minimum)
            // for accurate speaker clustering. Use 5s hop for 50% overlap.
            return DiarizedTranscriberOrchestrator(
                diarizationService: SherpaOnnxDiarizationService(),
                windowDuration: 10.0,
                hopDuration: 5.0
            )
        case .fluidAudio:
            print("[DiarizedOrchestrator] Using energy-based diarization backend")
            // Energy-based works with short windows (0.5s)
            return DiarizedTranscriberOrchestrator(diarizationService: EnergyBasedDiarizationService())
        }
    }
    
    /// Create with energy-based diarization (no ML model required)
    static func withEnergyBasedDiarization() -> DiarizedTranscriberOrchestrator {
        DiarizedTranscriberOrchestrator(diarizationService: EnergyBasedDiarizationService())
    }
    
    /// Create with mock diarization for testing
    static func withMockDiarization() -> DiarizedTranscriberOrchestrator {
        DiarizedTranscriberOrchestrator(diarizationService: MockDiarizationService())
    }
}
