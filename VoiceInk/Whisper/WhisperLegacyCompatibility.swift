import Foundation

/// Legacy local model representation kept for source compatibility
/// after removing whisper.cpp from the app.
struct LocalModel: Identifiable, Hashable {
    let id: UUID
    let name: String
    let url: URL

    init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

typealias WhisperModel = LocalModel

/// Lightweight compatibility context used by old realtime interfaces.
/// The whisper.cpp backend is removed, so this context is intentionally inert.
actor WhisperContext {
    private var prompt: String = ""

    func setPrompt(_ prompt: String) {
        self.prompt = prompt
    }

    func fullTranscribe(samples: [Float]) async -> Bool {
        false
    }

    func getTranscription() async -> String {
        ""
    }
}

@MainActor
extension WhisperState {
    func unloadModel() {
        Task { await cleanupModelResources() }
    }

    func loadModel(_ model: LocalModel) async throws {
        logger.notice("Local whisper.cpp model loading is deprecated: \(model.name)")
        isModelLoaded = false
    }

    func deleteModel(_ model: LocalModel) async {
        availableModels.removeAll { $0.name == model.name }

        if currentTranscriptionModel?.name == model.name {
            currentTranscriptionModel = nil
            UserDefaults.standard.removeObject(forKey: "CurrentTranscriptionModel")
        }
    }

    func cleanupModelResources() async {
        whisperContext = nil
        serviceRegistry.cleanup()
        isModelLoaded = false
    }
}
