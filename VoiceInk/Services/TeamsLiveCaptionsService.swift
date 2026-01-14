import Foundation
import AppKit
import ApplicationServices
import Combine

/// Service to read Live Captions from Microsoft Teams using Accessibility API
/// Rebuilt with minimal architecture - simple Timer + DispatchQueue
@MainActor
final class TeamsLiveCaptionsService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isReading = false
    @Published private(set) var captionEntries: [CaptionEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var availableTeamsProcesses: [TeamsProcess] = []
    @Published var selectedProcessPID: pid_t?
    @Published var selectedWindowTitle: String?
    @Published private(set) var availableWindows: [WindowInfo] = []
    
    // MARK: - Types
    
    struct CaptionEntry: Equatable, Identifiable {
        let id = UUID()
        let speaker: String
        let text: String
        let timestamp = Date()
        var isPreExisting: Bool = false
        
        static func == (lhs: CaptionEntry, rhs: CaptionEntry) -> Bool {
            lhs.speaker == rhs.speaker && lhs.text == rhs.text
        }
    }
    
    struct TeamsProcess: Identifiable, Hashable {
        let pid: pid_t
        let name: String
        let windowTitle: String?
        var id: pid_t { pid }
        
        var displayName: String {
            if let title = windowTitle, !title.isEmpty {
                return "\(name) - \(title)"
            }
            return name
        }
    }
    
    struct WindowInfo: Identifiable, Hashable {
        let pid: pid_t
        let appName: String
        let windowTitle: String
        let bundleIdentifier: String?
        var id: String { "\(pid)-\(windowTitle)" }
        
        var displayName: String {
            if windowTitle != appName && !windowTitle.isEmpty {
                return "\(appName) - \(windowTitle)"
            }
            return appName
        }
        
        var isTeamsCaptionWindow: Bool {
            let lowercaseTitle = windowTitle.lowercased()
            return lowercaseTitle.contains("caption") ||
                   lowercaseTitle.contains("captions") ||
                   (bundleIdentifier?.contains("com.microsoft.teams") ?? false)
        }
    }
    
    // MARK: - Private Properties
    
    private var pollTimer: Timer?
    private let backgroundQueue = DispatchQueue(label: "teams.captions.poll", qos: .userInitiated)
    private var seenCaptionKeys: Set<String> = []
    private var liveCaptionsContainer: AXUIElement?
    private var appElement: AXUIElement?
    private var currentPID: pid_t?
    private var isFirstPoll = true
    
    // MARK: - Initialization
    
    init() {
        // Perform initial refresh on background
        backgroundQueue.async { [weak self] in
            self?.doRefreshTeamsProcesses()
        }
    }
    
    deinit {
        pollTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    
    static func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    func refreshTeamsProcesses() async {
        await withCheckedContinuation { continuation in
            backgroundQueue.async { [weak self] in
                self?.doRefreshTeamsProcesses()
                continuation.resume()
            }
        }
    }
    
    /// Start reading captions - Simple Timer-based approach
    func startReading() {
        guard Self.isAccessibilityEnabled() else {
            errorMessage = "Accessibility permission not granted."
            return
        }
        
        guard let pid = selectedProcessPID else {
            errorMessage = "No Teams process selected."
            return
        }
        
        // Stop any existing polling
        stopReading()
        
        // Reset state
        errorMessage = nil
        isReading = true
        captionEntries = []
        seenCaptionKeys = []
        isFirstPoll = true
        
        // Initialize AX elements
        currentPID = pid
        appElement = AXUIElementCreateApplication(pid)
        liveCaptionsContainer = nil
        
        // Start polling timer - fires every 500ms
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.backgroundQueue.async { [weak self] in
                self?.pollOnBackground()
            }
        }
    }
    
    func stopReading() {
        isReading = false
        pollTimer?.invalidate()
        pollTimer = nil
        captionEntries = []
        seenCaptionKeys = []
        liveCaptionsContainer = nil
        appElement = nil
        currentPID = nil
    }
    
    func clear() {
        stopReading()
    }
    
    // MARK: - Private Methods (Background)
    
    private func doRefreshTeamsProcesses() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        let processes = runningApps
            .filter { app in
                let bundleId = app.bundleIdentifier ?? ""
                let name = app.localizedName ?? ""
                return bundleId.contains("com.microsoft.teams") ||
                       name.lowercased().contains("microsoft teams")
            }
            .compactMap { app -> TeamsProcess? in
                let title = getWindowTitle(for: app.processIdentifier)
                return TeamsProcess(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? "Microsoft Teams",
                    windowTitle: title
                )
            }
        
        DispatchQueue.main.async { [weak self] in
            self?.availableTeamsProcesses = processes
            if processes.count == 1 && self?.selectedProcessPID == nil {
                self?.selectedProcessPID = processes.first?.pid
            }
        }
    }
    
    private func pollOnBackground() {
        guard let pid = currentPID, appElement != nil else { return }
        
        // Find captions container if not cached
        if liveCaptionsContainer == nil {
            liveCaptionsContainer = findCaptionsContainer(pid: pid)
        }
        
        guard let container = liveCaptionsContainer else { return }
        
        // Check if container is still valid
        if !isValidElement(container) {
            liveCaptionsContainer = nil
            return
        }
        
        // Extract captions
        let rawCaptions = extractCaptions(from: container)
        
        // Filter to only complete sentences and new ones
        let sentenceEndings: Set<Character> = ["。", ".", "!", "?", "！", "？", "…"]
        var newEntries: [CaptionEntry] = []
        
        for caption in rawCaptions {
            let text = caption.text
            guard !text.isEmpty,
                  let lastChar = text.last,
                  sentenceEndings.contains(lastChar) else {
                continue
            }
            
            let key = "\(caption.speaker):\(text)"
            if seenCaptionKeys.contains(key) { continue }
            seenCaptionKeys.insert(key)
            
            var entry = CaptionEntry(speaker: caption.speaker, text: text)
            if isFirstPoll {
                entry.isPreExisting = true
            }
            newEntries.append(entry)
        }
        
        isFirstPoll = false
        
        // Only update UI if we have new entries
        if !newEntries.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isReading else { return }
                self.captionEntries.append(contentsOf: newEntries)
            }
        }
    }
    
    // MARK: - AX Helpers (called on background queue)
    
    private func getWindowTitle(for pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let firstWindow = windows.first else {
            return nil
        }
        
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(firstWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return nil
        }
        return title
    }
    
    private func findCaptionsContainer(pid: pid_t) -> AXUIElement? {
        guard let app = appElement else { return nil }
        
        // Try targeted search first
        if let targetTitle = selectedWindowTitle {
            if let window = findWindowByTitle(app: app, title: targetTitle) {
                if let container = findElementByDescription(in: window, description: "Live Captions", maxDepth: 30) {
                    return container
                }
            }
        }
        
        // Fallback: search entire app
        return findElementByDescription(in: app, description: "Live Captions", maxDepth: 30)
    }
    
    private func findWindowByTitle(app: AXUIElement, title: String) -> AXUIElement? {
        var winVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winVal) == .success,
              let windows = winVal as? [AXUIElement] else {
            return nil
        }
        
        return windows.first { window in
            guard let t = getStringAttribute(window, kAXTitleAttribute) else { return false }
            return t == title || t.localizedCaseInsensitiveContains(title)
        }
    }
    
    private func findElementByDescription(in element: AXUIElement, description: String, maxDepth: Int, depth: Int = 0) -> AXUIElement? {
        if depth > maxDepth { return nil }
        
        // Check current element
        if matchesDescription(element, description: description) {
            return element
        }
        
        // Check children
        guard let children = getChildren(element) else { return nil }
        for child in children {
            if let found = findElementByDescription(in: child, description: description, maxDepth: maxDepth, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
    
    private func matchesDescription(_ element: AXUIElement, description: String) -> Bool {
        if let desc = getStringAttribute(element, kAXDescriptionAttribute),
           desc.localizedCaseInsensitiveContains(description) { return true }
        if let title = getStringAttribute(element, kAXTitleAttribute),
           title.localizedCaseInsensitiveContains(description) { return true }
        if let roleDesc = getStringAttribute(element, kAXRoleDescriptionAttribute),
           roleDesc.localizedCaseInsensitiveContains(description) { return true }
        return false
    }
    
    private func extractCaptions(from element: AXUIElement) -> [(speaker: String, text: String)] {
        let textElements = extractStaticTextElements(from: element, limit: 50)
        var captions: [(speaker: String, text: String)] = []
        var i = 0
        
        while i < textElements.count {
            let t1 = textElements[i]
            if t1.isEmpty { i += 1; continue }
            
            if i + 1 < textElements.count {
                let t2 = textElements[i+1]
                if !t2.isEmpty {
                    captions.append((speaker: t1, text: t2))
                    i += 2
                    continue
                }
            }
            captions.append((speaker: "Unknown", text: t1))
            i += 1
        }
        return captions
    }
    
    private func extractStaticTextElements(from element: AXUIElement, limit: Int) -> [String] {
        var texts: [String] = []
        extractTextsRecursive(element, texts: &texts, limit: limit, depth: 0, maxDepth: 20)
        return texts
    }
    
    private func extractTextsRecursive(_ element: AXUIElement, texts: inout [String], limit: Int, depth: Int, maxDepth: Int) {
        if texts.count >= limit || depth > maxDepth { return }
        
        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            texts.append(value)
        }
        
        guard let children = getChildren(element) else { return }
        for child in children {
            if texts.count >= limit { break }
            extractTextsRecursive(child, texts: &texts, limit: limit, depth: depth + 1, maxDepth: maxDepth)
        }
    }
    
    private func isValidElement(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success
    }
    
    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let str = value as? String else { return nil }
        return str
    }
    
    private func getChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children
    }
    
    func refreshAvailableWindows() {
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            var allWindows: [WindowInfo] = []
            let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            
            for app in runningApps {
                let pid = app.processIdentifier
                let appName = app.localizedName ?? "Unknown App"
                let appElement = AXUIElementCreateApplication(pid)
                
                var winVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winVal) == .success,
                   let realWindows = winVal as? [AXUIElement] {
                    
                    for window in realWindows {
                        let title = self.getStringAttribute(window, kAXTitleAttribute) ?? appName
                        let info = WindowInfo(
                            pid: pid,
                            appName: appName,
                            windowTitle: title,
                            bundleIdentifier: app.bundleIdentifier
                        )
                        allWindows.append(info)
                    }
                }
            }
            
            let sorted = allWindows.sorted { a, b in
                if a.isTeamsCaptionWindow != b.isTeamsCaptionWindow {
                    return a.isTeamsCaptionWindow
                }
                return a.displayName < b.displayName
            }
            
            DispatchQueue.main.async {
                self.availableWindows = sorted
            }
        }
    }
}
