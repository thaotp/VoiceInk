import Foundation
import AppKit
import ApplicationServices
import Combine

/// Service to read Live Captions from Microsoft Teams using Accessibility API
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
    
    private let axClient = TeamsAXClient()
    private var pollingTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private let pollInterval: Duration = .milliseconds(100)
    private var seenCaptionTexts: Set<String> = []
    
    // Combine
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        // Perform initial refresh asynchronously to avoid blocking init
        Task { await refreshTeamsProcesses() }
    }
    
    deinit {
        print("[TeamsLiveCaptions] Service Deinit")
    }
    
    // MARK: - Public Methods
    
    static func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
    
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    /// Debug logging helper - DISABLED for performance testing
    nonisolated private static func debugLog(_ message: String) {
        // Temporarily disabled to test if logging causes freeze
        // let threadName = Thread.isMainThread ? "Main" : "Bg"
        // print("[TeamsLiveCaptions] [\(threadName)] \(Date().timeIntervalSince1970) - \(message)")
    }
    
    /// Refresh the list of available Teams processes (Moved to Actor/Background to prevent UI Freeze)
    func refreshTeamsProcesses() async {
        Self.debugLog("refreshTeamsProcesses called")
        // Run this on a background thread to avoid blocking the Main Actor
        await Task.detached(priority: .userInitiated) {
            Self.debugLog("refreshTeamsProcesses running on background")
            let runningApps = NSWorkspace.shared.runningApplications
            
            let processes = runningApps
                .filter { app in
                    let bundleId = app.bundleIdentifier ?? ""
                    let name = app.localizedName ?? ""
                    return bundleId.contains("com.microsoft.teams") ||
                           name.lowercased().contains("microsoft teams")
                }
                .compactMap { app -> TeamsProcess? in
                    // AX calls can be slow, so we do minimal work here or ensure it's off main thread
                    // Since we are in detached task, blocking here won't freeze UI
                    let title = self.getWindowTitleSync(for: app.processIdentifier)
                    Self.debugLog("Checked window title for PID \(app.processIdentifier): \(title ?? "nil")")
                    return TeamsProcess(
                        pid: app.processIdentifier,
                        name: app.localizedName ?? "Microsoft Teams",
                        windowTitle: title
                    )
                }
            
            // Update UI on Main Actor
            await MainActor.run {
                self.availableTeamsProcesses = processes
                if processes.count == 1 && self.selectedProcessPID == nil {
                    self.selectedProcessPID = processes.first?.pid
                }
                print("[TeamsLiveCaptions] Found \(processes.count) Teams process(es)")
            }
        }.value
    }
    
    func refreshAvailableWindows() {
        Task {
            let windows = await axClient.getAllOpenWindows()
            self.availableWindows = windows
        }
    }
    
    /// Start reading captions
    func startReading() {
        Self.debugLog("startReading called for PID: \(String(describing: selectedProcessPID))")
        guard Self.isAccessibilityEnabled() else {
            errorMessage = "Accessibility permission not granted. Please enable in System Preferences."
            return
        }
        
        guard let pid = selectedProcessPID else {
            errorMessage = "No Teams process selected."
            return
        }
        
        // Note: We removed the synchronous guard check + refresh here to prevent freezing.
        // If the process is dead, the polling will fail gracefully or the user can manually refresh.
        
        errorMessage = nil
        isReading = true
        captionEntries = []
        seenCaptionTexts = []
        
        print("[TeamsLiveCaptions] Starting to read captions from PID: \(pid)")
        
        // Capture title for detached task
        let title = selectedWindowTitle
        
        // Start Heartbeat
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Self.debugLog("Main Thread Heartbeat - Alive")
        }
        
        pollingTask?.cancel()
        pollingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            Self.debugLog("Polling Task Launched")
            
            // Ensure clean state (Serialized inside the task)
            await self.axClient.reset(pid: pid, windowTitle: title)
            Self.debugLog("AXClient Reset Complete - Starting Loop")
            
            var isFirstPoll = true
            let sentenceEndings: Set<Character> = ["。", ".", "!", "?", "！", "？", "…"]
            
            Self.debugLog("Polling loop started")
            
            while !Task.isCancelled {
                let rawCaptions = await self.axClient.pollCaptions()
                
                // Do deduplication on background thread
                var newEntries: [CaptionEntry] = []
                for caption in rawCaptions {
                    let text = caption.text
                    guard !text.isEmpty,
                          let lastChar = text.last,
                          sentenceEndings.contains(lastChar) else {
                        continue
                    }
                    
                    // Check dedup on Actor (background)
                    let isNew = await self.axClient.checkAndMarkSeen(speaker: caption.speaker, text: text)
                    if isNew {
                        var entry = CaptionEntry(speaker: caption.speaker, text: text)
                        if isFirstPoll {
                            entry.isPreExisting = true
                        }
                        newEntries.append(entry)
                    }
                }
                
                // ONLY touch MainActor if we have NEW entries
                if !Task.isCancelled && !newEntries.isEmpty {
                    await MainActor.run {
                        guard self.isReading else { return }
                        self.captionEntries.append(contentsOf: newEntries)
                        Self.debugLog("Appended \(newEntries.count) new. Total: \(self.captionEntries.count)")
                    }
                }
                
                isFirstPoll = false
                try? await Task.sleep(nanoseconds: 500 * 1_000_000) // 500ms
            }
        }
    }
    
    func stopReading() {
        Self.debugLog("stopReading called - Full Cleanup Starting")
        
        // 1. Set flag first to stop new processing
        isReading = false
        
        // 2. Cancel polling task immediately
        pollingTask?.cancel()
        pollingTask = nil
        
        // 3. Stop heartbeat timer
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        // 4. Clear all data state
        captionEntries = []
        seenCaptionTexts = []
        
        // 5. Terminate AX client
        Task {
            await axClient.terminate()
            await MainActor.run {
                Self.debugLog("stopReading - Full Cleanup Complete")
            }
        }
    }
    
    func clear() {
        stopReading()
    }
    
    // MARK: - Private Methods
    
    // Renamed to getWindowTitleSync and made private to actor/background
    // This should only be called from a background context
    nonisolated private func getWindowTitleSync(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success,
              let windows = windowsValue as? [AXUIElement],
              let firstWindow = windows.first else {
            return nil
        }
        
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(firstWindow, kAXTitleAttribute as CFString, &titleValue)
        
        if titleResult == .success, let title = titleValue as? String {
            return title
        }
        
        return nil
    }
    
    private func processNewCaptions(_ captions: [(speaker: String, text: String)], isFirstPoll: Bool) {
        guard isReading else { return }
        guard !captions.isEmpty else { return }
        
        Self.debugLog("Processing \(captions.count) new captions")
        
        let sentenceEndings: Set<Character> = ["。", ".", "!", "?", "！", "？", "…"]
        var newEntries: [CaptionEntry] = []
        
        for caption in captions {
            let text = caption.text
            
            guard !text.isEmpty,
                  let lastChar = text.last,
                  sentenceEndings.contains(lastChar) else {
                continue
            }
            
            let key = "\(caption.speaker):\(text)"
            
            if seenCaptionTexts.contains(key) { continue }
            seenCaptionTexts.insert(key)
            
            var entry = CaptionEntry(
                speaker: caption.speaker,
                text: text,
                // timestamp: Date() // User code has `let timestamp = Date()` in struct definition defaulting to current date
            )
            
            if isFirstPoll {
                entry.isPreExisting = true
            }
            
            newEntries.append(entry)
        }
        
        if !newEntries.isEmpty {
            self.captionEntries.append(contentsOf: newEntries)
            Self.debugLog("Appended \(newEntries.count) new unique entries. Total: \(self.captionEntries.count)")
        } else {
             // Self.debugLog("Filtered \(captions.count) duplicates. No change.")
        }
    }
}

