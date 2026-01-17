import Foundation
import AVFoundation
import Combine
import os

// WhisperKit is imported conditionally - add WhisperKit to your target's 
// "Frameworks, Libraries, and Embedded Content" section in Xcode to enable it
#if canImport(WhisperKit)
import WhisperKit
private let whisperKitAvailable = true
#else
private let whisperKitAvailable = false
#endif

/// Real-time transcription service using WhisperKit (CoreML-optimized Whisper)
@MainActor
final class WhisperKitRealtimeService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isListening = false
    @Published private(set) var isModelLoaded = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var partialTranscript: String = ""
    @Published private(set) var currentModelName: String = ""
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?
    
    // MARK: - Publishers
    
    let transcriptionPublisher = PassthroughSubject<String, Never>()
    let clearedPublisher = PassthroughSubject<Void, Never>()
    
    // MARK: - Private Properties
    
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif
    
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let audioBufferLock = NSLock()
    private var transcriptionTask: Task<Void, Never>?
    private var isProcessing = false
    
    private var selectedLanguage: String = "auto"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperKitRealtimeService")
    
    // Configuration
    private let sampleRate: Double = 16000
    private let minAudioLengthSeconds: Double = 0.5
    private let maxAudioLengthSeconds: Double = 30.0
    private let transcriptionIntervalSeconds: Double = 1.0
    
    // MARK: - Initialization
    
    init() {}
    
    deinit {
        // Note: Cannot call stopListening() directly as it's MainActor-isolated
        // Cleanup is handled by the caller or when the object is deallocated
        transcriptionTask?.cancel()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
    }
    
    // MARK: - Availability Check
    
    static var isWhisperKitAvailable: Bool {
        return whisperKitAvailable
    }
    
    private func checkAvailability() throws {
        guard whisperKitAvailable else {
            throw NSError(domain: "WhisperKitRealtimeService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "WhisperKit is not linked to the target. Please go to your target's 'Frameworks, Libraries, and Embedded Content' section and add WhisperKit."])
        }
    }
    
    // MARK: - Model Management
    
    /// Fetch available models from HuggingFace
    func fetchAvailableModels(from repo: String = "argmaxinc/whisperkit-coreml") async {
        #if canImport(WhisperKit)
        do {
            let models = try await WhisperKit.fetchAvailableModels(from: repo)
            await MainActor.run {
                self.availableModels = models.sorted()
            }
            logger.info("Fetched \(models.count) available WhisperKit models")
        } catch {
            logger.error("Failed to fetch available models: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Failed to fetch models: \(error.localizedDescription)"
            }
        }
        #else
        await MainActor.run {
            self.errorMessage = "WhisperKit is not linked. Add WhisperKit to your target's frameworks."
        }
        #endif
    }
    
    /// Get recommended model for this device
    func getRecommendedModel() async -> String? {
        #if canImport(WhisperKit)
        let modelSupport = await WhisperKit.recommendedRemoteModels()
        return modelSupport.default
        #else
        return "openai_whisper-tiny"
        #endif
    }
    
    /// Download and load a specific model
    func loadModel(_ modelName: String, from repo: String = "argmaxinc/whisperkit-coreml") async throws {
        try checkAvailability()
        
        #if canImport(WhisperKit)
        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = 0
            self.errorMessage = nil
        }
        
        do {
            logger.info("Loading WhisperKit model: \(modelName)")
            
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: repo,
                verbose: true,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: true
            )
            
            let kit = try await WhisperKit(config)
            
            await MainActor.run {
                self.whisperKit = kit
                self.isModelLoaded = true
                self.currentModelName = modelName
                self.isDownloading = false
                self.downloadProgress = 1.0
            }
            
            logger.info("WhisperKit model loaded successfully: \(modelName)")
            
        } catch {
            logger.error("Failed to load WhisperKit model: \(error.localizedDescription)")
            await MainActor.run {
                self.isDownloading = false
                self.errorMessage = "Failed to load model: \(error.localizedDescription)"
            }
            throw error
        }
        #endif
    }
    
    /// Unload the current model to free memory
    func unloadModel() {
        #if canImport(WhisperKit)
        whisperKit = nil
        #endif
        isModelLoaded = false
        currentModelName = ""
        logger.info("WhisperKit model unloaded")
    }
    
    // MARK: - Language
    
    func setLanguage(_ languageCode: String) {
        selectedLanguage = languageCode
        logger.info("Language set to: \(languageCode)")
    }
    
    // MARK: - Audio Recording
    
    func startListening() async throws {
        try checkAvailability()
        
        guard isModelLoaded else {
            throw NSError(domain: "WhisperKitRealtimeService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model not loaded. Please load a WhisperKit model first."])
        }
        
        guard !isListening else { return }
        
        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "WhisperKitRealtimeService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Create converter if needed (to 16kHz mono)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false)!
        
        let converter = AVAudioConverter(from: recordingFormat, to: targetFormat)
        
        // Reset audio buffer
        audioBufferLock.lock()
        audioBuffer = []
        audioBufferLock.unlock()
        
        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Convert to target format
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / recordingFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            converter?.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            if error == nil, let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                
                self.audioBufferLock.lock()
                self.audioBuffer.append(contentsOf: samples)
                
                // Limit buffer size to prevent memory issues
                let maxSamples = Int(self.maxAudioLengthSeconds * self.sampleRate)
                if self.audioBuffer.count > maxSamples {
                    self.audioBuffer = Array(self.audioBuffer.suffix(maxSamples))
                }
                self.audioBufferLock.unlock()
            }
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
        
        isListening = true
        logger.info("WhisperKit real-time listening started")
        
        // Start periodic transcription
        startTranscriptionLoop()
    }
    
    func stopListening() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        isListening = false
        isProcessing = false
        
        // Final transcription of remaining audio
        Task {
            await processFinalTranscription()
        }
        
        logger.info("WhisperKit real-time listening stopped")
    }
    
    func pause() {
        audioEngine?.pause()
        logger.info("WhisperKit listening paused")
    }
    
    func resume() {
        try? audioEngine?.start()
        logger.info("WhisperKit listening resumed")
    }
    
    func clear() {
        transcript = ""
        partialTranscript = ""
        audioBufferLock.lock()
        audioBuffer = []
        audioBufferLock.unlock()
        clearedPublisher.send()
    }
    
    // MARK: - Transcription
    
    private func startTranscriptionLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.transcriptionIntervalSeconds ?? 1.0))
                await self?.processAudioBuffer()
            }
        }
    }
    
    private func processAudioBuffer() async {
        guard !isProcessing, isListening else { return }
        
        audioBufferLock.lock()
        let minSamples = Int(minAudioLengthSeconds * sampleRate)
        guard audioBuffer.count >= minSamples else {
            audioBufferLock.unlock()
            return
        }
        
        let samplesToProcess = audioBuffer
        audioBufferLock.unlock()
        
        await transcribe(samples: samplesToProcess, isFinal: false)
    }
    
    private func processFinalTranscription() async {
        audioBufferLock.lock()
        let remainingSamples = audioBuffer
        audioBuffer = []
        audioBufferLock.unlock()
        
        if !remainingSamples.isEmpty {
            await transcribe(samples: remainingSamples, isFinal: true)
        }
    }
    
    private func transcribe(samples: [Float], isFinal: Bool) async {
        #if canImport(WhisperKit)
        guard let whisperKit = whisperKit else { return }
        
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            var options = DecodingOptions()
            
            // Set language if not auto
            if selectedLanguage != "auto" {
                options.language = selectedLanguage
            }
            
            // Run transcription
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            
            guard let result = results.first else { return }
            
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Clean artifacts
            let cleanedText = cleanTranscription(text)
            
            guard !cleanedText.isEmpty else { return }
            
            await MainActor.run {
                if isFinal {
                    // Confirm the transcription
                    if !cleanedText.isEmpty {
                        if !self.transcript.isEmpty {
                            self.transcript += "\n"
                        }
                        self.transcript += cleanedText
                        self.partialTranscript = ""
                        self.transcriptionPublisher.send(cleanedText)
                        
                        // Clear the buffer after final transcription
                        self.audioBufferLock.lock()
                        self.audioBuffer = []
                        self.audioBufferLock.unlock()
                    }
                } else {
                    // Update partial transcription
                    self.partialTranscript = cleanedText
                }
            }
            
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
        }
        #endif
    }
    
    private func cleanTranscription(_ text: String) -> String {
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
            "(silence)",
            "[ Music ]",
            "[Music]",
            "♪",
            "..."
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
}
