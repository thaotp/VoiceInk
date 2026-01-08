import SwiftUI

/// Settings model for Lyric Mode appearance and behavior
class LyricModeSettings: ObservableObject {
    @AppStorage("lyricMode.maxVisibleLines") var maxVisibleLines: Int = 5
    @AppStorage("lyricMode.fontSize") var fontSize: Double = 24
    @AppStorage("lyricMode.isClickThroughEnabled") var isClickThroughEnabled: Bool = false
    @AppStorage("lyricMode.backgroundOpacity") var backgroundOpacity: Double = 0.8
    @AppStorage("lyricMode.showPartialHighlight") var showPartialHighlight: Bool = true
    
    // Transcription settings (separate from global settings)
    @AppStorage("lyricMode.selectedModelName") var selectedModelName: String = ""
    @AppStorage("lyricMode.selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage("lyricMode.temperature") var temperature: Double = 0.0
    @AppStorage("lyricMode.beamSize") var beamSize: Int = 1
    @AppStorage("lyricMode.silenceDuration") var silenceDuration: Double = 0.5
    @AppStorage("lyricMode.selectedAudioDeviceUID") var selectedAudioDeviceUID: String = ""
    @AppStorage("lyricMode.whisperPrompt") var whisperPrompt: String = ""
    
    static let shared = LyricModeSettings()
    
    private init() {}
}