// MARK: - Background Actor

actor TeamsAXClient {
    private var liveCaptionsContainer: AXUIElement?
    private var appElement: AXUIElement?
    private var currentPID: pid_t?
    private var targetWindowTitle: String?
    private var seenCaptionKeys: Set<String> = []
    
    init() {
        print("[TeamsAXClient] Init")
    }
    
    func reset(pid: pid_t, windowTitle: String?) {
        print("[TeamsAXClient] Reset with PID: \(pid)")
        self.currentPID = pid
        self.targetWindowTitle = windowTitle
        self.liveCaptionsContainer = nil
        self.appElement = AXUIElementCreateApplication(pid)
        self.seenCaptionKeys = [] // Clear dedup cache on reset
    }
    
    func terminate() {
        print("[TeamsAXClient] Terminate")
        self.liveCaptionsContainer = nil
        self.appElement = nil
        self.currentPID = nil
        self.seenCaptionKeys = [] // Clear dedup cache
    }
    
    /// Check if this caption has been seen before. If new, mark as seen and return true.
    func checkAndMarkSeen(speaker: String, text: String) -> Bool {
        let key = "\(speaker):\(text)"
        if seenCaptionKeys.contains(key) {
            return false
        }
        seenCaptionKeys.insert(key)
        return true
    }
    
    func pollCaptions() -> [(speaker: String, text: String)] {
        let t0 = Date()
        defer {
            let dur = Date().timeIntervalSince(t0)
            if dur > 0.5 { print("[TeamsAXClient] SLOW Poll: \(String(format: "%.3f", dur))s") }
        }
        
        guard let pid = currentPID else { return [] }
        
        if liveCaptionsContainer == nil {
            // Check validity of app element first to avoid bad AX calls
            if self.appElement == nil || !isValid(self.appElement!) {
                self.appElement = AXUIElementCreateApplication(pid)
            }
            
            if let container = findCaptionsContainer(pid: pid) {
                liveCaptionsContainer = container
            } else {
                return []
            }
        }
        
        guard let container = liveCaptionsContainer else { return [] }
        
        if !isValid(container) {
            liveCaptionsContainer = nil
            return [] 
        }
        
        return extractCaptions(from: container)
    }
    
    private func isValid(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success
    }
    
    private func findCaptionsContainer(pid: pid_t) -> AXUIElement? {
        guard let app = appElement else { return nil }
        
        if let targetTitle = targetWindowTitle {
            if let window = findWindowByTitle(app: app, title: targetTitle) {
                if matchDescription(window, description: "Live Captions") {
                    return window
                }
                if let container = findElementByDescription(in: window, description: "Live Captions") {
                    return container
                }
            }
        }
        
        return findElementByDescription(in: app, description: "Live Captions")
    }
    
    private func findWindowByTitle(app: AXUIElement, title: String) -> AXUIElement? {
        var winVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winVal) == .success,
           let windows = winVal as? [AXUIElement] {
            if let match = windows.first(where: {
                guard let t = getStringAttribute($0, kAXTitleAttribute) else { return false }
                return t == title || t.localizedCaseInsensitiveContains(title)
            }) {
                return match
            }
        }
        return nil
    }
    
    private func findElementByDescription(in element: AXUIElement, description: String, depth: Int = 0) -> AXUIElement? {
        if depth > 50 { return nil }
        
        if matchDescription(element, description: description) {
            return element
        }
        
        guard let children = getChildren(element) else { return nil }
        for child in children {
            if let found = findElementByDescription(in: child, description: description, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
    
    private func matchDescription(_ element: AXUIElement, description: String) -> Bool {
        if let desc = getStringAttribute(element, kAXDescriptionAttribute), desc.localizedCaseInsensitiveContains(description) { return true }
        if let title = getStringAttribute(element, kAXTitleAttribute), title.localizedCaseInsensitiveContains(description) { return true }
        if let roleDesc = getStringAttribute(element, kAXRoleDescriptionAttribute), roleDesc.localizedCaseInsensitiveContains(description) { return true }
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
        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            texts.append(value)
        }
        
        if let children = getChildren(element) {
             var childrenToProcess = children
             if children.count > limit {
                 childrenToProcess = Array(children.suffix(limit))
             }
             
             for child in childrenToProcess {
                 if texts.count >= limit { break }
                 texts.append(contentsOf: extractStaticTextElementsRecursive(child, limit: limit, currentCount: texts.count))
             }
        }
        return texts
    }
    
    private func extractStaticTextElementsRecursive(_ element: AXUIElement, limit: Int, currentCount: Int) -> [String] {
        if currentCount >= limit { return [] }
        var texts: [String] = []
        var myCount = currentCount
        
        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            texts.append(value)
            myCount += 1
        }
        
        if myCount >= limit { return texts }
        
        if let children = getChildren(element) {
            for child in children {
                if myCount >= limit { break }
                let newTexts = extractStaticTextElementsRecursive(child, limit: limit, currentCount: myCount)
                texts.append(contentsOf: newTexts)
                myCount += newTexts.count
            }
        }
        return texts
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
    
    func getAllOpenWindows() -> [TeamsLiveCaptionsService.WindowInfo] {
        var allWindows: [TeamsLiveCaptionsService.WindowInfo] = []
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        
        for app in runningApps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "Unknown App"
            let appElement = AXUIElementCreateApplication(pid)
            
            var winVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winVal) == .success,
               let realWindows = winVal as? [AXUIElement] {
                
                for window in realWindows {
                    let title = getStringAttribute(window, kAXTitleAttribute) ?? appName
                    let info = TeamsLiveCaptionsService.WindowInfo(
                        pid: pid,
                        appName: appName,
                        windowTitle: title,
                        bundleIdentifier: app.bundleIdentifier
                    )
                    allWindows.append(info)
                }
            }
        }
        return allWindows.sorted { a, b in
            if a.isTeamsCaptionWindow != b.isTeamsCaptionWindow {
                return a.isTeamsCaptionWindow
            }
            return a.displayName < b.displayName
        }
    }
}
