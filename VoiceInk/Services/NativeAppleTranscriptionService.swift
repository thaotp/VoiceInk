import Foundation
import AVFoundation
import os

#if canImport(Speech)
import Speech
#endif

/// Transcription service that leverages the new SpeechAnalyzer / SpeechTranscriber API available on macOS 26 (Tahoe).
/// Falls back with an unsupported-provider error on earlier OS versions so the application can gracefully degrade.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NativeAppleTranscriptionService")
    
    /// Maps simple language codes to Apple's BCP-47 locale format
    private func mapToAppleLocale(_ simpleCode: String) -> String {
        let mapping = [
            "en": "en-US",
            "es": "es-ES", 
            "fr": "fr-FR",
            "de": "de-DE",
            "ar": "ar-SA",
            "it": "it-IT",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "vi": "vi-VN",
            "yue": "yue-CN",
            "zh": "zh-CN"
        ]
        return mapping[simpleCode] ?? "en-US"
    }
    
    enum ServiceError: Error, LocalizedError {
        case unsupportedOS
        case transcriptionFailed
        case localeNotSupported
        case invalidModel
        case assetAllocationFailed
        
        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "SpeechAnalyzer requires macOS 26 or later."
            case .transcriptionFailed:
                return "Transcription failed using SpeechAnalyzer."
            case .localeNotSupported:
                return "The selected language is not supported by SpeechAnalyzer."
            case .invalidModel:
                return "Invalid model type provided for Native Apple transcription."
            case .assetAllocationFailed:
                return "Failed to allocate assets for the selected locale."
            }
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model is NativeAppleModel else {
            throw ServiceError.invalidModel
        }
        
        guard #available(macOS 26, *) else {
            logger.error("SpeechAnalyzer is not available on this macOS version")
            throw ServiceError.unsupportedOS
        }
        
        // Feature gated: SpeechAnalyzer/SpeechTranscriber are future APIs.
        // Enable by defining ENABLE_NATIVE_SPEECH_ANALYZER in build settings once building against macOS 26+ SDKs.
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        logger.notice("Starting Apple native transcription with SpeechAnalyzer.")
        
        let audioFile = try AVAudioFile(forReading: audioURL)
        
        // Get the user's selected language in simple format and convert to BCP-47 format
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
        let appleLocale = mapToAppleLocale(selectedLanguage)
        let locale = Locale(identifier: appleLocale)

        // Check for locale support and asset installation status using proper BCP-47 format
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        let isLocaleSupported = supportedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))
        let isLocaleInstalled = installedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))

        // Create the detailed log message
        let supportedIdentifiers = supportedLocales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        let installedIdentifiers = installedLocales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        let availableForDownload = Set(supportedLocales).subtracting(Set(installedLocales)).map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        
        var statusMessage: String
        if isLocaleInstalled {
            statusMessage = "✅ Installed"
        } else if isLocaleSupported {
            statusMessage = "❌ Not Installed (Available for download)"
        } else {
            statusMessage = "❌ Not Supported"
        }
        
        let logMessage = """
        
        --- Native Speech Transcription ---
        Selected Language: '\(selectedLanguage)' → Apple Locale: '\(locale.identifier(.bcp47))'
        Status: \(statusMessage)
        ------------------------------------
        Supported Locales: [\(supportedIdentifiers)]
        Installed Locales: [\(installedIdentifiers)]
        Available for Download: [\(availableForDownload)]
        ------------------------------------
        """
        logger.notice("\(logMessage)")

        if !isLocaleSupported {
            logger.notice("Locale '\(locale.identifier(.bcp47))' not supported by SpeechTranscriber, falling back to SFSpeechRecognizer.")
            return try await transcribeUsingSFSpeechRecognizer(audioURL: audioURL, locale: locale)
        }
        
        // Asset reservations are managed automatically by the system.
        
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        
        // Ensure model assets are available, triggering a system download prompt if necessary.
        try await ensureModelIsAvailable(for: transcriber, locale: locale)
        
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        
        var transcript: AttributedString = ""
        for try await result in transcriber.results {
            transcript += result.text
        }
        
        var finalTranscription = String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        logger.notice("Native transcription successful. Length: \(finalTranscription.count) characters.")
        return finalTranscription
        #else
        logger.notice("Native Apple transcription is disabled in this build (future Speech APIs not enabled).")
        throw ServiceError.unsupportedOS
        #endif
    }
    
    // MARK: - SFSpeechRecognizer Fallback
    
    /// Fallback transcription using SFSpeechRecognizer for locales not supported by SpeechTranscriber
    private func transcribeUsingSFSpeechRecognizer(audioURL: URL, locale: Locale) async throws -> String {
        logger.notice("Using SFSpeechRecognizer fallback for locale: \(locale.identifier)")
        
        // Check authorization
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus != .authorized {
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard authorized else {
                throw ServiceError.transcriptionFailed
            }
        }
        
        // Create recognizer for the locale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            logger.error("SFSpeechRecognizer not available for locale: \(locale.identifier)")
            throw ServiceError.localeNotSupported
        }
        
        // Create recognition request for the audio file
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        
        // Perform recognition
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    self.logger.error("SFSpeechRecognizer error: \(error.localizedDescription)")
                    continuation.resume(throwing: ServiceError.transcriptionFailed)
                    return
                }
                
                guard let result = result, result.isFinal else {
                    return
                }
                
                let transcript = result.bestTranscription.formattedString
                self.logger.notice("SFSpeechRecognizer transcription successful. Length: \(transcript.count) characters.")
                continuation.resume(returning: transcript)
            }
        }
    }
    
    
    
    // Forward-compatibility: Use Any here because SpeechTranscriber is only available in future macOS SDKs.
    // This avoids referencing an unavailable SDK symbol while keeping the method shape for later adoption.
    @available(macOS 26, *)
    private func ensureModelIsAvailable(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let installedLocales = await SpeechTranscriber.installedLocales
        let isInstalled = installedLocales.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47))

        if !isInstalled {
            logger.notice("Assets for '\(locale.identifier(.bcp47))' not installed. Requesting system download.")
            
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                logger.notice("Asset download for '\(locale.identifier(.bcp47))' complete.")
            } else {
                logger.error("Asset download for '\(locale.identifier(.bcp47))' failed: Could not create installation request.")
                // Note: We don't throw an error here, as transcription might still work with a base model.
            }
        }
        #endif
    }
} 
