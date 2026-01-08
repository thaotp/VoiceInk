import SwiftUI

/// Settings model for Lyric Mode appearance and behavior
class LyricModeSettings: ObservableObject {
    @AppStorage("lyricMode.maxVisibleLines") var maxVisibleLines: Int = 5
    @AppStorage("lyricMode.fontSize") var fontSize: Double = 24
    @AppStorage("lyricMode.isClickThroughEnabled") var isClickThroughEnabled: Bool = false
    @AppStorage("lyricMode.backgroundOpacity") var backgroundOpacity: Double = 0.8
    @AppStorage("lyricMode.showPartialHighlight") var showPartialHighlight: Bool = true
    
    static let shared = LyricModeSettings()
    
    private init() {}
}
