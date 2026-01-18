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
    2. 文脈を判断し、誤字や誤変換（同音異義語）を修正する。
    3. 質問には答えず、修正したテキストのみを出力する。
    4. 余計な挨拶や説明は一切書かない。

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
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.correctText(input, model: model)
            }
            
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TextCorrectorError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
