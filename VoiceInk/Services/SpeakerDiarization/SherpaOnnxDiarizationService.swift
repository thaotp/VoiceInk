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
    private static let embeddingModelFile = "wespeaker_zh_cnceleb_resnet34.onnx"
    
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
        
        print("[SherpaOnnx] Initializing Sherpa-Onnx diarization service...")
        logger.info("Initializing Sherpa-Onnx diarization service...")
        
        // Find model paths in bundle
        guard let modelsDir = Bundle.main.resourcePath else {
            print("[SherpaOnnx] ERROR: Cannot find app bundle resource path")
            logger.error("Cannot find app bundle resource path")
            initialized = true  // Mark initialized to prevent repeated attempts
            return
        }
        
        // DEBUG: List files in resource path to verify where models are
        // (Removing detailed debug loop to reduce noise, now that we know the issue)
        
        // Fallback checks for flattened structure vs folder structure
        // Note: Preferring int8 model to avoid ONNX Runtime Opset incompatibility (Opset 19 error)
        let flatSegmentationPathInt8 = "\(modelsDir)/model.int8.onnx"
        let flatSegmentationPath = "\(modelsDir)/model.onnx"
        let structuredSegmentationPathInt8 = "\(modelsDir)/SherpaOnnxModels/\(Self.segmentationModelDir)/model.int8.onnx"
        let structuredSegmentationPath = "\(modelsDir)/SherpaOnnxModels/\(Self.segmentationModelDir)/\(Self.segmentationModelFile)"
        
        let flatEmbeddingPath = "\(modelsDir)/\(Self.embeddingModelFile)"
        let structuredEmbeddingPath = "\(modelsDir)/SherpaOnnxModels/\(Self.embeddingModelFile)"
        
        // Determine correct paths
        let fileManager = FileManager.default
        
        var finalSegmentationPath = structuredSegmentationPath
        
        if fileManager.fileExists(atPath: flatSegmentationPathInt8) {
             print("[SherpaOnnx] Found int8 segmentation model in root: \(flatSegmentationPathInt8)")
             finalSegmentationPath = flatSegmentationPathInt8
        } else if fileManager.fileExists(atPath: structuredSegmentationPathInt8) {
             print("[SherpaOnnx] Found int8 segmentation model in folder: \(structuredSegmentationPathInt8)")
             finalSegmentationPath = structuredSegmentationPathInt8
        } else if fileManager.fileExists(atPath: flatSegmentationPath) {
            print("[SherpaOnnx] Found segmentation model in root: \(flatSegmentationPath)")
            finalSegmentationPath = flatSegmentationPath
        } else if fileManager.fileExists(atPath: structuredSegmentationPath) {
            print("[SherpaOnnx] Found segmentation model in folder: \(structuredSegmentationPath)")
            finalSegmentationPath = structuredSegmentationPath
        } else {
             print("[SherpaOnnx] ERROR: Segmentation model not found in either location!")
             print("[SherpaOnnx] Checked: \(flatSegmentationPath)")
             print("[SherpaOnnx] Checked: \(structuredSegmentationPath)")
             logger.warning("Segmentation model not found")
             initialized = true
             return
        }
        
        var finalEmbeddingPath = structuredEmbeddingPath
        if fileManager.fileExists(atPath: flatEmbeddingPath) {
            print("[SherpaOnnx] Found embedding model in root: \(flatEmbeddingPath)")
            finalEmbeddingPath = flatEmbeddingPath
        } else if fileManager.fileExists(atPath: structuredEmbeddingPath) {
             print("[SherpaOnnx] Found embedding model in folder: \(structuredEmbeddingPath)")
             finalEmbeddingPath = structuredEmbeddingPath
        } else {
             print("[SherpaOnnx] ERROR: Embedding model not found in either location!")
             print("[SherpaOnnx] Checked: \(flatEmbeddingPath)")
             print("[SherpaOnnx] Checked: \(structuredEmbeddingPath)")
             logger.warning("Embedding model not found")
             initialized = true
             return
        }
        
        print("[SherpaOnnx] Models found, creating wrapper...")
        
        // Create and initialize wrapper
        let newWrapper = SherpaOnnxSpeakerDiarizationWrapper()
        let success = newWrapper.initialize(
            segmentationModelPath: finalSegmentationPath,
            embeddingModelPath: finalEmbeddingPath,
            numClusters: 0,     // Auto-detect number of speakers
            threshold: 0.45,    // Lower threshold for better sensitivity (Japanese optimized)
            minDurationOn: 0.3, // Minimum speech segment duration
            minDurationOff: 0.3 // Minimum silence gap to split segments
        )
        
        if success {
            wrapper = newWrapper
            print("[SherpaOnnx] ✅ Initialization successful! Sample rate: \(newWrapper.sampleRate)")
            logger.info("Sherpa-Onnx diarization initialized successfully")
        } else {
            print("[SherpaOnnx] ❌ Wrapper initialization failed!")
            logger.error("Failed to initialize Sherpa-Onnx diarization")
        }
        
        initialized = true
    }
    
    func process(window: DiarizationWindow) async -> [SpeakerSegment]? {
        guard initialized else {
            print("[SherpaOnnx] Not initialized, skipping process")
            return nil
        }
        
        guard let wrapper = wrapper, wrapper.isInitialized else {
            // Wrapper not available - models might be missing
            print("[SherpaOnnx] Wrapper not initialized (models missing?)")
            return nil
        }
        
        // Process the audio window
        print("[SherpaOnnx] Processing window: \(window.samples.count) samples (\(String(format: "%.2f", Double(window.samples.count) / 16000.0))s)")
        let results = wrapper.process(samples: window.samples)
        
        guard !results.isEmpty else {
            print("[SherpaOnnx] No segments returned from diarization")
            return nil
        }
        
        print("[SherpaOnnx] Diarization returned \(results.count) segments")
        
        // Convert to SpeakerSegment format
        let windowStartTime = Double(window.startTimestamp.sampleTime) / window.startTimestamp.sampleRate
        
        var segments: [SpeakerSegment] = []
        for result in results {
            // Map sherpa-onnx speaker label to our SpeakerID
            let speakerID = mapSpeakerLabel(result.speakerLabel)
            
            let segment = SpeakerSegment(
                speakerID: speakerID,
                startTime: windowStartTime + result.startTime,
                endTime: windowStartTime + result.endTime,
                confidence: 0.85  // Sherpa-onnx does not provide confidence, use default high value
            )
            segments.append(segment)
            print("[SherpaOnnx] Segment: Speaker \(result.speakerLabel) [\(String(format: "%.2f", result.startTime))-\(String(format: "%.2f", result.endTime))]")
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

