import Foundation
import os

/// LLMTextCorrector: Uses Ollama to correct Japanese speech recognition errors.
/// - Adds punctuation (、。！？) at natural positions
/// - Fixes typos and homophones based on context
/// - Does NOT answer questions or add extra text
///
/// Uses the existing OllamaService for inference.
@available(macOS 14.0, *)
actor LLMTextCorrector {
    
    // MARK: - Types
    
    enum TextCorrectorError: LocalizedError {
        case ollamaNotConnected
        case generationFailed(String)
        case timeout
        
        var errorDescription: String? {
            switch self {
            case .ollamaNotConnected:
                return "Ollama service is not connected. Please ensure Ollama is running."
            case .generationFailed(let reason):
                return "Text correction failed: \(reason)"
            case .timeout:
                return "Text correction timed out"
            }
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.voiceink", category: "LLMTextCorrector")
    private let ollamaService: OllamaService
    
    /// System prompt for Japanese text correction
    private let systemPrompt = """
    あなたは音声認識の誤りを修正するAIアシスタントです。以下のルールに従って、入力されたテキストを修正してください。
    【ルール】
    1. 句読点（、。！？）を自然な位置に追加して、文を区切る。
    2. 質問には答えず、修正したテキストのみを出力する。
    3. 余計な挨拶や説明は一切書かない。

    【例】
    入力: 今日はいい天気ですね散歩に行きましょうか
    出力: 今日はいい天気ですね。散歩に行きましょうか？
    """
    
    // MARK: - Initialization
    
    /// Initialize the text corrector with an OllamaService instance
    /// - Parameter ollamaService: The Ollama service to use for inference
    init(ollamaService: OllamaService? = nil) {
        // Use provided service or create a new one
        self.ollamaService = ollamaService ?? OllamaService()
    }
    
    // MARK: - Text Correction
    
    /// Correct Japanese text by adding punctuation and fixing typos
    /// - Parameters:
    ///   - input: Raw speech recognition text
    ///   - model: Optional model name to use (defaults to OllamaService's selected model)
    /// - Returns: Corrected text with proper punctuation
    func correctText(_ input: String, model: String? = nil) async throws -> String {
        print("🤖 [Ollama] Correcting: '\(input)' with model: \(model ?? "default")")
        
        do {
            let result = try await ollamaService.enhance(input, withSystemPrompt: systemPrompt, model: model)
            
            // Clean up the result - remove any "出力:" prefix if model included it
            var cleanedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if cleanedResult.hasPrefix("出力:") {
                cleanedResult = String(cleanedResult.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            if cleanedResult.hasPrefix("出力：") {
                cleanedResult = String(cleanedResult.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            
            print("✨ [Ollama] Result: '\(cleanedResult)'")
            
            return cleanedResult
        } catch {
            print("⚠️ [Ollama] Correction failed: \(error.localizedDescription)")
            throw TextCorrectorError.generationFailed(error.localizedDescription)
        }
    }
}

// MARK: - Convenience Extensions

@available(macOS 14.0, *)
extension LLMTextCorrector {
    /// Shared instance using a new OllamaService
    static let shared = LLMTextCorrector()
    
    /// Correct text with a timeout and optional model
    func correctText(_ input: String, model: String? = nil, timeout: TimeInterval) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Task 1: The actual correction
            group.addTask {
                return try await self.correctText(input, model: model)
            }
            
            // Task 2: The timeout race
            group.addTask {
                // Sleep for timeout duration
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If we wake up, it means timeout happened
                throw TextCorrectorError.timeout
            }
            
            // Wait for the first one to complete
            do {
                if let result = try await group.next() {
                    group.cancelAll() // Cancel timeout task
                    return result
                } else {
                    // Should not happen if tasks are added correctly
                    throw TextCorrectorError.generationFailed("Unknown error (empty task group)")
                }
            } catch {
                group.cancelAll() // Cancel other task
                
                // Enhance error logging
                if let correctorError = error as? TextCorrectorError, case .timeout = correctorError {
                    print("⏱️ [LLMTextCorrector] Operation timed out after \(timeout)s for input: '\(input.prefix(20))...'")
                } else {
                    print("⚠️ [LLMTextCorrector] Unexpected error: \(error.localizedDescription)")
                }
                
                throw error
            }
        }
    }
}
