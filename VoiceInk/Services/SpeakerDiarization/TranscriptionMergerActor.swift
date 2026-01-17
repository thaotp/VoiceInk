import Foundation
import os

/// Actor that merges transcription words with speaker labels from diarization
actor TranscriptionMergerActor {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionMerger")
    
    private let diarizationActor: DiarizationMergerActor
    
    // Current segment being built
    private var currentSegment: TranscriptSegment?
    
    // All finalized segments
    private var allSegments: [TranscriptSegment] = []
    
    // Configuration
    private let speakerChangeThreshold: TimeInterval = 5.0  // Max gap before forcing new segment
    
    init(diarizationActor: DiarizationMergerActor) {
        self.diarizationActor = diarizationActor
    }
    
    // MARK: - Public Methods
    
    /// Process an incoming transcribed word
    func processWord(_ word: TranscribedWord) async -> TranscriptUpdate {
        let speakerResult = await diarizationActor.lookupSpeaker(at: word.timestamp)
        let speakerLabel = speakerResult.toLabel
        
        // Check if we should start a new segment
        if await shouldStartNewSegment(newSpeaker: speakerLabel, wordTimestamp: word.timestamp) {
            // Finalize current segment if exists
            if var current = currentSegment {
                current.isFinal = true
                allSegments.append(current)
                logger.debug("Finalized segment: \(current.speaker.displayName) - \(current.text)")
            }
            
            // Start new segment
            currentSegment = TranscriptSegment(
                id: UUID(),
                speaker: speakerLabel,
                words: [word],
                startTime: word.timestamp,
                endTime: word.timestamp + word.duration,
                isFinal: false
            )
            
            return .newSegmentStarted(currentSegment!)
        }
        
        // Append to current segment
        currentSegment?.words.append(word)
        currentSegment?.endTime = word.timestamp + word.duration
        
        // Update speaker if confidence improved
        if let current = currentSegment {
            if case .identified(_, let newConf) = speakerLabel,
               case .identified(_, let oldConf) = current.speaker,
               newConf > oldConf {
                currentSegment?.speaker = speakerLabel
            } else if case .unknown = current.speaker, case .identified = speakerLabel {
                // Upgrade from unknown to identified
                currentSegment?.speaker = speakerLabel
            }
        }
        
        return .segmentUpdated(currentSegment!)
    }
    
    /// Finalize current segment when speech ends
    func finalizeCurrentSegment() -> TranscriptUpdate? {
        guard var current = currentSegment else { return nil }
        
        current.isFinal = true
        allSegments.append(current)
        currentSegment = nil
        
        logger.debug("Finalized segment on speech end: \(current.speaker.displayName) - \(current.text)")
        
        return .segmentFinalized(current)
    }
    
    /// Get all segments (finalized + current)
    func getAllSegments() -> [TranscriptSegment] {
        var result = allSegments
        if let current = currentSegment {
            result.append(current)
        }
        return result
    }
    
    /// Get the current in-progress segment
    func getCurrentSegment() -> TranscriptSegment? {
        return currentSegment
    }
    
    /// Clear all segments
    func clear() {
        currentSegment = nil
        allSegments.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func shouldStartNewSegment(newSpeaker: SpeakerLabel, wordTimestamp: TimeInterval) async -> Bool {
        guard let current = currentSegment else { return true }
        
        // Check for speaker change (comparing speaker IDs)
        if let currentID = current.speaker.speakerID,
           let newID = newSpeaker.speakerID,
           currentID != newID {
            logger.debug("Speaker change detected: \(currentID.description) -> \(newID.description)")
            return true
        }
        
        // Unknown -> Identified (don't split)
        // Identified -> Unknown (don't split for short gaps)
        
        // Check time gap
        if let lastWord = current.words.last {
            let gap = wordTimestamp - (lastWord.timestamp + lastWord.duration)
            if gap > speakerChangeThreshold {
                logger.debug("Time gap > \(self.speakerChangeThreshold)s, starting new segment")
                return true
            }
        }
        
        return false
    }
}
