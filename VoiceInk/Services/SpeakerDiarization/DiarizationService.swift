import Foundation
import os

/// Protocol for speaker diarization service implementations
/// This allows swapping between different diarization backends (FluidAudio, Core ML, Cloud, etc.)
protocol DiarizationServiceProtocol: Sendable {
    /// Initialize the diarization model
    func initialize() async throws
    
    /// Process an audio window and return speaker segments
    func process(window: DiarizationWindow) async -> [SpeakerSegment]?
    
    /// Check if the service is ready
    var isReady: Bool { get async }
}

/// Mock diarization service for testing and development
/// Simulates speaker detection with random speaker assignments
actor MockDiarizationService: DiarizationServiceProtocol {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MockDiarization")
    private var initialized = false
    private var currentSpeaker = SpeakerID(rawValue: 0)
    private var speakerSwitchProbability: Double = 0.1  // 10% chance of speaker change
    
    var isReady: Bool {
        initialized
    }
    
    func initialize() async throws {
        // Simulate initialization delay
        try await Task.sleep(for: .milliseconds(100))
        initialized = true
        logger.info("Mock diarization service initialized")
    }
    
    func process(window: DiarizationWindow) async -> [SpeakerSegment]? {
        guard initialized else { return nil }
        
        // Simulate processing time
        try? await Task.sleep(for: .milliseconds(50))
        
        // Randomly switch speakers
        if Double.random(in: 0...1) < speakerSwitchProbability {
            let newSpeaker = (currentSpeaker.rawValue + 1) % 4  // Cycle through 4 speakers
            currentSpeaker = SpeakerID(rawValue: newSpeaker)
        }
        
        let startTime = Double(window.startTimestamp.sampleTime) / window.startTimestamp.sampleRate
        
        let segment = SpeakerSegment(
            speakerID: currentSpeaker,
            startTime: startTime,
            endTime: startTime + window.duration,
            confidence: Double.random(in: 0.7...1.0)
        )
        
        return [segment]
    }
}

// MARK: - FluidAudio Diarization Service (Placeholder)

/// FluidAudio-based diarization service
/// Note: This requires FluidAudio to expose a SpeakerDiarizer module
/// If not available, use MockDiarizationService or a Core ML-based implementation
actor FluidAudioDiarizationService: DiarizationServiceProtocol {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidDiarization")
    private var initialized = false
    
    // Placeholder for FluidAudio diarizer
    // private var diarizer: SpeakerDiarizer?
    
    var isReady: Bool {
        initialized
    }
    
    func initialize() async throws {
        // TODO: Initialize FluidAudio SpeakerDiarizer when available
        // Example:
        // diarizer = try await SpeakerDiarizer()
        
        logger.warning("FluidAudio diarization not yet available - using placeholder")
        initialized = true
    }
    
    func process(window: DiarizationWindow) async -> [SpeakerSegment]? {
        guard initialized else { return nil }
        
        // TODO: Implement actual FluidAudio diarization
        // Example:
        // let result = try? await diarizer?.process(samples: window.samples)
        // return result?.segments.map { SpeakerSegment(...) }
        
        // For now, return nil to indicate no diarization available
        return nil
    }
}

// MARK: - Energy-based Simple Diarization

/// Simple energy-based speaker change detection
/// Uses audio energy changes to detect potential speaker switches
/// Not as accurate as neural network-based diarization but works without ML models
actor EnergyBasedDiarizationService: DiarizationServiceProtocol {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "EnergyDiarization")
    private var initialized = false
    
    // State tracking
    private var currentSpeaker = SpeakerID(rawValue: 0)
    private var previousEnergy: Float = 0
    private var silenceThreshold: Float = -40  // dB
    private var energyChangeThreshold: Float = 20  // dB change to trigger speaker evaluation
    private var silenceDuration: TimeInterval = 0
    private let speakerChangeOnSilence: TimeInterval = 0.5  // Consider speaker change after 500ms silence
    
    var isReady: Bool {
        initialized
    }
    
    func initialize() async throws {
        initialized = true
        logger.info("Energy-based diarization service initialized")
    }
    
    func process(window: DiarizationWindow) async -> [SpeakerSegment]? {
        guard initialized else { return nil }
        
        let energy = calculateEnergy(window.samples)
        let energyDB = 20 * log10(max(energy, 1e-10))
        
        let startTime = Double(window.startTimestamp.sampleTime) / window.startTimestamp.sampleRate
        
        // Check for silence
        if energyDB < silenceThreshold {
            silenceDuration += window.duration
            
            // Long silence - next speech might be different speaker
            if silenceDuration >= speakerChangeOnSilence {
                // Return silence segment
                return [SpeakerSegment(
                    speakerID: SpeakerID.unknown,
                    startTime: startTime,
                    endTime: startTime + window.duration,
                    confidence: 0.5
                )]
            }
            
            return nil  // Short silence, no segment
        }
        
        // Reset silence duration
        let wasSilent = silenceDuration >= speakerChangeOnSilence
        silenceDuration = 0
        
        // Check for significant energy change after silence (potential speaker change)
        if wasSilent || abs(energyDB - previousEnergy) > energyChangeThreshold {
            // Potential speaker change
            currentSpeaker = SpeakerID(rawValue: (currentSpeaker.rawValue + 1) % 4)
        }
        
        previousEnergy = energyDB
        
        return [SpeakerSegment(
            speakerID: currentSpeaker,
            startTime: startTime,
            endTime: startTime + window.duration,
            confidence: 0.6  // Lower confidence for energy-based detection
        )]
    }
    
    private func calculateEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}
