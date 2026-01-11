import Foundation

/// Lightweight translation service for Lyric Mode using Ollama Chat API
/// Maintains conversation history for context-aware translations
class LyricModeTranslationService {
    
    private let settings = LyricModeSettings.shared
    
    /// Message history for context retention
    private var messageHistory: [[String: String]] = []
    
    /// Maximum messages to retain (to prevent token overflow)
    private let maxHistoryMessages = 20
    
    /// Clear conversation history (call when starting new session)
    func clearHistory() {
        messageHistory = []
    }
    
    /// Translate text to the target language using configured Ollama model
    func translate(_ text: String) async throws -> String {
        guard !text.isEmpty else { return "" }
        
        let baseURL = settings.ollamaBaseURL
        let model = settings.selectedOllamaModel
        let targetLanguage = settings.targetLanguage
        
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw TranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let systemPrompt = """
        You are an expert translator specializing in faithful, accurate localization.
        ROLE:
        Translate text from English to \(targetLanguage) preserving 100% of the original meaning and structure.

        CRITICAL INSTRUCTIONS:
        1. COMPLETENESS: Translate every single sentence. Do NOT summarize, skip, or condense any information.
        2. MAPPING: Maintain a 1:1 correspondence between source sentences and translated sentences.
        3. LANGUAGE: Use natural, fluent \(targetLanguage). Avoid "translationese".
        4. TERMINOLOGY: Keep technical terms in English (e.g., Python, RAM) unless a standard local term exists.

        OUTPUT FORMAT:
        - Output ONLY the final translation.
        - No conversational filler, no markdown blocks (unless requested), no explanations.

        VERIFICATION:
        Before outputting, internally verify that the number of sentences in the translation matches the source.
        """
        
        // Build messages array with system prompt and history
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        
        // Add conversation history
        messages.append(contentsOf: messageHistory)
        
        // Add current translation request
        let userMessage = "Translate to \(targetLanguage): \(text)"
        messages.append(["role": "user", "content": userMessage])
        
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": 0.1
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw TranslationError.serverError(httpResponse.statusCode)
        }
        
        struct OllamaChatResponse: Codable {
            let message: Message
            
            struct Message: Codable {
                let role: String
                let content: String
            }
        }
        
        let ollamaResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let translation = ollamaResponse.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Add to history for context retention
        messageHistory.append(["role": "user", "content": userMessage])
        messageHistory.append(["role": "assistant", "content": translation])
        
        // Prune history if too long (keep recent messages)
        if messageHistory.count > maxHistoryMessages {
            messageHistory = Array(messageHistory.suffix(maxHistoryMessages))
        }
        
        return translation
    }
}

// MARK: - Errors

enum TranslationError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .notConnected:
            return "Ollama is not connected"
        }
    }
}
