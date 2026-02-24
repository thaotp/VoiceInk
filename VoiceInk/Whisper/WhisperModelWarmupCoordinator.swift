import Foundation
import Combine

@MainActor
final class WhisperModelWarmupCoordinator: ObservableObject {
    static let shared = WhisperModelWarmupCoordinator()
    
    @Published private(set) var warmingModels: Set<String> = []
    
    private init() {}
    
    func isWarming(modelNamed name: String) -> Bool {
        warmingModels.contains(name)
    }
    
    func scheduleWarmup(for model: LocalModel, whisperState: WhisperState) {
        guard shouldWarmup(modelName: model.name),
              !warmingModels.contains(model.name) else {
            return
        }
        
        warmingModels.insert(model.name)
        
        Task {
            do {
                try await runWarmup(for: model, whisperState: whisperState)
            } catch {
                await MainActor.run {
                    whisperState.logger.error("Warmup failed for \(model.name): \(error.localizedDescription)")
                }
            }
            
            await MainActor.run {
                self.warmingModels.remove(model.name)
            }
        }
    }
    
    private func runWarmup(for model: LocalModel, whisperState: WhisperState) async throws {
        guard let sampleURL = warmupSampleURL() else { return }
        guard let selectedModel = whisperState.allAvailableModels.first(where: { $0.name == model.name }) else {
            return
        }

        // Warmup now uses the unified transcription registry because local whisper.cpp is removed.
        let registry = TranscriptionServiceRegistry(
            whisperState: whisperState,
            modelsDirectory: whisperState.modelsDirectory
        )
        _ = try await registry.transcribe(audioURL: sampleURL, model: selectedModel)
    }
    
    private func warmupSampleURL() -> URL? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "esc", withExtension: "wav", subdirectory: "Resources/Sounds"),
            bundle.url(forResource: "esc", withExtension: "wav", subdirectory: "Sounds"),
            bundle.url(forResource: "esc", withExtension: "wav")
        ]

        for candidate in candidates {
            if let url = candidate {
                return url
            }
        }

        return nil
    }
    
    private func shouldWarmup(modelName: String) -> Bool {
        !modelName.contains("q5") && !modelName.contains("q8")
    }
}
