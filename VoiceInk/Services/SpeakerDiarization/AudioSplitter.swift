import Foundation
import AVFoundation
import os

/// Splits audio from a single AVAudioEngine tap and feeds two parallel consumers:
/// speech recognition and speaker diarization
final class AudioSplitter {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioSplitter")
    
    // Processing queues
    private let speechQueue = DispatchQueue(label: "com.voiceink.speech.audio", qos: .userInteractive)
    private let diarizationQueue = DispatchQueue(label: "com.voiceink.diarization.audio", qos: .userInitiated)
    
    // Stream continuations
    private var speechContinuation: AsyncStream<SpeechAudioInput>.Continuation?
    private var diarizationContinuation: AsyncStream<DiarizationChunk>.Continuation?
    
    // Sample rate converter for diarization (lazy initialized)
    private var diarizationConverter: AVAudioConverter?
    private let diarizationFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    
    // Sample rate converter for speech (Int16 format for SpeechAnalyzer)
    private var speechConverter: AVAudioConverter?
    private var speechFormat: AVAudioFormat?
    
    // Reference tracking
    private weak var installedNode: AVAudioInputNode?
    private var streamStartTime: AVAudioTime?
    
    // MARK: - Public Types
    
    /// Audio input for speech recognition
    struct SpeechAudioInput: Sendable {
        let buffer: AVAudioPCMBuffer
        let timestamp: AudioTimestamp
    }
    
    // MARK: - Public Methods
    
    /// Configure the stream continuations
    func configure(
        speechContinuation: AsyncStream<SpeechAudioInput>.Continuation,
        diarizationContinuation: AsyncStream<DiarizationChunk>.Continuation
    ) {
        self.speechContinuation = speechContinuation
        self.diarizationContinuation = diarizationContinuation
    }
    
    /// Install a tap on the input node that feeds both consumers
    /// - Parameters:
    ///   - inputNode: The audio input node to tap
    ///   - inputFormat: The input format from the node
    ///   - speechFormat: Optional target format for speech recognition. If nil, will create Int16 mono format.
    func installTap(on inputNode: AVAudioInputNode, inputFormat: AVAudioFormat, speechFormat: AVAudioFormat? = nil) {
        // Create converter for diarization if needed
        if inputFormat.sampleRate != 16000 || inputFormat.channelCount != 1 {
            diarizationConverter = AVAudioConverter(from: inputFormat, to: diarizationFormat)
        }
        
        // Use provided speechFormat or create default Int16 MONO format
        if let targetFormat = speechFormat {
            // Use the format provided (from SpeechAnalyzer.bestAvailableAudioFormat)
            speechConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            self.speechFormat = targetFormat
            logger.info("Using provided speech format: \(targetFormat)")
        } else {
            // Fallback: Create Int16 MONO format for SpeechAnalyzer
            let int16MonoFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
            
            if let int16MonoFormat = int16MonoFormat {
                speechConverter = AVAudioConverter(from: inputFormat, to: int16MonoFormat)
                self.speechFormat = int16MonoFormat
            } else {
                self.speechFormat = inputFormat
            }
        }
        
        installedNode = inputNode
        streamStartTime = nil
        
        // Use small buffer for low latency (256 samples = ~5ms at 48kHz)
        inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // Record start time
            if self.streamStartTime == nil {
                self.streamStartTime = time
            }
            
            // Fan-out: dispatch to both consumers in parallel
            self.speechQueue.async {
                self.processSpeechBuffer(buffer, time: time, inputFormat: inputFormat)
            }
            
            self.diarizationQueue.async {
                self.processDiarizationBuffer(buffer, time: time, inputFormat: inputFormat)
            }
        }
        
        logger.info("Audio splitter installed: \(inputFormat.sampleRate)Hz -> Speech (Int16) + 16kHz Diarization")
    }
    
    /// Remove the tap
    func removeTap() {
        installedNode?.removeTap(onBus: 0)
        installedNode = nil
        streamStartTime = nil
        
        // Clean up continuations
        speechContinuation?.finish()
        diarizationContinuation?.finish()
        speechContinuation = nil
        diarizationContinuation = nil
        
        logger.info("Audio splitter tap removed")
    }
    
    // MARK: - Private Methods
    
    private func processSpeechBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, inputFormat: AVAudioFormat) {
        let timestamp = AudioTimestamp(from: time, sampleRate: inputFormat.sampleRate)
        
        // Convert to Int16 if we have a converter
        let bufferToSend: AVAudioPCMBuffer
        if let converter = speechConverter, let format = speechFormat {
            if let converted = convertBufferForSpeech(buffer, using: converter, to: format) {
                bufferToSend = converted
            } else {
                bufferToSend = buffer
            }
        } else {
            bufferToSend = buffer
        }
        
        let input = SpeechAudioInput(buffer: bufferToSend, timestamp: timestamp)
        speechContinuation?.yield(input)
    }
    
    private func convertBufferForSpeech(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Calculate output frame count
        let ratio = format.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCount) else {
            return nil
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if status == .error || error != nil {
            logger.warning("Speech audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        
        return outputBuffer
    }
    
    private func processDiarizationBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, inputFormat: AVAudioFormat) {
        // Convert to 16kHz mono if needed
        let convertedBuffer = convertBufferForDiarization(buffer)
        let samples = extractSamples(from: convertedBuffer)
        
        guard !samples.isEmpty else { return }
        
        let timestamp = AudioTimestamp(from: time, sampleRate: 16000)
        let chunk = DiarizationChunk(samples: samples, timestamp: timestamp)
        diarizationContinuation?.yield(chunk)
    }
    
    private func convertBufferForDiarization(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let converter = diarizationConverter else {
            return inputBuffer
        }
        
        // Calculate output frame count based on sample rate ratio
        let ratio = diarizationFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: diarizationFormat,
            frameCapacity: outputFrameCount
        ) else {
            logger.warning("Failed to create output buffer for diarization")
            return inputBuffer
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if status == .error || error != nil {
            logger.warning("Audio conversion failed: \(error?.localizedDescription ?? "unknown error")")
            return inputBuffer
        }
        
        return outputBuffer
    }
    
    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
    }
    
    deinit {
        removeTap()
    }
}
