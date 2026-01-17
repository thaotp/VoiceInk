import Foundation
import AVFoundation

// MARK: - Audio Timing

/// Precise audio timestamp for synchronization between transcription and diarization streams
struct AudioTimestamp: Sendable, Equatable {
    let hostTime: UInt64           // mach_absolute_time
    let sampleTime: AVAudioFramePosition
    let sampleRate: Double
    
    static let zero = AudioTimestamp(hostTime: 0, sampleTime: 0, sampleRate: 16000)
    
    /// Convert to seconds since stream start
    func seconds(relativeTo base: AudioTimestamp) -> TimeInterval {
        return Double(sampleTime - base.sampleTime) / sampleRate
    }
    
    /// Advance by sample count
    func advanced(bySamples count: Int) -> AudioTimestamp {
        AudioTimestamp(
            hostTime: hostTime,
            sampleTime: sampleTime + AVAudioFramePosition(count),
            sampleRate: sampleRate
        )
    }
    
    /// Create from AVAudioTime
    init(from time: AVAudioTime, sampleRate: Double) {
        self.hostTime = time.hostTime
        self.sampleTime = time.sampleTime
        self.sampleRate = sampleRate
    }
    
    init(hostTime: UInt64, sampleTime: AVAudioFramePosition, sampleRate: Double) {
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
    }
}

// MARK: - Speaker Identification

/// Unique speaker identifier (0-indexed, reassigned per session)
struct SpeakerID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: Int
    
    static let unknown = SpeakerID(rawValue: -1)
    
    var description: String {
        if rawValue < 0 {
            return "Unknown"
        }
        return "Speaker \(Character(UnicodeScalar(65 + rawValue)!))"  // A, B, C...
    }
    
    var shortLabel: String {
        if rawValue < 0 {
            return "?"
        }
        return String(Character(UnicodeScalar(65 + rawValue)!))  // A, B, C...
    }
}

/// Speaker label for UI display with confidence
enum SpeakerLabel: Sendable, Equatable {
    case identified(SpeakerID, confidence: Double)
    case unknown
    case silence
    
    var speakerID: SpeakerID? {
        switch self {
        case .identified(let id, _): return id
        case .unknown, .silence: return nil
        }
    }
    
    var displayName: String {
        switch self {
        case .identified(let id, _): return id.description
        case .unknown: return "Unknown Speaker"
        case .silence: return "[Silence]"
        }
    }
    
    var shortLabel: String {
        switch self {
        case .identified(let id, _): return id.shortLabel
        case .unknown: return "?"
        case .silence: return "…"
        }
    }
    
    /// Color for UI (hex string)
    var color: String {
        switch self {
        case .identified(let id, _):
            let colors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7", "#DDA0DD", "#87CEEB", "#FFA07A"]
            return colors[abs(id.rawValue) % colors.count]
        case .unknown: return "#808080"
        case .silence: return "#C0C0C0"
        }
    }
    
    var confidence: Double {
        switch self {
        case .identified(_, let conf): return conf
        case .unknown, .silence: return 0.0
        }
    }
}

// MARK: - Diarization Types

/// Raw diarization result from the diarization model
struct SpeakerSegment: Sendable {
    let speakerID: SpeakerID
    let startTime: TimeInterval    // Seconds since stream start
    let endTime: TimeInterval
    let confidence: Double         // 0.0 - 1.0
    
    var duration: TimeInterval {
        endTime - startTime
    }
}

/// Audio window sent to diarization model for inference
struct DiarizationWindow: Sendable {
    let samples: [Float]
    let startTimestamp: AudioTimestamp
    let duration: TimeInterval
    
    var endTimestamp: AudioTimestamp {
        startTimestamp.advanced(bySamples: samples.count)
    }
}

/// Chunk of audio for diarization pipeline
struct DiarizationChunk: Sendable {
    let samples: [Float]
    let timestamp: AudioTimestamp
    
    var duration: TimeInterval {
        Double(samples.count) / timestamp.sampleRate
    }
}

// MARK: - Transcription Types

/// Individual transcribed word with timing information
struct TranscribedWord: Sendable, Identifiable {
    let id: UUID
    let text: String
    let timestamp: TimeInterval    // Seconds since stream start
    let duration: TimeInterval
    let confidence: Double
    let isFinal: Bool
    
    init(
        id: UUID = UUID(),
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        confidence: Double = 1.0,
        isFinal: Bool = false
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

// MARK: - Combined Transcript

/// Combined transcript segment with speaker attribution
struct TranscriptSegment: Identifiable, Sendable {
    let id: UUID
    var speaker: SpeakerLabel
    var words: [TranscribedWord]
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
    private var _text: String?
    
    var text: String {
        get {
            _text ?? words.map(\.text).joined(separator: " ")
        }
        set {
            _text = newValue
        }
    }
    
    var duration: TimeInterval {
        endTime - startTime
    }
    
    var isEmpty: Bool {
        words.isEmpty && (_text?.isEmpty ?? true)
    }
    
    init(
        id: UUID = UUID(),
        speaker: SpeakerLabel,
        words: [TranscribedWord] = [],
        text: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isFinal: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.words = words
        self._text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
    }
}

// MARK: - Update Events

/// Update sent to UI when transcript changes
enum TranscriptUpdate: Sendable {
    case segmentUpdated(TranscriptSegment)
    case newSegmentStarted(TranscriptSegment)
    case segmentFinalized(TranscriptSegment)
}

/// Result of speaker lookup in the diarization buffer
enum SpeakerLookupResult: Sendable {
    case speaker(SpeakerID, confidence: Double)
    case silence
    case unknown
    
    var toLabel: SpeakerLabel {
        switch self {
        case .speaker(let id, let conf): return .identified(id, confidence: conf)
        case .silence: return .silence
        case .unknown: return .unknown
        }
    }
}
