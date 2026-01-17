import Foundation
import AVFoundation
import os

/// Accumulates audio chunks and produces windows for diarization inference
actor DiarizationBufferActor {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DiarizationBuffer")
    
    // Audio buffer
    private var buffer: [Float] = []
    private var bufferStartTimestamp: AudioTimestamp?
    
    // Configuration
    private let sampleRate: Double = 16000.0  // Diarization models expect 16kHz
    private let windowDuration: TimeInterval  // Window size in seconds
    private let hopDuration: TimeInterval     // Hop size in seconds (overlap = window - hop)
    
    private var windowSize: Int { Int(sampleRate * windowDuration) }
    private var hopSize: Int { Int(sampleRate * hopDuration) }
    
    /// Initialize with window and hop durations
    /// - Parameters:
    ///   - windowDuration: Duration of each window in seconds (default 0.5s)
    ///   - hopDuration: Hop between windows in seconds (default 0.25s = 50% overlap)
    init(windowDuration: TimeInterval = 0.5, hopDuration: TimeInterval = 0.25) {
        self.windowDuration = windowDuration
        self.hopDuration = hopDuration
    }
    
    /// Append a chunk and return a window if ready
    func append(chunk: DiarizationChunk) -> DiarizationWindow? {
        if bufferStartTimestamp == nil {
            bufferStartTimestamp = chunk.timestamp
        }
        
        buffer.append(contentsOf: chunk.samples)
        
        // Emit window when we have enough samples
        if buffer.count >= windowSize {
            guard let startTimestamp = bufferStartTimestamp else { return nil }
            
            let window = DiarizationWindow(
                samples: Array(buffer.prefix(windowSize)),
                startTimestamp: startTimestamp,
                duration: windowDuration
            )
            
            // Slide buffer by hop size
            buffer.removeFirst(min(hopSize, buffer.count))
            bufferStartTimestamp = startTimestamp.advanced(bySamples: hopSize)
            
            logger.debug("Emitted window: \(self.windowDuration)s at sample \(startTimestamp.sampleTime)")
            
            return window
        }
        
        return nil
    }
    
    /// Clear the buffer
    func clear() {
        buffer.removeAll()
        bufferStartTimestamp = nil
    }
    
    /// Get current buffer size in samples
    func getBufferSize() -> Int {
        return buffer.count
    }
    
    /// Get current buffer duration in seconds
    func getBufferDuration() -> TimeInterval {
        return Double(buffer.count) / sampleRate
    }
}
