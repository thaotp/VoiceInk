import SwiftUI

/// Transcription engine types for Lyric Mode
enum LyricModeEngineType: String, CaseIterable, Identifiable {
    case whisper = "Whisper"
    case appleSpeech = "Apple Speech"
    case cloud = "Cloud"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .whisper:
            return "Local Whisper model (most accurate)"
        case .appleSpeech:
            return "Apple's built-in speech recognition (no download)"
        case .cloud:
            return "Cloud transcription (requires API key)"
        }
    }
    
    var icon: String {
        switch self {
        case .whisper:
            return "waveform"
        case .appleSpeech:
            return "apple.logo"
        case .cloud:
            return "cloud"
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
    
    // Transcription engine type
    @AppStorage("lyricMode.engineType") var engineTypeRaw: String = LyricModeEngineType.whisper.rawValue
    
    var engineType: LyricModeEngineType {
        get { LyricModeEngineType(rawValue: engineTypeRaw) ?? .whisper }
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
    
    // AI Provider settings (for future AI features in Lyric Mode)
    @AppStorage("lyricMode.aiProvider") var aiProviderRaw: String = "ollama"
    @AppStorage("lyricMode.ollamaBaseURL") var ollamaBaseURL: String = "http://localhost:11434"
    @AppStorage("lyricMode.selectedOllamaModel") var selectedOllamaModel: String = "mistral"
    @AppStorage("lyricMode.openAIAPIKey") var openAIAPIKey: String = ""
    @AppStorage("lyricMode.selectedOpenAIModel") var selectedOpenAIModel: String = "gpt-4o-mini"
    
    // Translation settings
    @AppStorage("lyricMode.translationEnabled") var translationEnabled: Bool = false
    @AppStorage("lyricMode.targetLanguage") var targetLanguage: String = "Vietnamese"
    
    // Apple Speech specific settings
    @AppStorage("lyricMode.appleSpeechMode") var appleSpeechModeRaw: String = AppleSpeechMode.standard.rawValue
    
    var appleSpeechMode: AppleSpeechMode {
        get { AppleSpeechMode(rawValue: appleSpeechModeRaw) ?? .standard }
        set { 
            Task { @MainActor in
                appleSpeechModeRaw = newValue.rawValue
            }
        }
    }
    
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

