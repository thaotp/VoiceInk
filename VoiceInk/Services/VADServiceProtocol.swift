import Foundation
import Combine

/// Protocol for Voice Activity Detection services
/// Allows RealtimeTranscriptionEngine to work with different VAD implementations
protocol VADServiceProtocol: ObservableObject {
    /// Current speech state
    var isSpeaking: Bool { get }
    
    /// Publisher for state changes
    var stateChangePublisher: PassthroughSubject<VADSpeechState, Never> { get }
    
    /// Configuration for silence detection
    var minSilenceDuration: TimeInterval { get set }
    var maxSilenceDuration: TimeInterval { get set }
    
    /// Connect to audio stream
    func connect(to audioStream: RealtimeAudioStreamService)
    
    /// Disconnect from audio stream
    func disconnect()
    
    /// Reset VAD state
    func reset() async
}

/// Common speech state used by all VAD implementations
enum VADSpeechState: Equatable {
    case silence
    case speechStart
    case speaking
    case speechEnd
}

// MARK: - RealtimeVADService Conformance

extension RealtimeVADService {
    /// Convert internal state to common VADSpeechState
    static func toCommonState(_ state: SpeechState) -> VADSpeechState {
        switch state {
        case .silence: return .silence
        case .speechStart: return .speechStart
        case .speaking: return .speaking
        case .speechEnd: return .speechEnd
        }
    }
}

// MARK: - FluidAudioVADService Conformance

extension FluidAudioVADService {
    /// Convert internal state to common VADSpeechState
    static func toCommonState(_ state: SpeechState) -> VADSpeechState {
        switch state {
        case .silence: return .silence
        case .speechStart: return .speechStart
        case .speaking: return .speaking
        case .speechEnd: return .speechEnd
        }
    }
}
