import Foundation
import os

/// Translation service for Lyric Mode using Gemini API
/// Sends Japanese text and returns Vietnamese translation, corrected/spaced Japanese, typo fixes, and grammar analysis
class GeminiTranslationService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "GeminiTranslation")
    
    /// Track active URLSession tasks for cancellation
    private var activeTasks: [URLSessionTask] = []
    private let taskLock = NSLock()
    
    /// Cancel all pending Gemini API requests
    func cancelPendingRequests() {
        taskLock.lock()
        let tasks = activeTasks
        activeTasks.removeAll()
        taskLock.unlock()
        
        for task in tasks {
            task.cancel()
        }
        if !tasks.isEmpty {
            logger.info("Cancelled \(tasks.count) pending Gemini request(s)")
        }
    }
    
    /// Gemini API request models
    private struct GeminiRequest: Codable {
        let contents: [GeminiContent]
        let generationConfig: GenerationConfig?
    }
    
    private struct GenerationConfig: Codable {
        let temperature: Double?
        let responseMimeType: String?
        let thinkingConfig: ThinkingConfig?
    }
    
    private struct ThinkingConfig: Codable {
        let thinkingBudget: Int
    }
    
    private struct GeminiContent: Codable {
        let parts: [GeminiTextPart]
    }
    
    private struct GeminiTextPart: Codable {
        let text: String
    }
    
    private struct GeminiResponse: Codable {
        let candidates: [GeminiCandidate]
    }
    
    private struct GeminiCandidate: Codable {
        let content: GeminiResponseContent
    }
    
    private struct GeminiResponseContent: Codable {
        let parts: [GeminiResponsePart]
    }
    
    private struct GeminiResponsePart: Codable {
        let text: String
    }
    
    // MARK: - Public Result Types
    
    /// A single typo fix entry
    struct TypoFix: Codable {
        let original: String
        let fixed: String
    }
    
    /// A grammar clause breakdown
    struct GrammarClause: Codable {
        let s: String  // Subject
        let v: String  // Predicate
        let o: String  // Object/Complement
    }
    
    /// Full result from Gemini translation
    struct GeminiTranslationResult {
        let vn: String
        let jaFixedSpaced: String
        let typoFix: [TypoFix]
        let grammar: [GrammarClause]
    }
    
    /// JSON response schema from Gemini
    private struct TranslationResponse: Codable {
        let vn: String
        let ja_fixed_spaced: String
        let typo_fix: [TypoFix]?
        let grammar: [GrammarClause]?
    }
    
    // MARK: - Translate
    
    /// Translate Japanese text using Gemini API
    /// Returns Vietnamese translation, corrected/spaced Japanese, typo fixes, and grammar analysis
    func translate(_ text: String, model: String = "gemini-2.0-flash") async throws -> GeminiTranslationResult {
        guard !text.isEmpty else {
            return GeminiTranslationResult(vn: "", jaFixedSpaced: "", typoFix: [], grammar: [])
        }
        
        // Get API key
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Gemini"), !apiKey.isEmpty else {
            logger.error("Gemini API key not configured")
            throw GeminiTranslationError.missingAPIKey
        }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GeminiTranslationError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        // Build prompt
        let prompt = """
        Task:

        Translate the original text into natural Vietnamese.

        Fix all dictation/typo errors in the input Japanese text based on context.

        Segment the corrected Japanese text with spaces and proper punctuation.

        Extract grammatical components for each clause: Subject (s), Predicate (v), and Object/Complement (o).

        Output JSON schema:
        {
        "vn": "Vietnamese translation",
        "ja_fixed_spaced": "corrected and spaced Japanese with punctuation",
        "typo_fix": [
        {"original": "string", "fixed": "string"}
        ],
        "grammar": [
        {"s": "Subject", "v": "Predicate", "o": "Object/Complement"}
        ]
        }

        Constraints:

        Strictly NO preamble, NO introductory or concluding remarks.

        Respond ONLY with the JSON object.

        In the "grammar" section, if the subject is omitted in Japanese, infer it from context and place it in parentheses.

        No POS tags, no slashes, no additional explanations.

        Input: \(text)
        """
        
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(parts: [GeminiTextPart(text: prompt)])
            ],
            generationConfig: GenerationConfig(
                temperature: 0.1,
                responseMimeType: "application/json",
                thinkingConfig: ThinkingConfig(thinkingBudget: 0)
            )
        )
        
        let startTime = Date()
        
        do {
            let jsonData = try JSONEncoder().encode(requestBody)
            request.httpBody = jsonData
        } catch {
            logger.error("Failed to encode Gemini request: \(error.localizedDescription)")
            throw GeminiTranslationError.encodingError
        }
        
        // Create and track the URLSession task
        let sessionTask = URLSession.shared.dataTask(with: request) { _, _, _ in }
        taskLock.lock()
        activeTasks.append(sessionTask)
        taskLock.unlock()
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Remove from active tasks on failure
            taskLock.lock()
            activeTasks.removeAll { $0 === sessionTask }
            taskLock.unlock()
            throw error
        }
        
        // Remove from active tasks on completion
        taskLock.lock()
        activeTasks.removeAll { $0 === sessionTask }
        taskLock.unlock()
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiTranslationError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Gemini API error (\(httpResponse.statusCode)): \(errorMessage)")
            throw GeminiTranslationError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        // Parse Gemini response
        let geminiResponse: GeminiResponse
        do {
            geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            logger.error("Failed to decode Gemini response: \(error.localizedDescription)")
            throw GeminiTranslationError.decodingError
        }
        
        guard let candidate = geminiResponse.candidates.first,
              let part = candidate.content.parts.first,
              !part.text.isEmpty else {
            throw GeminiTranslationError.emptyResponse
        }
        
        // Parse the JSON response
        let jsonText = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let result: GeminiTranslationResult
        do {
            guard let jsonData = jsonText.data(using: .utf8) else {
                throw GeminiTranslationError.decodingError
            }
            let parsed = try JSONDecoder().decode(TranslationResponse.self, from: jsonData)
            result = GeminiTranslationResult(
                vn: parsed.vn,
                jaFixedSpaced: parsed.ja_fixed_spaced,
                typoFix: parsed.typo_fix ?? [],
                grammar: parsed.grammar ?? []
            )
        } catch {
            // Fallback: try manual extraction
            logger.warning("JSON decode failed, attempting manual extraction: \(error.localizedDescription)")
            let vn = extractField("vn", from: jsonText) ?? jsonText
            let ja = extractField("ja_fixed_spaced", from: jsonText) ?? text
            result = GeminiTranslationResult(vn: vn, jaFixedSpaced: ja, typoFix: [], grammar: [])
        }
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("Gemini translation completed in \(String(format: "%.2f", duration))s")
        print("[GeminiTranslation] Completed in \(String(format: "%.2f", duration))s: \(text.prefix(30))... -> vn: \(result.vn.prefix(40))... ja: \(result.jaFixedSpaced.prefix(40))...")
        if !result.typoFix.isEmpty {
            print("[GeminiTranslation] Typo fixes: \(result.typoFix.map { "\($0.original) -> \($0.fixed)" }.joined(separator: ", "))")
        }
        
        return result
    }
    
    /// Manual extraction of a JSON string field as fallback
    private func extractField(_ field: String, from json: String) -> String? {
        let patterns = [
            "\"\(field)\"\\s*:\\s*\"([^\"]+)\"",
            "\"\(field)\"\\s*:\\s*'([^']+)'"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
               let range = Range(match.range(at: 1), in: json) {
                return String(json[range])
            }
        }
        
        return nil
    }
}

// MARK: - Errors

enum GeminiTranslationError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case encodingError
    case invalidResponse
    case apiError(Int, String)
    case decodingError
    case emptyResponse
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemini API key not configured. Add it in Settings > AI Models."
        case .invalidURL:
            return "Invalid Gemini API URL"
        case .encodingError:
            return "Failed to encode request"
        case .invalidResponse:
            return "Invalid response from Gemini"
        case .apiError(let code, let message):
            return "Gemini API error (\(code)): \(message)"
        case .decodingError:
            return "Failed to decode Gemini response"
        case .emptyResponse:
            return "Empty response from Gemini"
        }
    }
}
