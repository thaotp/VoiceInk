import Foundation
import FluidAudio
import Combine
import os

/// Voice Activity Detection service using FluidAudio's neural network-based VAD
/// More accurate than energy-based detection, especially in noisy environments
@MainActor
final class FluidAudioVADService: ObservableObject {
    
    // MARK: - Speech State
    
    enum SpeechState: Equatable {
        case silence
        case speechStart
        case speaking
        case speechEnd
    }
    
    // MARK: - Published Properties
    
    @Published private(set) var currentState: SpeechState = .silence
    @Published private(set) var isSpeaking = false
    @Published private(set) var currentProbability: Float = 0.0
    
    // MARK: - State Change Publisher
    
    let stateChangePublisher = PassthroughSubject<SpeechState, Never>()
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Probability threshold for detecting speech (0.0-1.0)
        var speechThreshold: Float = 0.5
        /// Probability threshold for detecting silence (0.0-1.0)
        var silenceThreshold: Float = 0.3
        /// Minimum duration of speech to confirm (in seconds)
        var minSpeechDuration: TimeInterval = 0.25
        /// Minimum duration of silence to confirm end of speech (in seconds)
        var minSilenceDuration: TimeInterval = 0.5
        /// Maximum duration before forcing sentence break (hard timeout)
        var maxSilenceDuration: TimeInterval = 2.0
    }
    
    var configuration = Configuration()
    
    // MARK: - Private Properties
    
    private var vadManager: VadManager?
    private var streamState: VadStreamState?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioVAD")
    
    private var speechStartTime: Date?
    private var silenceStartTime: Date?
    private var lastSpeechTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    private var isInitialized = false
    
    // MARK: - Initialization
    
    init() {}
    
    /// Initialize the VAD manager - must be called before processing
    func initialize() async throws {
        guard !isInitialized else { return }
        
        let config = VadConfig(defaultThreshold: configuration.speechThreshold)
        vadManager = try await VadManager(config: config)
        streamState = await vadManager?.makeStreamState()
        isInitialized = true
        logger.info("FluidAudio VAD initialized successfully")
    }
    
    // MARK: - Public Methods
    
    /// Process an audio chunk and update VAD state
    func processAudioChunk(_ samples: [Float], timestamp: Date) async {
        guard let vadManager = vadManager, let state = streamState else {
            logger.warning("VAD not initialized, skipping chunk")
            return
        }
        
        do {
            let result = try await vadManager.processStreamingChunk(
                samples,
                state: state,
                config: .default,
                returnSeconds: true,
                timeResolution: 2
            )
            
            // Update stream state
            streamState = result.state
            currentProbability = result.probability
            
            // Handle speech events from FluidAudio
            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    handleSpeechStart(timestamp: timestamp)
                case .speechEnd:
                    handleSpeechEnd(timestamp: timestamp)
                @unknown default:
                    break
                }
            }
            
            // Also use probability for additional state management
            updateStateFromProbability(result.probability, timestamp: timestamp)
            
        } catch {
            logger.error("VAD processing failed: \(error.localizedDescription)")
        }
    }
    
    /// Reset VAD state
    func reset() async {
        currentState = .silence
        isSpeaking = false
        speechStartTime = nil
        silenceStartTime = nil
        lastSpeechTime = nil
        currentProbability = 0.0
        
        // Reset stream state
        if let vadManager = vadManager {
            streamState = await vadManager.makeStreamState()
        }
    }
    
    /// Connect to audio stream service for automatic processing
    func connect(to audioStream: RealtimeAudioStreamService) {
        audioStream.audioChunkPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                Task { @MainActor in
                    await self?.processAudioChunk(chunk.samples, timestamp: chunk.timestamp)
                }
            }
            .store(in: &cancellables)
    }
    
    func disconnect() {
        cancellables.removeAll()
    }
    
    func cleanup() {
        disconnect()
        vadManager = nil
        streamState = nil
        isInitialized = false
    }
    
    // MARK: - Private Methods
    
    private func handleSpeechStart(timestamp: Date) {
        if currentState == .silence {
            speechStartTime = timestamp
            transitionTo(.speechStart)
        }
    }
    
    private func handleSpeechEnd(timestamp: Date) {
        if currentState == .speaking || currentState == .speechStart {
            transitionTo(.speechEnd)
        }
    }
    
    private func updateStateFromProbability(_ probability: Float, timestamp: Date) {
        switch currentState {
        case .silence:
            if probability > configuration.speechThreshold {
                if speechStartTime == nil {
                    speechStartTime = timestamp
                } else if let startTime = speechStartTime,
                          timestamp.timeIntervalSince(startTime) >= configuration.minSpeechDuration {
                    transitionTo(.speechStart)
                    transitionTo(.speaking)
                }
            } else {
                speechStartTime = nil
            }
            
        case .speechStart:
            if probability > configuration.speechThreshold {
                if let startTime = speechStartTime,
                   timestamp.timeIntervalSince(startTime) >= configuration.minSpeechDuration {
                    transitionTo(.speaking)
                }
            } else {
                speechStartTime = nil
                transitionTo(.silence)
            }
            
        case .speaking:
            if probability > configuration.speechThreshold {
                // Still speaking
                silenceStartTime = nil
                lastSpeechTime = timestamp
            } else if probability < configuration.silenceThreshold {
                // Low probability, start silence timer
                if silenceStartTime == nil {
                    silenceStartTime = timestamp
                } else if let silenceStart = silenceStartTime,
                          timestamp.timeIntervalSince(silenceStart) >= configuration.minSilenceDuration {
                    transitionTo(.speechEnd)
                }
            }
            
            // Hard timeout: force end if no speech for maxSilenceDuration
            if let lastSpeech = lastSpeechTime,
               timestamp.timeIntervalSince(lastSpeech) >= configuration.maxSilenceDuration {
                transitionTo(.speechEnd)
            }
            
        case .speechEnd:
            // Automatically transition back to silence
            silenceStartTime = nil
            speechStartTime = nil
            lastSpeechTime = nil
            transitionTo(.silence)
        }
    }
    
    private func transitionTo(_ newState: SpeechState) {
        guard newState != currentState else { return }
        
        let previousState = currentState
        currentState = newState
        
        // Update isSpeaking convenience flag
        switch newState {
        case .speechStart, .speaking:
            isSpeaking = true
        case .silence, .speechEnd:
            isSpeaking = false
        }
        
        logger.debug("FluidAudio VAD: \(String(describing: previousState)) → \(String(describing: newState)) (prob: \(self.currentProbability))")
        stateChangePublisher.send(newState)
    }
}
