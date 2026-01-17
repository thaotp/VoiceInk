import Foundation
import os.log

/// Swift wrapper for sherpa-onnx offline speaker diarization C API
/// This class provides a Swift-friendly interface to the sherpa-onnx diarization functions
class SherpaOnnxSpeakerDiarizationWrapper {
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SherpaOnnxWrapper")
    
    /// Pointer to the native diarization object
    private var diarizationPtr: OpaquePointer?
    
    /// Sample rate expected by the model
    private(set) var sampleRate: Int32 = 16000
    
    /// Whether the wrapper is initialized
    var isInitialized: Bool {
        diarizationPtr != nil
    }
    
    deinit {
        destroy()
    }
    
    /// Initialize the speaker diarization with model paths
    /// - Parameters:
    ///   - segmentationModelPath: Path to the Pyannote segmentation ONNX model
    ///   - embeddingModelPath: Path to the speaker embedding ONNX model
    ///   - numClusters: Number of speakers (0 = auto-detect)
    ///   - threshold: Clustering threshold (default 0.5)
    func initialize(
        segmentationModelPath: String,
        embeddingModelPath: String,
        numClusters: Int32 = 0,
        threshold: Float = 0.5
    ) -> Bool {
        guard diarizationPtr == nil else {
            logger.warning("Already initialized")
            return true
        }
        
        logger.info("Initializing sherpa-onnx diarization...")
        logger.info("Segmentation model: \(segmentationModelPath)")
        logger.info("Embedding model: \(embeddingModelPath)")
        
        // Create configuration with proper string handling
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        
        // Need to keep string data alive during the entire initialization
        let segPathCString = strdup(segmentationModelPath)
        let embPathCString = strdup(embeddingModelPath)
        
        defer {
            free(segPathCString)
            free(embPathCString)
        }
        
        // Configure segmentation model (Pyannote)
        config.segmentation.pyannote.model = segPathCString
        
        // Configure embedding extractor
        config.embedding.model = embPathCString
        
        // Configure clustering
        config.clustering.num_clusters = numClusters
        config.clustering.threshold = threshold
        
        // Create the diarization object
        let ptr = SherpaOnnxCreateOfflineSpeakerDiarization(&config)
        
        if let ptr = ptr {
            diarizationPtr = ptr
            sampleRate = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(ptr)
            logger.info("Sherpa-onnx diarization initialized, sample rate: \(self.sampleRate)")
            return true
        } else {
            logger.error("Failed to create sherpa-onnx diarization")
            return false
        }
    }
    
    /// Process audio samples and get speaker segments
    /// - Parameters:
    ///   - samples: Audio samples (must be at expected sample rate, typically 16kHz)
    /// - Returns: Array of speaker segments with start/end times and speaker labels
    func process(samples: [Float]) -> [SpeakerDiarizationSegment] {
        guard let ptr = diarizationPtr else {
            logger.error("Not initialized")
            return []
        }
        
        guard !samples.isEmpty else {
            return []
        }
        
        let result = samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeakerDiarizationProcess(
                ptr,
                buffer.baseAddress,
                Int32(samples.count)
            )
        }
        
        guard let result = result else {
            logger.warning("Diarization returned no result")
            return []
        }
        
        defer {
            SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)
        }
        
        var segments: [SpeakerDiarizationSegment] = []
        let numSegments = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result)
        
        // Get the pointer to sorted segments once, then index into it safely
        if let segPtr = SherpaOnnxOfflineSpeakerDiarizationResultGetSortedSegments(result) {
            for i in 0..<numSegments {
                let segmentData = segPtr[Int(i)]
                segments.append(SpeakerDiarizationSegment(
                    startTime: Double(segmentData.start),
                    endTime: Double(segmentData.end),
                    speakerLabel: Int(segmentData.speaker)
                ))
            }
        }
        
        return segments
    }
    
    /// Destroy the native diarization object and free resources
    func destroy() {
        if let ptr = diarizationPtr {
            SherpaOnnxDestroyOfflineSpeakerDiarization(ptr)
            diarizationPtr = nil
            logger.info("Sherpa-onnx diarization destroyed")
        }
    }
}

/// A speaker diarization segment result
struct SpeakerDiarizationSegment {
    /// Start time in seconds
    let startTime: Double
    
    /// End time in seconds
    let endTime: Double
    
    /// Speaker label (0, 1, 2, ...)
    let speakerLabel: Int
    
    /// Duration in seconds
    var duration: Double {
        endTime - startTime
    }
}
