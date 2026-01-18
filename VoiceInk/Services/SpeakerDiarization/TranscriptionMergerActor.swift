import Foundation
import NaturalLanguage
import os

/// Actor that merges transcription words with speaker labels from diarization
/// Uses NLTokenizer for sentence boundary detection instead of Apple's isFinal flag
actor TranscriptionMergerActor {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionMerger")
    
    private let diarizationActor: DiarizationMergerActor
    
    // Current segment being built
    private var currentSegment: TranscriptSegment?
    
    // All finalized segments
    private var allSegments: [TranscriptSegment] = []
    
    // Accumulated text buffer for sentence detection
    private var textBuffer: String = ""
    private var wordsBuffer: [TranscribedWord] = []
    
    // Configuration
    private let speakerChangeThreshold: TimeInterval = 5.0  // Max gap before forcing new segment
    
    // NLTokenizer for sentence detection
    private let sentenceTokenizer = NLTokenizer(unit: .sentence)
    
    init(diarizationActor: DiarizationMergerActor) {
        self.diarizationActor = diarizationActor
    }
    
    // MARK: - Public Methods
    
    /// Process an incoming transcribed word
    func processWord(_ word: TranscribedWord) async -> TranscriptUpdate {
        let speakerResult = await diarizationActor.lookupSpeaker(at: word.timestamp)
        let speakerLabel = speakerResult.toLabel
        
        // Check if we should start a new segment due to speaker change or long gap
        if await shouldStartNewSegment(newSpeaker: speakerLabel, wordTimestamp: word.timestamp) {
            // Finalize current segment if exists
            if var current = currentSegment {
                current.isFinal = true
                allSegments.append(current)
                logger.debug("Finalized segment (speaker change): \(current.speaker.displayName) - \(current.text)")
            }
            
            // Clear buffers for new speaker
            textBuffer = ""
            wordsBuffer = []
            
            // Start new segment
            currentSegment = TranscriptSegment(
                id: UUID(),
                speaker: speakerLabel,
                words: [word],
                startTime: word.timestamp,
                endTime: word.timestamp + word.duration,
                isFinal: false
            )
            
            textBuffer = word.text
            wordsBuffer = [word]
            
            return .newSegmentStarted(currentSegment!)
        }
        
        // Append to current segment
        currentSegment?.words.append(word)
        currentSegment?.endTime = word.timestamp + word.duration
        
        // Update text buffer
        if textBuffer.isEmpty {
            textBuffer = word.text
        } else {
            textBuffer += " " + word.text
        }
        wordsBuffer.append(word)
        
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
        
        // Check for sentence boundary using NLTokenizer
        if let sentenceSplit = detectCompleteSentence(in: textBuffer) {
            // We have a complete sentence with trailing text - finalize it
            return await finalizeSentence(sentenceSplit.sentence, remainingText: sentenceSplit.remaining, speakerLabel: speakerLabel)
        }
        
        return .segmentUpdated(currentSegment!)
    }
    
    /// Finalize current segment when speech ends (force finalization)
    func finalizeCurrentSegment() -> TranscriptUpdate? {
        guard var current = currentSegment else { return nil }
        
        current.isFinal = true
        allSegments.append(current)
        currentSegment = nil
        
        // Clear buffers
        textBuffer = ""
        wordsBuffer = []
        
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
        textBuffer = ""
        wordsBuffer = []
    }
    
    // MARK: - Private Methods
    
    /// Detect if there's a complete sentence followed by more text
    /// Returns the sentence and remaining text if found, nil otherwise
    private func detectCompleteSentence(in text: String) -> (sentence: String, remaining: String)? {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        guard !trimmedText.isEmpty else { return nil }
        
        sentenceTokenizer.string = trimmedText
        
        var sentences: [Range<String.Index>] = []
        sentenceTokenizer.enumerateTokens(in: trimmedText.startIndex..<trimmedText.endIndex) { tokenRange, _ in
            sentences.append(tokenRange)
            return true
        }
        
        // We need at least 2 sentences (or 1 complete sentence with trailing text)
        // to consider the first sentence "complete"
        guard sentences.count >= 2 else {
            // Check if single sentence ends with sentence-ending punctuation and has trailing content
            if sentences.count == 1 {
                let sentence = String(trimmedText[sentences[0]])
                let afterSentence = trimmedText.index(sentences[0].upperBound, offsetBy: 0, limitedBy: trimmedText.endIndex) ?? trimmedText.endIndex
                let remaining = String(trimmedText[afterSentence...]).trimmingCharacters(in: .whitespaces)
                
                // Only split if there's actual content after the sentence
                if !remaining.isEmpty {
                    return (sentence: sentence, remaining: remaining)
                }
            }
            return nil
        }
        
        // Return first sentence and everything after it
        let firstSentence = String(trimmedText[sentences[0]])
        let afterFirst = sentences[0].upperBound
        let remaining = String(trimmedText[afterFirst...]).trimmingCharacters(in: .whitespaces)
        
        return (sentence: firstSentence, remaining: remaining)
    }
    
    /// Finalize a complete sentence and start a new segment with remaining text
    private func finalizeSentence(_ sentence: String, remainingText: String, speakerLabel: SpeakerLabel) async -> TranscriptUpdate {
        guard var current = currentSegment else {
            return .segmentUpdated(currentSegment!)
        }
        
        // Update the current segment with just the complete sentence
        // Find words that belong to the sentence (approximate by character count)
        let sentenceWordCount = sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        let sentenceWords = Array(wordsBuffer.prefix(sentenceWordCount))
        let remainingWords = Array(wordsBuffer.dropFirst(sentenceWordCount))
        
        current.words = sentenceWords
        current.isFinal = true
        if let lastWord = sentenceWords.last {
            current.endTime = lastWord.timestamp + lastWord.duration
        }
        
        allSegments.append(current)
        logger.debug("Finalized sentence: \(current.speaker.displayName) - \(sentence)")
        
        // Start new segment with remaining text
        let newSegmentId = UUID()
        let startTime = remainingWords.first?.timestamp ?? current.endTime
        
        currentSegment = TranscriptSegment(
            id: newSegmentId,
            speaker: speakerLabel,
            words: remainingWords,
            startTime: startTime,
            endTime: remainingWords.last.map { $0.timestamp + $0.duration } ?? startTime,
            isFinal: false
        )
        
        // Update buffers
        textBuffer = remainingText
        wordsBuffer = remainingWords
        
        // Return the finalized segment
        return .segmentFinalized(current)
    }
    
    private func shouldStartNewSegment(newSpeaker: SpeakerLabel, wordTimestamp: TimeInterval) async -> Bool {
        guard let current = currentSegment else { return true }
        
        // Check for speaker change (comparing speaker IDs)
        // COMMENTED OUT FOR TESTING: Disable forced split on speaker change
        /*
        if let currentID = current.speaker.speakerID,
           let newID = newSpeaker.speakerID,
           currentID != newID {
            logger.debug("Speaker change detected: \(currentID.description) -> \(newID.description)")
            return true
        }
        */
        
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
