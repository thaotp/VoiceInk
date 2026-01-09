import Foundation
import AVFoundation
import Speech
import Combine
import os

/// Real-time speech recognition service using Apple's SFSpeechRecognizer
/// Works on macOS 10.15+ for real-time streaming transcription
@MainActor
final class AppleSpeechRealtimeService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isListening = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var partialTranscript: String = ""
    
    /// Publisher for finalized transcription segments
    let transcriptionPublisher = PassthroughSubject<String, Never>()
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppleSpeechRealtime")
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    
    private var lastFinalizedText: String = ""
    private var restartTimer: Timer?
    
    // Configuration
    private var selectedLocale: Locale = Locale(identifier: "en-US")
    
    // MARK: - Initialization
    
    init() {
        // Check initial status without triggering request
        let status = SFSpeechRecognizer.authorizationStatus()
        isAuthorized = (status == .authorized)
    }
    
    // MARK: - Authorization
    
    /// Request speech recognition authorization
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
    
    /// Set the language for speech recognition
    func setLanguage(_ languageCode: String) {
        let localeMapping: [String: String] = [
            "auto": "en-US",
            "en": "en-US",
            "es": "es-ES",
            "fr": "fr-FR",
            "de": "de-DE",
            "it": "it-IT",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "zh": "zh-CN",
            "pt": "pt-BR",
            "ru": "ru-RU",
            "ar": "ar-SA",
            "hi": "hi-IN",
            "nl": "nl-NL",
            "pl": "pl-PL",
            "tr": "tr-TR",
            "vi": "vi-VN",
            "th": "th-TH"
        ]
        
        let localeId = localeMapping[languageCode] ?? "en-US"
        selectedLocale = Locale(identifier: localeId)
        speechRecognizer = SFSpeechRecognizer(locale: selectedLocale)
        
        logger.info("Apple Speech language set to: \(localeId)")
    }
    
    /// Start real-time speech recognition
    func startListening() async throws {
        // Request authorization if not already authorized
        if !isAuthorized {
            let authorized = await requestAuthorization()
            guard authorized else {
                throw AppleSpeechError.notAuthorized
            }
        }
        
        guard !isListening else { return }
        
        // Initialize recognizer if needed
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: selectedLocale)
        }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let request = recognitionRequest else {
            throw AppleSpeechError.requestCreationFailed
        }
        
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false // Allow cloud for better accuracy
        
        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AppleSpeechError.audioEngineError
        }
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap on input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                
                DispatchQueue.main.async {
                    if result.isFinal {
                        // Finalized result
                        let newText = self.extractNewText(from: text)
                        if !newText.isEmpty {
                            self.transcript = text
                            self.partialTranscript = ""
                            self.transcriptionPublisher.send(newText)
                            self.lastFinalizedText = text
                        }
                    } else {
                        // Partial result
                        self.partialTranscript = self.extractNewText(from: text)
                    }
                }
            }
            
            // Ignore expected cancellation errors during restart
            if let error = error as NSError? {
                // 216 = canceled, 1110 = request canceled - these are expected during restart
                if error.code == 216 || error.code == 1110 {
                    return
                }
                self.logger.error("Recognition error: \(error.localizedDescription)")
            }
        }
        
        // Start audio engine
        engine.prepare()
        try engine.start()
        
        isListening = true
        logger.info("Apple Speech recognition started")
        
        // Schedule periodic restart to handle the 1-minute limit
        scheduleAutoRestart()
    }
    
    /// Stop speech recognition
    func stopListening() {
        restartTimer?.invalidate()
        restartTimer = nil
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        
        isListening = false
        logger.info("Apple Speech recognition stopped")
    }
    
    /// Process audio samples directly (for integration with existing audio stream)
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }
    
    /// Clear transcript state
    func clearTranscript() {
        transcript = ""
        partialTranscript = ""
        lastFinalizedText = ""
    }
    
    // MARK: - Private Methods
    
    private func extractNewText(from fullText: String) -> String {
        if fullText.hasPrefix(lastFinalizedText) {
            let newPart = String(fullText.dropFirst(lastFinalizedText.count))
            return newPart.trimmingCharacters(in: .whitespaces)
        }
        return fullText
    }
    
    private func scheduleAutoRestart() {
        // Restart every 55 seconds to avoid the 1-minute limit
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isListening, !self.isRestarting else { return }
                self.logger.debug("Auto-restarting recognition to avoid timeout")
                await self.performRestart()
            }
        }
    }
    
    private var isRestarting = false
    
    private func performRestart() async {
        guard isListening, !isRestarting else { return }
        
        isRestarting = true
        defer { isRestarting = false }
        
        // End current request gracefully
        recognitionRequest?.endAudio()
        
        // Give it a moment to finalize
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Cancel old task
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        // Create new recognition
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            logger.error("Recognizer unavailable during restart")
            return
        }
        
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = false
        recognitionRequest = newRequest
        
        // Reset state for new session
        lastFinalizedText = ""
        
        recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            // Ignore cancellation errors during restart
            if let error = error as NSError?, error.code == 216 || error.code == 1110 {
                // 216 = canceled, 1110 = request canceled
                return
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
            
            // Only handle unexpected errors
            if let error = error, self.isListening, !self.isRestarting {
                self.logger.error("Recognition error: \(error.localizedDescription)")
            }
        }
        
        logger.debug("Recognition restarted successfully")
    }
}

// MARK: - Errors

enum AppleSpeechError: Error, LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case requestCreationFailed
    case audioEngineError
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is not authorized. Please enable it in System Settings > Privacy & Security > Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognizer is not available for the selected language."
        case .requestCreationFailed:
            return "Failed to create speech recognition request."
        case .audioEngineError:
            return "Failed to initialize audio engine."
        }
    }
}
