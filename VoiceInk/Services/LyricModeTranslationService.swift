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
        You are a helpful assistant. Your goal is to provide helpful, accurate, and detailed responses.

        CORE INSTRUCTIONS:
        1. LANGUAGE: Answer strictly in \(targetLanguage). Use natural, fluent \(targetLanguage) (avoid "translationese" or stiff word-for-word translation).
        2. TERMINOLOGY: Keep technical terms in English if they are commonly used (e.g., Python, RAM, CPU), but explain them in \(targetLanguage) if necessary.
        3. FORMATTING: Raw text. Output ONLY the translation, nothing else
        4. TONE: Professional, objective, yet friendly.

        RESTRICTIONS:
        - Do not make up facts. If you don't know, admit it.
        - Remember the context of previous translations in this session.
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
