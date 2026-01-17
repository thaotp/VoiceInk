import Foundation
import AVFoundation
import os

/// Thread-safe actor that buffers diarization results and provides timestamp-based speaker lookups
actor DiarizationMergerActor {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DiarizationMerger")
    
    // Ring buffer of speaker segments, sorted by time
    private var speakerSegments: [SpeakerSegment] = []
    private let maxBufferDuration: TimeInterval = 30.0  // Keep 30s of history
    
    // Current speaker tracking for gap handling
    private var lastKnownSpeaker: SpeakerID?
    private var lastKnownTimestamp: TimeInterval = 0
    
    // Stream start reference
    private var streamStartTime: TimeInterval = 0
    
    // MARK: - Public Methods
    
    /// Set the stream start reference time
    func setStreamStart(_ time: TimeInterval) {
        streamStartTime = time
    }
    
    /// Add a diarization result to the buffer
    func addSegment(_ segment: SpeakerSegment) {
        // Insert in sorted order (by start time)
        let insertIndex = speakerSegments.firstIndex { $0.startTime > segment.startTime }
            ?? speakerSegments.endIndex
        speakerSegments.insert(segment, at: insertIndex)
        
        // Prune old segments
        pruneOldSegments()
        
        // Update last known speaker
        if segment.endTime > lastKnownTimestamp {
            lastKnownSpeaker = segment.speakerID
            lastKnownTimestamp = segment.endTime
        }
        
        logger.debug("Added segment: \(segment.speakerID.description) [\(String(format: "%.2f", segment.startTime))-\(String(format: "%.2f", segment.endTime))]")
    }
    
    /// Add multiple segments at once
    func addSegments(_ segments: [SpeakerSegment]) async {
        for segment in segments {
            addSegment(segment)
        }
    }
    
    /// Look up speaker ID for a given audio timestamp
    func lookupSpeaker(at timestamp: TimeInterval) -> SpeakerLookupResult {
        // Binary search for the segment containing this timestamp
        for segment in speakerSegments {
            if timestamp >= segment.startTime && timestamp <= segment.endTime {
                return .speaker(segment.speakerID, confidence: segment.confidence)
            }
            
            // Check if we're in a gap between segments
            if timestamp < segment.startTime {
                // We're before this segment - check if in silence gap
                if let prevSegment = speakerSegments.last(where: { $0.endTime < timestamp }) {
                    let gapDuration = segment.startTime - prevSegment.endTime
                    if gapDuration > 0.5 {
                        // Long gap - likely silence
                        return .silence
                    }
                    // Short gap - assume same speaker as previous with reduced confidence
                    return .speaker(prevSegment.speakerID, confidence: max(0.3, prevSegment.confidence * 0.5))
                }
                break
            }
        }
        
        // Timestamp is beyond our buffered data - use heuristics
        if let lastSpeaker = lastKnownSpeaker {
            let timeSinceLastKnown = timestamp - lastKnownTimestamp
            if timeSinceLastKnown < 2.0 && timeSinceLastKnown >= 0 {
                // Within 2s - assume same speaker with degraded confidence
                let confidence = max(0.3, 1.0 - timeSinceLastKnown * 0.35)
                return .speaker(lastSpeaker, confidence: confidence)
            }
        }
        
        return .unknown
    }
    
    /// Get all segments in a time range
    func getSegments(from startTime: TimeInterval, to endTime: TimeInterval) -> [SpeakerSegment] {
        return speakerSegments.filter { segment in
            segment.endTime >= startTime && segment.startTime <= endTime
        }
    }
    
    /// Get the current buffer size
    func getBufferCount() -> Int {
        return speakerSegments.count
    }
    
    /// Clear all buffered segments
    func clear() {
        speakerSegments.removeAll()
        lastKnownSpeaker = nil
        lastKnownTimestamp = 0
    }
    
    // MARK: - Private Methods
    
    private func pruneOldSegments() {
        guard let newest = speakerSegments.last else { return }
        let cutoff = newest.endTime - maxBufferDuration
        speakerSegments.removeAll { $0.endTime < cutoff }
    }
}
