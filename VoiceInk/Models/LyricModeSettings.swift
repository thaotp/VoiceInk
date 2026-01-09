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
    
    // Transcription engine type
    @AppStorage("lyricMode.engineType") var engineTypeRaw: String = LyricModeEngineType.whisper.rawValue
    
    var engineType: LyricModeEngineType {
        get { LyricModeEngineType(rawValue: engineTypeRaw) ?? .whisper }
        set { engineTypeRaw = newValue.rawValue }
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
    
    static let shared = LyricModeSettings()
    
    private init() {}
}

