import Foundation
import AVFoundation
import os.log

/// Speaker Diarization Service using Sherpa-Onnx with Pyannote + 3D-Speaker models
///
/// Uses offline speaker diarization for accurate multi-speaker identification.
/// Requires sherpa-onnx dynamic libraries and ONNX models in the app bundle.
actor SherpaOnnxDiarizationService: DiarizationServiceProtocol {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SherpaOnnxDiarization")
    
    // MARK: - Model Configuration
    
    private static let segmentationModelDir = "sherpa-onnx-pyannote-segmentation-3-0"
    private static let segmentationModelFile = "model.onnx"
    private static let embeddingModelFile = "3dspeaker-embedding.onnx"
    
    // MARK: - Properties
    
    private var wrapper: SherpaOnnxSpeakerDiarizationWrapper?
    private var initialized = false
    private var currentSpeakerMapping: [Int: SpeakerID] = [:]
    
    // MARK: - DiarizationServiceProtocol
    
    var isReady: Bool {
        initialized && wrapper?.isInitialized == true
    }
    
    func initialize() async throws {
        guard !initialized else { return }
        
        logger.info("Initializing Sherpa-Onnx diarization service...")
        
        // Find model paths in bundle
        guard let modelsDir = Bundle.main.resourcePath else {
            logger.error("Cannot find app bundle resource path")
            initialized = true  // Mark initialized to prevent repeated attempts
            return
        }
        
        let segmentationPath = "\(modelsDir)/SherpaOnnxModels/\(Self.segmentationModelDir)/\(Self.segmentationModelFile)"
        let embeddingPath = "\(modelsDir)/SherpaOnnxModels/\(Self.embeddingModelFile)"
        
        // Check if models exist
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: segmentationPath) else {
            logger.warning("Segmentation model not found at: \(segmentationPath)")
            initialized = true
            return
        }
        guard fileManager.fileExists(atPath: embeddingPath) else {
            logger.warning("Embedding model not found at: \(embeddingPath)")
            initialized = true
            return
        }
        
        // Create and initialize wrapper
        let newWrapper = SherpaOnnxSpeakerDiarizationWrapper()
        let success = newWrapper.initialize(
            segmentationModelPath: segmentationPath,
            embeddingModelPath: embeddingPath,
            numClusters: 0,  // Auto-detect number of speakers
            threshold: 0.5   // Default clustering threshold
        )
        
        if success {
            wrapper = newWrapper
            logger.info("Sherpa-Onnx diarization initialized successfully")
        } else {
            logger.error("Failed to initialize Sherpa-Onnx diarization")
        }
        
        initialized = true
    }
    
    func process(window: DiarizationWindow) async -> [SpeakerSegment]? {
        guard initialized else { return nil }
        
        guard let wrapper = wrapper, wrapper.isInitialized else {
            // Wrapper not available - models might be missing
            return nil
        }
        
        // Process the audio window
        let results = wrapper.process(samples: window.samples)
        
        guard !results.isEmpty else {
            return nil
        }
        
        // Convert to SpeakerSegment format
        let windowStartTime = Double(window.startTimestamp.sampleTime) / window.startTimestamp.sampleRate
        
        var segments: [SpeakerSegment] = []
        for result in results {
            // Map sherpa-onnx speaker label to our SpeakerID
            let speakerID = mapSpeakerLabel(result.speakerLabel)
            
            segments.append(SpeakerSegment(
                speakerID: speakerID,
                startTime: windowStartTime + result.startTime,
                endTime: windowStartTime + result.endTime,
                confidence: 0.85  // Sherpa-onnx does not provide confidence, use default high value
            ))
        }
        
        return segments
    }
    
    // MARK: - Private Methods
    
    private func mapSpeakerLabel(_ label: Int) -> SpeakerID {
        if let existingID = currentSpeakerMapping[label] {
            return existingID
        }
        
        // Create new speaker ID for this label
        let newID = SpeakerID(rawValue: label)
        currentSpeakerMapping[label] = newID
        return newID
    }
}

