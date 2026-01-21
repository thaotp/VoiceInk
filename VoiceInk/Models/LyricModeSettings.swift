import SwiftUI

/// Transcription engine types for Lyric Mode
enum LyricModeEngineType: String, CaseIterable, Identifiable {
    case appleSpeech = "Apple Speech"
    
    var id: String { rawValue }
    
    var description: String {
        return "Apple's built-in speech recognition"
    }
    
    var icon: String {
        return "apple.logo"
    }
}

/// Diarization backend options for speaker identification
enum DiarizationBackend: String, CaseIterable, Identifiable {
    case fluidAudio = "FluidAudio"
    case sherpaOnnx = "Sherpa-Onnx"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .fluidAudio:
            return "Audio energy-based speaker detection"
        case .sherpaOnnx:
            return "Neural network speaker diarization"
        }
    }
    
    var icon: String {
        switch self {
        case .fluidAudio:
            return "waveform"
        case .sherpaOnnx:
            return "brain.head.profile"
        }
    }
}

/// Settings model for Lyric Mode appearance and behavior
class LyricModeSettings: ObservableObject {
    @AppStorage("lyricMode.maxVisibleLines") var maxVisibleLines: Int = 5
    @AppStorage("lyricMode.fontSize") var fontSize: Double = 24
    @AppStorage("lyricMode.isClickThroughEnabled") var isClickThroughEnabled: Bool = false
    @AppStorage("lyricMode.backgroundOpacity") var backgroundOpacity: Double = 0.8
    @AppStorage("lyricMode.showPartialHighlight") var showPartialHighlight: Bool = true
    @AppStorage("lyricMode.autoShowOverlay") var autoShowOverlay: Bool = true
    
    // Transcription engine type (now only Apple Speech)
    @AppStorage("lyricMode.engineType") var engineTypeRaw: String = LyricModeEngineType.appleSpeech.rawValue
    
    var engineType: LyricModeEngineType {
        get { .appleSpeech }
        set { 
            Task { @MainActor in
                engineTypeRaw = newValue.rawValue 
            }
        }
    }
    
    // Transcription settings (separate from global settings)
    @AppStorage("lyricMode.selectedModelName") var selectedModelName: String = ""
    @AppStorage("lyricMode.selectedCloudModelName") var selectedCloudModelName: String = ""
    @AppStorage("lyricMode.selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage("lyricMode.temperature") var temperature: Double = 0.0
    @AppStorage("lyricMode.beamSize") var beamSize: Int = 1
    @AppStorage("lyricMode.softTimeout") var softTimeout: Double = 0.5
    @AppStorage("lyricMode.hardTimeout") var hardTimeout: Double = 2.0
    @AppStorage("lyricMode.selectedAudioDeviceUID") var selectedAudioDeviceUID: String = ""
    @AppStorage("lyricMode.whisperPrompt") var whisperPrompt: String = ""
    
    // WhisperKit specific settings
    @AppStorage("lyricMode.selectedWhisperKitModel") var selectedWhisperKitModel: String = ""
    @AppStorage("lyricMode.whisperKitModelRepo") var whisperKitModelRepo: String = "argmaxinc/whisperkit-coreml"
    
    // AI Provider settings (for future AI features in Lyric Mode)
    @AppStorage("lyricMode.aiProvider") var aiProviderRaw: String = "ollama"
    @AppStorage("lyricMode.ollamaBaseURL") var ollamaBaseURL: String = "http://localhost:11434"
    @AppStorage("lyricMode.selectedOllamaModel") var selectedOllamaModel: String = "mistral"
    @AppStorage("lyricMode.openAIAPIKey") var openAIAPIKey: String = ""
    @AppStorage("lyricMode.selectedOpenAIModel") var selectedOpenAIModel: String = "gpt-4o-mini"
    
    // Translation settings
    @AppStorage("lyricMode.translationEnabled") var translationEnabled: Bool = true
    @AppStorage("lyricMode.translateImmediately") var translateImmediately: Bool = false
    @AppStorage("lyricMode.targetLanguage") var targetLanguage: String = "Vietnamese"
    
    // Sentence continuity setting
    @AppStorage("lyricMode.sentenceContinuityEnabled") var sentenceContinuityEnabled: Bool = true
    
    // Post-Processing (LLM Correction) settings
    @AppStorage("lyricMode.postProcessingEnabled") var postProcessingEnabled: Bool = false
    @AppStorage("lyricMode.postProcessingModel") var postProcessingModel: String = "qwen2.5:3b"
    @AppStorage("lyricMode.postProcessingTimeout") var postProcessingTimeout: Double = 2.0
    
    // Segment Processing settings
    @AppStorage("lyricMode.deduplicationEnabled") var deduplicationEnabled: Bool = true
    @AppStorage("lyricMode.similarityReplacementEnabled") var similarityReplacementEnabled: Bool = true
    
    // Apple Speech specific settings
    @AppStorage("lyricMode.appleSpeechMode") var appleSpeechModeRaw: String = AppleSpeechMode.standard.rawValue
    @AppStorage("lyricMode.speakerDiarizationEnabled") var speakerDiarizationEnabled: Bool = false
    @AppStorage("lyricMode.diarizationBackend") var diarizationBackendRaw: String = DiarizationBackend.fluidAudio.rawValue
    
    var diarizationBackend: DiarizationBackend {
        get { DiarizationBackend(rawValue: diarizationBackendRaw) ?? .fluidAudio }
        set { diarizationBackendRaw = newValue.rawValue }
    }
    
    var appleSpeechMode: AppleSpeechMode {
        get { AppleSpeechMode(rawValue: appleSpeechModeRaw) ?? .standard }
        set { 
            Task { @MainActor in
                appleSpeechModeRaw = newValue.rawValue
            }
        }
    }
    
    // Teams Live Captions settings
    @AppStorage("lyricMode.teamsSelectedPID") var teamsSelectedPID: Int = 0
    @AppStorage("lyricMode.teamsSelectedWindowTitle") var teamsSelectedWindowTitle: String = ""
    @AppStorage("lyricMode.teamsCaptionsPollInterval") var teamsCaptionsPollInterval: Double = 0.1
    
    enum AppleSpeechMode: String, CaseIterable, Identifiable {
        case standard = "Standard" // SpeechTranscriber (High Accuracy)
        case dictation = "Dictation" // DictationTranscriber (Fast)
        case legacy = "Legacy" // SFSpeechRecognizer
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .standard: return "High accuracy, long form (SpeechTranscriber)"
            case .dictation: return "Low latency, short form (DictationTranscriber)"
            case .legacy: return "Classic API (SFSpeechRecognizer)"
            }
        }
    }
    
    static let shared = LyricModeSettings()
    
    private init() {}
}

