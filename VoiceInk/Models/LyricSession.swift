import SwiftData
import Foundation

/// Represents a saved Lyric Mode session
@Model
final class LyricSession {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var transcriptSegments: [String]
    var translatedSegments: [String]
    var audioFilePath: String? // Reserved for future audio recording support
    var targetLanguage: String
    var title: String
    var summary: String? // AI Summary
    
    // Custom formatted date string for display (computed property, not stored)
    @Transient var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    init(id: UUID = UUID(), timestamp: Date = Date(), duration: TimeInterval, transcriptSegments: [String], translatedSegments: [String], audioFilePath: String? = nil, targetLanguage: String, title: String, summary: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.transcriptSegments = transcriptSegments
        self.translatedSegments = translatedSegments
        self.audioFilePath = audioFilePath
        self.targetLanguage = targetLanguage
        self.title = title
        self.summary = summary
    }
}
