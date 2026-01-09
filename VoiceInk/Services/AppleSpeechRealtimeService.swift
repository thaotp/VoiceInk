import Foundation
import AVFoundation
import Speech
import Combine
import os

/// Real-time speech recognition service using Apple's SpeechTranscriber (macOS 26+)
/// Falls back to SFSpeechRecognizer on older macOS versions
@MainActor
final class AppleSpeechRealtimeService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isListening = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var partialTranscript: String = ""
    
    /// Publisher for finalized transcription segments
    let transcriptionPublisher = PassthroughSubject<String, Never>()
    
    /// Publisher that fires when content is cleared
    let clearedPublisher = PassthroughSubject<Void, Never>()
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppleSpeechRealtime")
    
    // SpeechTranscriber (macOS 26+) - using Any to avoid availability issues
    private var inputContinuation: Any? // AsyncStream<AnalyzerInput>.Continuation on macOS 26+
    private var recognitionTask: Task<Void, Error>?
    
    // SFSpeechRecognizer fallback (older macOS)
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyRecognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var restartTimer: Timer?
    
    private var lastFinalizedText: String = ""
    private var selectedLocale: Locale = Locale(identifier: "en-US")
    
    // Track which API is being used
    private var usingSpeechTranscriber = false
    
    // MARK: - Initialization
    
    init() {
        let status = SFSpeechRecognizer.authorizationStatus()
        isAuthorized = (status == .authorized)
    }
    
    // MARK: - Authorization
    
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    let authorized = (status == .authorized)
                    self?.isAuthorized = authorized
                    if !authorized {
                        self?.logger.warning("Speech recognition not authorized: \(String(describing: status))")
                    }
                    continuation.resume(returning: authorized)
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    func setLanguage(_ languageCode: String) {
        let localeMapping: [String: String] = [
            "auto": "en-US", "en": "en-US", "es": "es-ES", "fr": "fr-FR",
            "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
            "pt": "pt-BR", "zh": "zh-CN", "ru": "ru-RU", "ar": "ar-SA",
            "hi": "hi-IN", "nl": "nl-NL", "pl": "pl-PL", "tr": "tr-TR",
            "vi": "vi-VN", "th": "th-TH", "id": "id-ID", "ms": "ms-MY"
        ]
        
        let identifier = localeMapping[languageCode] ?? "en-US"
        selectedLocale = Locale(identifier: identifier)
        logger.info("Language set to: \(identifier)")
    }
    
    func startListening() async throws {
        // Check authorization
        if !isAuthorized {
            let authorized = await requestAuthorization()
            guard authorized else {
                throw AppleSpeechError.notAuthorized
            }
        }
        
        guard !isListening else { return }
        
        // Check Apple Speech Mode setting
        let modeRaw = UserDefaults.standard.string(forKey: "lyricMode.appleSpeechMode") ?? "Standard"
        let useLegacy = modeRaw == "Legacy"
        let useDictation = modeRaw == "Dictation"
        
        // Try Native SpeechAnalyzer (Standard) on macOS 26+ if not using Legacy or Dictation
        // Note: Dictation mode uses SFSpeechRecognizer for maximum responsiveness (lowest latency)
        if #available(macOS 26, *), !useLegacy, !useDictation {
            // Check if locale is supported by SpeechTranscriber (handling _ vs -)
            let supportedLocales = await SpeechTranscriber.supportedLocales
            let isSupported = supportedLocales.contains { 
                $0.identifier.replacingOccurrences(of: "_", with: "-") == self.selectedLocale.identifier.replacingOccurrences(of: "_", with: "-") 
            }
            
            if isSupported {
                do {
                    try await startWithSpeechTranscriber()
                    return
                } catch {
                    logger.error("Failed to start SpeechAnalyzer: \(error.localizedDescription), falling back...")
                    stopListening()
                }
            } else {
                logger.warning("Locale \(self.selectedLocale.identifier) not supported by SpeechTranscriber, falling back to SFSpeechRecognizer")
            }
        }
        
        try await startWithSFSpeechRecognizer()
    }
    
    func stopListening() {
        if usingSpeechTranscriber {
            if #available(macOS 26, *) {
                stopSpeechTranscriber()
            }
        } else {
            stopSFSpeechRecognizer()
        }
        
        isListening = false
        logger.info("Apple Speech recognition stopped")
    }
    
    func pause() {
        audioEngine?.pause()
        logger.info("Apple Speech recognition paused")
    }
    
    func resume() {
        try? audioEngine?.start()
        logger.info("Apple Speech recognition resumed")
    }
    
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        if usingSpeechTranscriber {
            if #available(macOS 26, *) {
                // Send buffer to SpeechTranscriber via async stream
                let input = AnalyzerInput(buffer: buffer)
                if let continuation = inputContinuation as? AsyncStream<AnalyzerInput>.Continuation {
                    continuation.yield(input)
                }
            }
        } else {
            // Send to SFSpeechRecognizer
            recognitionRequest?.append(buffer)
        }
    }
    
    func clear() {
        transcript = ""
        partialTranscript = ""
        lastFinalizedText = ""
        clearedPublisher.send()
    }
    
    // MARK: - SpeechTranscriber (macOS 26+)
    
    @available(macOS 26, *)
    private func startWithSpeechTranscriber() async throws {
        logger.info("Starting SpeechTranscriber (macOS 26+) - optimized for low latency")
        usingSpeechTranscriber = true
        
        // Create async stream for audio input
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        
        // Create transcriber with maximum speed settings
        // .fastResults + .volatileResults = lowest latency configuration
        let transcriber = SpeechTranscriber(
            locale: selectedLocale,
            transcriptionOptions: [],  // No filtering - get all updates
            reportingOptions: [.volatileResults, .fastResults],  // Fast + volatile for lowest latency
            attributeOptions: []
        )
        
        // Create analyzer with transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        
        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AppleSpeechError.audioEngineError
        }
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Get best audio format for the analyzer
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            logger.error("Could not determine best audio format for SpeechTranscriber")
            throw AppleSpeechError.audioEngineError
        }
        
        // Create converter if formats differ (Native is usually Float32, Analyzer wants Int16)
        let converter = AVAudioConverter(from: recordingFormat, to: analyzerFormat)
        
        // High-priority queue for audio processing to minimize latency
        let audioProcessingQueue = DispatchQueue(label: "com.voiceink.audioProcessing", qos: .userInteractive)
        
        // Install tap with small buffer for maximum update frequency (256 = ~5ms at 48kHz)
        inputNode.installTap(onBus: 0, bufferSize: 256, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Process on high-priority queue
            audioProcessingQueue.async {
                var bufferToSend = buffer
                
                // Convert if needed
                if let converter = converter, converter.inputFormat != converter.outputFormat {
                    // Calculate output frame capacity
                    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                    
                    if let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) {
                        var error: NSError?
                        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                            outStatus.pointee = .haveData
                            return buffer
                        }
                        
                        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
                        
                        if error == nil {
                            bufferToSend = outputBuffer
                        }
                    }
                }
                
                // Send to analyzer
                let input = AnalyzerInput(buffer: bufferToSend)
                if let continuation = self.inputContinuation as? AsyncStream<AnalyzerInput>.Continuation {
                    continuation.yield(input)
                }
            }
        }
        
        // Warm up: Start the analyzer BEFORE audio engine to reduce initial latency
        recognitionTask = Task(priority: .userInitiated) {
            do {
                try await analyzer.start(inputSequence: stream)
                
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    
                    await MainActor.run {
                        // ALWAYS update partial transcript immediately for live feel
                        // This ensures we see text appearing as soon as recognizer has ANY hypothesis
                        if !result.isFinal {
                            self.partialTranscript = text
                        } else {
                            // Only finalize when truly final
                            if !text.isEmpty {
                                self.transcript += text
                                self.partialTranscript = ""
                                self.transcriptionPublisher.send(text)
                            }
                        }
                    }
                }
            } catch {
                self.logger.error("SpeechTranscriber error: \(error.localizedDescription)")
            }
        }
        
        // Small delay to allow analyzer to warm up
        try await Task.sleep(for: .milliseconds(100))
        
        // Start audio engine
        engine.prepare()
        try engine.start()
        
        isListening = true
        logger.info("SpeechTranscriber started with low-latency optimizations")
    }
    

    @available(macOS 26, *)
    private func stopSpeechTranscriber() {
        if let continuation = inputContinuation as? AsyncStream<AnalyzerInput>.Continuation {
            continuation.finish()
        }
        inputContinuation = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }
    
    // MARK: - SFSpeechRecognizer Fallback (older macOS)
    
    private func startWithSFSpeechRecognizer() async throws {
        logger.info("Starting SFSpeechRecognizer fallback (pre-macOS 26)")
        usingSpeechTranscriber = false
        
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: selectedLocale)
        }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw AppleSpeechError.requestCreationFailed
        }
        
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AppleSpeechError.audioEngineError
        }
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        legacyRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                
                DispatchQueue.main.async {
                    if result.isFinal {
                        let newText = self.extractNewText(from: text)
                        if !newText.isEmpty {
                            self.transcript = text
                            self.partialTranscript = ""
                            self.transcriptionPublisher.send(newText)
                            self.lastFinalizedText = text
                        }
                    } else {
                        self.partialTranscript = self.extractNewText(from: text)
                    }
                }
            }
            
            if let error = error as NSError? {
                let cancelCodes = [1, 216, 301, 1110]
                if cancelCodes.contains(error.code) { return }
                self.logger.error("Recognition error: \(error.localizedDescription)")
            }
        }
        
        engine.prepare()
        try engine.start()
        
        isListening = true
        
        // Schedule auto-restart for SFSpeechRecognizer (1-minute limit)
        scheduleAutoRestart()
        logger.info("SFSpeechRecognizer started (will restart every 55s)")
    }
    
    private func stopSFSpeechRecognizer() {
        restartTimer?.invalidate()
        restartTimer = nil
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        legacyRecognitionTask?.cancel()
        
        recognitionRequest = nil
        legacyRecognitionTask = nil
        audioEngine = nil
    }
    
    private func extractNewText(from fullText: String) -> String {
        if fullText.hasPrefix(lastFinalizedText) {
            let newPart = String(fullText.dropFirst(lastFinalizedText.count))
            return newPart.trimmingCharacters(in: .whitespaces)
        }
        return fullText
    }
    
    private func scheduleAutoRestart() {
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isListening, !self.usingSpeechTranscriber else { return }
                self.logger.debug("Auto-restarting SFSpeechRecognizer to avoid timeout")
                await self.performRestart()
            }
        }
    }
    
    private var isRestarting = false
    
    private func performRestart() async {
        guard isListening, !isRestarting, !usingSpeechTranscriber else { return }
        
        isRestarting = true
        defer { isRestarting = false }
        
        recognitionRequest?.endAudio()
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        legacyRecognitionTask?.cancel()
        legacyRecognitionTask = nil
        recognitionRequest = nil
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            logger.error("Recognizer unavailable during restart")
            return
        }
        
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = false
        recognitionRequest = newRequest
        
        lastFinalizedText = ""
        
        legacyRecognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error as NSError? {
                let cancelCodes = [1, 209, 216, 301, 1110]
                if cancelCodes.contains(error.code) { return }
            }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                
                DispatchQueue.main.async {
                    if result.isFinal {
                        if !text.isEmpty {
                            self.partialTranscript = ""
                            self.transcriptionPublisher.send(text)
                            self.lastFinalizedText = text
                        }
                    } else {
                        self.partialTranscript = text
                    }
                }
            }
            
            if let error = error, self.isListening, !self.isRestarting {
                self.logger.error("Recognition error: \(error.localizedDescription)")
            }
        }
        
        logger.debug("Recognition restarted successfully")
    }
}

// MARK: - Errors

enum AppleSpeechError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case requestCreationFailed
    case audioEngineError
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized"
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        case .audioEngineError:
            return "Audio engine error"
        }
    }
}
