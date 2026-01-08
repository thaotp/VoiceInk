import Foundation
import Combine
import os

/// Voice Activity Detection service using energy-based analysis
/// Detects speech segments and provides state transitions for transcription segmentation
@MainActor
final class RealtimeVADService: ObservableObject {
    
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
    @Published private(set) var currentPower: Float = -60.0
    @Published private(set) var ambientNoiseFloor: Float = -50.0
    
    // MARK: - State Change Publisher
    
    let stateChangePublisher = PassthroughSubject<SpeechState, Never>()
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Threshold above noise floor to detect speech (in dB)
        var speechThresholdOffset: Float = 10.0
        /// Threshold below speech to detect silence (in dB)
        var silenceThresholdOffset: Float = 3.0
        /// Minimum duration of speech to confirm (in seconds)
        var minSpeechDuration: TimeInterval = 0.25
        /// Minimum duration of silence to confirm end of speech (in seconds)
        var minSilenceDuration: TimeInterval = 0.4
        /// Maximum duration before forcing sentence break (hard timeout)
        var maxSilenceDuration: TimeInterval = 2.0
        /// Alpha for exponential moving average of noise floor
        var noiseFloorAlpha: Float = 0.01
        /// Maximum noise floor (prevents runaway adaptation)
        var maxNoiseFloor: Float = -30.0
        /// Minimum noise floor
        var minNoiseFloor: Float = -60.0
    }
    
    var configuration = Configuration()
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RealtimeVAD")
    
    private var speechStartTime: Date?
    private var silenceStartTime: Date?
    private var lastSpeechTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    private var speechThreshold: Float {
        ambientNoiseFloor + configuration.speechThresholdOffset
    }
    
    private var silenceThreshold: Float {
        ambientNoiseFloor + configuration.silenceThresholdOffset
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Process an audio chunk and update VAD state
    func processAudioChunk(_ chunk: AudioChunk) {
        let power = chunk.power
        currentPower = power
        
        // Update noise floor during silence
        if currentState == .silence {
            updateNoiseFloor(power)
        }
        
        // State machine transitions
        switch currentState {
        case .silence:
            if power > speechThreshold {
                speechStartTime = chunk.timestamp
                transitionTo(.speechStart)
            }
            
        case .speechStart:
            if power > speechThreshold {
                if let startTime = speechStartTime,
                   chunk.timestamp.timeIntervalSince(startTime) >= configuration.minSpeechDuration {
                    transitionTo(.speaking)
                }
            } else {
                // False start, return to silence
                speechStartTime = nil
                transitionTo(.silence)
            }
            
        case .speaking:
            if power < silenceThreshold {
                if silenceStartTime == nil {
                    silenceStartTime = chunk.timestamp
                } else if let silenceStart = silenceStartTime,
                          chunk.timestamp.timeIntervalSince(silenceStart) >= configuration.minSilenceDuration {
                    transitionTo(.speechEnd)
                }
            } else {
                // Still speaking, reset silence timer and update last speech time
                silenceStartTime = nil
                lastSpeechTime = chunk.timestamp
            }
            
            // Hard timeout: if no loud speech for maxSilenceDuration, force end
            if let lastSpeech = lastSpeechTime,
               chunk.timestamp.timeIntervalSince(lastSpeech) >= configuration.maxSilenceDuration {
                transitionTo(.speechEnd)
            }
            
        case .speechEnd:
            // Automatically transition back to silence
            silenceStartTime = nil
            speechStartTime = nil
            transitionTo(.silence)
        }
    }
    
    /// Reset VAD state
    func reset() {
        currentState = .silence
        isSpeaking = false
        speechStartTime = nil
        silenceStartTime = nil
        lastSpeechTime = nil
        currentPower = -60.0
    }
    
    /// Connect to audio stream service for automatic processing
    func connect(to audioStream: RealtimeAudioStreamService) {
        audioStream.audioChunkPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                self?.processAudioChunk(chunk)
            }
            .store(in: &cancellables)
    }
    
    func disconnect() {
        cancellables.removeAll()
    }
    
    // MARK: - Private Methods
    
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
        
        logger.debug("VAD: \(String(describing: previousState)) → \(String(describing: newState)) (power: \(self.currentPower) dB)")
        stateChangePublisher.send(newState)
    }
    
    private func updateNoiseFloor(_ power: Float) {
        // Exponential moving average for noise floor adaptation
        // Only update when power is below current noise floor + small margin
        if power < ambientNoiseFloor + 5.0 {
            let alpha = configuration.noiseFloorAlpha
            let newFloor = alpha * power + (1 - alpha) * ambientNoiseFloor
            
            // Clamp to reasonable range
            ambientNoiseFloor = min(
                max(newFloor, configuration.minNoiseFloor),
                configuration.maxNoiseFloor
            )
        }
    }
}

// MARK: - Speech Segment

/// Represents a completed speech segment for transcription
struct SpeechSegment {
    let startTime: Date
    let endTime: Date
    let samples: [Float]
    
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}
