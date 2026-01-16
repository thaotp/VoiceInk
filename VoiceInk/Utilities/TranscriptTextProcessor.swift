import Foundation

/// Utility for processing transcription text segments
/// Handles overlap detection, duplicate checking, and sentence continuity
enum TranscriptTextProcessor {
    
    // MARK: - Constants
    
    /// Punctuation marks that indicate the end of a sentence
    static let sentenceEndingPunctuation: Set<Character> = [
        "。", "！", "？",  // Japanese/Chinese
        ".", "!", "?",    // English
        "」", "』",        // Closing quotes (Japanese)
        "\u{201D}",       // Right double quotation mark "
        "\u{2019}"        // Right single quotation mark '
    ]
    
    /// Maximum overlap length to search for (performance optimization)
    static let maxOverlapSearchLength = 200
    
    /// Minimum overlap length to consider (avoid false positives)
    static let minOverlapSearchLength = 3
    
    // MARK: - Overlap Detection
    
    /// Removes overlapping content from new text that already exists at the end of existing text
    /// - Parameters:
    ///   - newText: The new text to process
    ///   - existingText: The existing accumulated text
    /// - Returns: The new text with overlap removed, or nil if all content already exists
    static func removeOverlap(from newText: String, existingText: String) -> String? {
        guard !newText.isEmpty, !existingText.isEmpty else { return newText }
        
        let maxLength = min(newText.count, existingText.count, maxOverlapSearchLength)
        
        for overlapLength in stride(from: maxLength, through: minOverlapSearchLength, by: -1) {
            let existingEnd = String(existingText.suffix(overlapLength))
            if newText.hasPrefix(existingEnd) {
                let newContent = String(newText.dropFirst(overlapLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return newContent.isEmpty ? nil : newContent
            }
        }
        
        return newText
    }
    
    // MARK: - Duplicate Detection
    
    /// Check if new text is a duplicate of existing text
    /// - Parameters:
    ///   - newText: The new text to check
    ///   - existingText: The existing text to compare against
    /// - Returns: True if the text should be skipped as a duplicate
    static func isDuplicate(_ newText: String, of existingText: String) -> Bool {
        // Exact duplicate
        if existingText == newText {
            return true
        }
        // New text is prefix of existing (already processed)
        if existingText.hasPrefix(newText) {
            return true
        }
        // Substantial overlap
        if existingText.contains(newText) || newText.contains(existingText) {
            return true
        }
        return false
    }
    
    /// Check if new text is a cumulative update (extends existing text)
    /// - Parameters:
    ///   - newText: The new text
    ///   - existingText: The existing text
    /// - Returns: True if new text starts with existing text
    static func isCumulativeUpdate(_ newText: String, of existingText: String) -> Bool {
        return newText.hasPrefix(existingText) && newText != existingText
    }
    
    /// Check if new text is a "replacement" (correction/extension) of existing text
    /// This handles cases where the engine corrects a word or adds punctuation
    static func isReplacementOf(_ newText: String, existingText: String) -> Bool {
        // If entirely different, not a replacement
        if newText.isEmpty || existingText.isEmpty { return false }
        
        // If new text contains the existing text (fuzzy match could be better but strict containment is safe start)
        // We normalize simply by removing punctuation/spaces for the check
        let normalizedNew = newText.filter { !$0.isWhitespace && !$0.isPunctuation }
        let normalizedExisting = existingText.filter { !$0.isWhitespace && !$0.isPunctuation }
        
        // If the core content is a prefix, it's a replacement/extension
        return normalizedNew.hasPrefix(normalizedExisting)
    }
    
    // MARK: - Sentence Continuity
    
    /// Check if text ends with a complete sentence
    static func endsWithCompleteSentence(_ text: String) -> Bool {
        guard let lastChar = text.last else { return false }
        return sentenceEndingPunctuation.contains(lastChar)
    }
    
    /// Extract the incomplete sentence portion from the end of text
    /// - Returns: Tuple of (complete part, incomplete part) or nil if text ends with complete sentence
    static func extractIncompleteSentence(from text: String) -> (complete: String, incomplete: String)? {
        guard !endsWithCompleteSentence(text) else { return nil }
        
        if let lastPunctuationIndex = text.lastIndex(where: { sentenceEndingPunctuation.contains($0) }) {
            let incompleteStartIndex = text.index(after: lastPunctuationIndex)
            let incompletePart = String(text[incompleteStartIndex...])
                .trimmingCharacters(in: .whitespaces)
            
            if !incompletePart.isEmpty {
                let completePart = String(text[...lastPunctuationIndex])
                return (completePart, incompletePart)
            }
        }
        
        return nil
    }
    
    // MARK: - Similarity Detection
    
    /// Calculate similarity ratio between two strings (0.0 to 1.0)
    /// Uses longest common subsequence ratio
    static func similarityRatio(_ text1: String, _ text2: String) -> Double {
        guard !text1.isEmpty && !text2.isEmpty else { return 0.0 }
        
        let s1 = Array(text1.lowercased())
        let s2 = Array(text2.lowercased())
        
        // Use LCS (Longest Common Subsequence) for similarity
        let lcsLength = longestCommonSubsequenceLength(s1, s2)
        let maxLength = max(s1.count, s2.count)
        
        return Double(lcsLength) / Double(maxLength)
    }
    
    /// Calculate longest common subsequence length
    private static func longestCommonSubsequenceLength(_ s1: [Character], _ s2: [Character]) -> Int {
        let m = s1.count
        let n = s2.count
        
        // Optimization: use only two rows instead of full matrix
        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)
        
        for i in 1...m {
            for j in 1...n {
                if s1[i - 1] == s2[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
            curr = [Int](repeating: 0, count: n + 1)
        }
        
        return prev[n]
    }
    
    /// Check if new text is too similar to any existing segment
    /// - Parameters:
    ///   - newText: The new text to check
    ///   - existingSegments: Array of existing segments
    ///   - threshold: Similarity threshold (default 0.3 = 30%)
    /// - Returns: True if new text is too similar to any existing segment
    static func isTooSimilarToAny(_ newText: String, in existingSegments: [String], threshold: Double = 0.3) -> Bool {
        for existing in existingSegments {
            let similarity = similarityRatio(newText, existing)
            if similarity > threshold {
                return true
            }
        }
        return false
    }
}
