import Foundation
import AVFoundation
import Combine
import os

/// Real-time audio streaming service for continuous microphone capture
/// Produces overlapping audio chunks suitable for streaming transcription
@MainActor
final class RealtimeAudioStreamService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isStreaming = false
    @Published private(set) var currentPower: Float = 0.0
    
    // MARK: - Audio Chunk Output
    
    /// Publisher for audio chunks ready for transcription
    /// Each chunk contains 16kHz mono Float32 samples
    let audioChunkPublisher = PassthroughSubject<AudioChunk, Never>()
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Duration of each audio chunk in seconds
        var chunkDuration: TimeInterval = 0.5
        /// Overlap between consecutive chunks (0.0 to 0.5)
        var overlapRatio: Double = 0.2
        /// Target sample rate for whisper (16kHz)
        static let targetSampleRate: Double = 16000.0
        /// Minimum power level to emit chunks (silence gating)
        var silenceThreshold: Float = -50.0
    }
    
    var configuration = Configuration()
    
    // MARK: - Private Properties
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var converter: AVAudioConverter?
    
    private let audioProcessingQueue = DispatchQueue(label: "com.voiceink.realtime.audio", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RealtimeAudioStream")
    
    // Ring buffer for overlapping chunks
    private var ringBuffer: [Float] = []
    private var ringBufferLock = NSLock()
    
    private var samplesPerChunk: Int {
        Int(Configuration.targetSampleRate * configuration.chunkDuration)
    }
    
    private var overlapSamples: Int {
        Int(Double(samplesPerChunk) * configuration.overlapRatio)
    }
    
    private var outputFormat: AVAudioFormat?
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    func startStreaming() throws {
        guard !isStreaming else { return }
        
        stopStreaming()
        
        let engine = AVAudioEngine()
        audioEngine = engine
        
        let input = engine.inputNode
        inputNode = input
        
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            throw RealtimeAudioError.invalidInputFormat
        }
        
        // Create output format for whisper (16kHz mono)
        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Configuration.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RealtimeAudioError.invalidOutputFormat
        }
        outputFormat = whisperFormat
        
        // Create converter if sample rate or channel count differs
        if inputFormat.sampleRate != Configuration.targetSampleRate || inputFormat.channelCount != 1 {
            guard let conv = AVAudioConverter(from: inputFormat, to: whisperFormat) else {
                throw RealtimeAudioError.converterCreationFailed
            }
            converter = conv
        }
        
        // Clear ring buffer
        ringBufferLock.lock()
        ringBuffer.removeAll()
        ringBuffer.reserveCapacity(samplesPerChunk * 3)
        ringBufferLock.unlock()
        
        // Install tap on input node
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms buffers
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }
        
        do {
            try engine.start()
            isStreaming = true
            logger.info("Real-time audio streaming started")
        } catch {
            input.removeTap(onBus: 0)
            throw RealtimeAudioError.engineStartFailed(error)
        }
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        converter = nil
        
        ringBufferLock.lock()
        ringBuffer.removeAll()
        ringBufferLock.unlock()
        
        isStreaming = false
        currentPower = 0.0
        logger.info("Real-time audio streaming stopped")
    }
    
    // MARK: - Private Methods
    
    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Convert to 16kHz mono if needed
            let samples: [Float]
            if let converter = self.converter, let outputFormat = self.outputFormat {
                guard let converted = self.convertBuffer(buffer, using: converter, to: outputFormat) else {
                    return
                }
                samples = converted
            } else {
                guard let channelData = buffer.floatChannelData else { return }
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }
            
            // Calculate power for this buffer
            let power = self.calculatePower(samples)
            
            Task { @MainActor in
                self.currentPower = power
            }
            
            // Add to ring buffer
            self.ringBufferLock.lock()
            self.ringBuffer.append(contentsOf: samples)
            
            // Emit chunks when we have enough samples
            while self.ringBuffer.count >= self.samplesPerChunk {
                let chunk = Array(self.ringBuffer.prefix(self.samplesPerChunk))
                let chunkPower = self.calculatePower(chunk)
                
                // Remove samples, keeping overlap for next chunk
                let samplesToRemove = self.samplesPerChunk - self.overlapSamples
                self.ringBuffer.removeFirst(samplesToRemove)
                
                self.ringBufferLock.unlock()
                
                // Emit chunk if above silence threshold
                if chunkPower > self.configuration.silenceThreshold {
                    let audioChunk = AudioChunk(
                        samples: chunk,
                        power: chunkPower,
                        timestamp: Date()
                    )
                    
                    Task { @MainActor in
                        self.audioChunkPublisher.send(audioChunk)
                    }
                }
                
                self.ringBufferLock.lock()
            }
            self.ringBufferLock.unlock()
        }
    }
    
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> [Float]? {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        var error: NSError?
        var hasData = true
        
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let error = error {
            logger.error("Conversion error: \(error.localizedDescription)")
            return nil
        }
        
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
    
    private func calculatePower(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -Float.infinity }
        
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        
        let rms = sqrt(sumSquares / Float(samples.count))
        let db = 20 * log10(max(rms, 1e-10))
        return db
    }
    
    deinit {
        Task { @MainActor in
            stopStreaming()
        }
    }
}

// MARK: - Audio Chunk

struct AudioChunk {
    let samples: [Float]
    let power: Float
    let timestamp: Date
    
    var duration: TimeInterval {
        Double(samples.count) / RealtimeAudioStreamService.Configuration.targetSampleRate
    }
}

// MARK: - Errors

enum RealtimeAudioError: LocalizedError {
    case invalidInputFormat
    case invalidOutputFormat
    case converterCreationFailed
    case engineStartFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Invalid audio input format from microphone"
        case .invalidOutputFormat:
            return "Failed to create output audio format"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}
