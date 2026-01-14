import Foundation

/// Lightweight translation service for Lyric Mode using Ollama Chat API
/// Maintains conversation history for context-aware translations
/// Uses serial queue to process requests sequentially (avoids Ollama bottlenecks)
class LyricModeTranslationService {
    
    private let settings = LyricModeSettings.shared
    
    /// Message history for context retention
    private var messageHistory: [[String: String]] = []
    
    /// Maximum messages to retain (to prevent token overflow)
    private let maxHistoryMessages = 20
    
    /// Serial semaphore for sequential translation requests (1 at a time)
    private let translationSemaphore = AsyncSemaphore(value: 1)
    
    /// Clear conversation history (call when starting new session)
    func clearHistory() {
        messageHistory = []
    }
    
    /// Cancel pending (queued) translation requests
    func cancelPendingRequests() async {
        await translationSemaphore.cancelAll()
    }
    
    /// Translate text to the target language using configured Ollama model
    /// Requests are processed sequentially to avoid overwhelming Ollama
    func translate(_ text: String) async throws -> String {
        guard !text.isEmpty else { return "" }
        
        // Wait for any in-progress translation to complete (sequential processing)
        // This will throw if cancelled
        try await translationSemaphore.wait()
        defer {
            Task { await translationSemaphore.signal() }
        }
        
        // Final check for cancellation before starting network request
        if Task.isCancelled { return "" }
        
        let startTime = Date()
        print("[Translation] Starting translation for: \(text.prefix(30))...")
        
        let baseURL = settings.ollamaBaseURL
        let model = settings.selectedOllamaModel
        let targetLanguage = settings.targetLanguage
        
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw TranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        let systemPrompt = """
        You are a professional human translator and localizer.

        ROLE:
        Translate the input text from Japanese into \(targetLanguage) as a fluent, natural, and idiomatic human translation, while fully preserving the original meaning.

        REQUIREMENTS:
        1. COMPLETENESS:
        Translate every sentence. Do not omit, merge, summarize, or add any information.

        2. SENTENCE ALIGNMENT:
        Keep a clear one-to-one correspondence between source sentences and translated sentences.
        If a source sentence is long, you may restructure it internally, but it must remain a single translated sentence.

        3. NATURALNESS:
        The translation should read like it was originally written in \(targetLanguage), not like a literal translation.
        Prefer natural phrasing, correct grammar, and appropriate style over word-for-word mapping.

        4. MEANING FIDELITY:
        Preserve 100% of the original meaning, tone, and intent.

        5. TERMINOLOGY:
        Keep technical terms in English (e.g., Python, RAM, API) unless a widely accepted local term exists.

        6. INCOMPLETE SENTENCES:
        If a source sentence is incomplete, cut off, or intentionally left unfinished, reflect this in the translation by keeping it incomplete and appending "..." at the end.

        OUTPUT RULES:
        - Output only the translated text.
        - Do not include explanations, comments, formatting, or markdown.
        - Do not repeat the source text.

        FINAL CHECK:
        Before outputting, ensure that:
        - All sentences are translated.
        - The number of translated sentences matches the number of source sentences.
        - Incomplete sentences end with "...".
        - The result reads naturally in \(targetLanguage).
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
        
        let duration = Date().timeIntervalSince(startTime)
        print("[Translation] Completed in \(String(format: "%.2f", duration))s")
        
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

// MARK: - Serial Translation Queue

/// Simple async semaphore to ensure sequential translation requests
/// Prevents overwhelming Ollama with parallel requests
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []
    
    init(value: Int = 1) {
        self.count = value
    }
    
    func wait() async throws {
        if count > 0 {
            count -= 1
            return
        }
        
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
    
    /// Cancel all waiting tasks
    func cancelAll() {
        // Resume all waiters with cancellation error
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
        waiters.removeAll()
        // Reset count to initial value to allow fresh start
        count = 1
    }
}
