import Foundation
import os

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Manages WhisperKit model downloads and storage
@MainActor
class WhisperKitModelManager: ObservableObject {
    
    static let shared = WhisperKitModelManager()
    
    // MARK: - Published Properties
    
    @Published private(set) var downloadedModels: [WhisperKitModelInfo] = []
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var recommendedModel: String?
    @Published private(set) var isLoadingModels = false
    @Published private(set) var downloadingModels: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperKitModelManager")
    private let fileManager = FileManager.default
    
    private var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("VoiceInk/WhisperKitModels", isDirectory: true)
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: modelsDir.path) {
            try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }
        
        return modelsDir
    }
    
    // MARK: - Initialization
    
    private init() {
        loadDownloadedModels()
    }
    
    // MARK: - Model Discovery
    
    /// Fetch available models from HuggingFace
    func fetchAvailableModels(from repo: String = "argmaxinc/whisperkit-coreml") async {
        isLoadingModels = true
        errorMessage = nil
        
        #if canImport(WhisperKit)
        do {
            let models = try await WhisperKit.fetchAvailableModels(from: repo)
            await MainActor.run {
                self.availableModels = models.sorted()
                self.isLoadingModels = false
            }
            
            // Get recommended model
            let modelSupport = await WhisperKit.recommendedRemoteModels()
            await MainActor.run {
                self.recommendedModel = modelSupport.default
            }
            
            logger.info("Fetched \(models.count) available WhisperKit models")
        } catch {
            logger.error("Failed to fetch available models: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Failed to fetch models: \(error.localizedDescription)"
                self.isLoadingModels = false
            }
        }
        #else
        await MainActor.run {
            self.errorMessage = "WhisperKit is not available. Please link WhisperKit to your target."
            self.isLoadingModels = false
        }
        #endif
    }
    
    // MARK: - Model Download
    
    /// Download a model
    func downloadModel(_ modelName: String, from repo: String = "argmaxinc/whisperkit-coreml") async throws {
        guard !downloadingModels.contains(modelName) else { return }
        
        await MainActor.run {
            downloadingModels.insert(modelName)
            downloadProgress[modelName] = 0
            errorMessage = nil
        }
        
        #if canImport(WhisperKit)
        do {
            logger.info("Downloading WhisperKit model: \(modelName)")
            
            // WhisperKit will download to its default location
            // We just need to initialize it with download: true
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: repo,
                verbose: true,
                logLevel: .info,
                prewarm: false,
                load: false,
                download: true
            )
            
            // This will download the model
            _ = try await WhisperKit(config)
            
            await MainActor.run {
                self.downloadingModels.remove(modelName)
                self.downloadProgress[modelName] = 1.0
            }
            
            // Refresh downloaded models list
            loadDownloadedModels()
            
            logger.info("WhisperKit model downloaded: \(modelName)")
            
        } catch {
            logger.error("Failed to download model: \(error.localizedDescription)")
            await MainActor.run {
                self.downloadingModels.remove(modelName)
                self.downloadProgress.removeValue(forKey: modelName)
                self.errorMessage = "Failed to download \(modelName): \(error.localizedDescription)"
            }
            throw error
        }
        #else
        await MainActor.run {
            self.downloadingModels.remove(modelName)
            self.errorMessage = "WhisperKit is not available"
        }
        throw NSError(domain: "WhisperKitModelManager", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "WhisperKit is not available"])
        #endif
    }
    
    // MARK: - Model Deletion
    
    /// Delete a downloaded model
    func deleteModel(_ modelName: String) {
        #if canImport(WhisperKit)
        // Find the model folder in WhisperKit's default location
        let libraryPath = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let hubPath = libraryPath.appendingPathComponent("Caches/huggingface/hub")
        
        // WhisperKit stores models in a specific format
        // Try to find and delete the model folder
        if let contents = try? fileManager.contentsOfDirectory(at: hubPath, includingPropertiesForKeys: nil) {
            for folder in contents {
                if folder.lastPathComponent.contains(modelName.replacingOccurrences(of: "/", with: "--")) {
                    do {
                        try fileManager.removeItem(at: folder)
                        logger.info("Deleted model: \(modelName)")
                    } catch {
                        logger.error("Failed to delete model: \(error.localizedDescription)")
                        errorMessage = "Failed to delete \(modelName)"
                    }
                }
            }
        }
        
        // Also try the WhisperKit models directory
        let whisperKitPath = libraryPath.appendingPathComponent("Application Support/WhisperKit")
        if fileManager.fileExists(atPath: whisperKitPath.path) {
            if let contents = try? fileManager.contentsOfDirectory(at: whisperKitPath, includingPropertiesForKeys: nil) {
                for folder in contents {
                    if folder.lastPathComponent.contains(modelName) || folder.lastPathComponent == modelName {
                        do {
                            try fileManager.removeItem(at: folder)
                            logger.info("Deleted model from WhisperKit directory: \(modelName)")
                        } catch {
                            logger.error("Failed to delete model from WhisperKit: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        #endif
        
        // Refresh the list
        loadDownloadedModels()
    }
    
    // MARK: - Model Detection
    
    /// Load list of downloaded models
    func loadDownloadedModels() {
        var models: [WhisperKitModelInfo] = []
        
        #if canImport(WhisperKit)
        // Check WhisperKit's cache directories
        let libraryPath = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        
        // Check HuggingFace hub cache
        let hubPath = libraryPath.appendingPathComponent("Caches/huggingface/hub")
        if let contents = try? fileManager.contentsOfDirectory(at: hubPath, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) {
            for folder in contents {
                let name = folder.lastPathComponent
                // Check if it's a WhisperKit model
                if name.contains("whisperkit") || name.contains("whisper") {
                    let displayName = extractModelName(from: name)
                    let size = folderSize(at: folder)
                    
                    models.append(WhisperKitModelInfo(
                        name: displayName,
                        path: folder,
                        size: size,
                        isRecommended: displayName == recommendedModel
                    ))
                }
            }
        }
        
        // Check WhisperKit's Application Support directory
        let whisperKitPath = libraryPath.appendingPathComponent("Application Support/WhisperKit")
        if let contents = try? fileManager.contentsOfDirectory(at: whisperKitPath, includingPropertiesForKeys: [.fileSizeKey]) {
            for folder in contents {
                let name = folder.lastPathComponent
                // Skip if already added
                if !models.contains(where: { $0.name == name }) {
                    let size = folderSize(at: folder)
                    models.append(WhisperKitModelInfo(
                        name: name,
                        path: folder,
                        size: size,
                        isRecommended: name == recommendedModel
                    ))
                }
            }
        }
        #endif
        
        downloadedModels = models.sorted { $0.name < $1.name }
        logger.info("Found \(models.count) downloaded WhisperKit models")
    }
    
    // MARK: - Helpers
    
    private func extractModelName(from folderName: String) -> String {
        // Convert "models--argmaxinc--whisperkit-coreml" format to readable name
        var name = folderName
        name = name.replacingOccurrences(of: "models--", with: "")
        name = name.replacingOccurrences(of: "--", with: "/")
        return name
    }
    
    /// Format model name for display (e.g. "openai_whisper-tiny" -> "Tiny")
    func formatModelName(_ name: String) -> String {
        // Handle common prefixes
        var display = name.replacingOccurrences(of: "openai_whisper-", with: "")
        display = display.replacingOccurrences(of: "distil-whisper_", with: "")
        display = display.replacingOccurrences(of: "distil-", with: "")
        
        // Remove version/date suffixes if they make it too long
        // e.g. "large-v3-v20240930" -> "Large v3"
        if let range = display.range(of: "-v20") {
            display = String(display[..<range.lowerBound])
        }
        
        // Split by separators
        let parts = display.split(separator: "-")
        var formattedParts: [String] = []
        
        for part in parts {
            let p = String(part)
            // Capitalize known terms
            switch p.lowercased() {
            case "tiny", "base", "small", "medium", "large":
                formattedParts.append(p.capitalized)
            case "en":
                formattedParts.append("(English)")
            case "q5", "q8":
                formattedParts.append(p.uppercased()) // Quantization
            case "turbo":
                 formattedParts.append("Turbo")
            default:
                if p == "v1" || p == "v2" || p == "v3" {
                    formattedParts.append(p)
                } else {
                    formattedParts.append(p)
                }
            }
        }
        
        return formattedParts.joined(separator: " ")
    }
    
    private func folderSize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        
        return totalSize
    }
    
    /// Check if a model is downloaded
    func isModelDownloaded(_ modelName: String) -> Bool {
        return downloadedModels.contains { $0.name.contains(modelName) || modelName.contains($0.name) }
    }
}

// MARK: - Model Info

struct WhisperKitModelInfo: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: URL
    let size: Int64
    var isRecommended: Bool = false
    
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
