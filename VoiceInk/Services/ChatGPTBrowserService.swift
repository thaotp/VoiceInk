import WebKit
import AppKit
import Combine

// MARK: - Streaming Response Protocol

/// Protocol for receiving real-time streaming responses from ChatGPT
protocol ChatGPTStreamingDelegate: AnyObject {
    /// Called when streaming text is updated (called frequently during generation)
    func chatGPTDidUpdateStreamingText(_ text: String)
    
    /// Called when streaming is complete
    func chatGPTDidFinishStreaming(finalText: String)
    
    /// Called when an error occurs during streaming
    func chatGPTStreamingDidFail(error: Error)
}

/// Background browser service for ChatGPT integration in Lyric Mode.
/// Uses WKWebView to load chatgpt.com in a hidden window (stealth mode).
/// Cookies and sessions persist via WKWebsiteDataStore for single sign-in.
@MainActor
class ChatGPTBrowserService: NSObject, ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = ChatGPTBrowserService()
    
    // MARK: - Public Properties
    
    /// The WKWebView instance - retained strongly to prevent deallocation
    private(set) var webView: WKWebView!
    
    /// Whether the browser window is currently visible
    @Published private(set) var isVisible: Bool = false
    
    /// Whether the ChatGPT page has finished loading
    @Published private(set) var isLoaded: Bool = false
    
    /// Current URL of the webview
    @Published private(set) var currentURL: URL?
    
    /// Loading progress (0.0 - 1.0)
    @Published private(set) var loadingProgress: Double = 0.0
    
    /// Whether user appears to be logged in (based on URL patterns)
    @Published private(set) var isLoggedIn: Bool = false
    
    /// Current streaming response text (updated in real-time)
    @Published private(set) var streamingText: String = ""
    
    /// Whether a response is currently being streamed
    @Published private(set) var isStreaming: Bool = false
    
    /// Publisher for streaming text updates
    var streamingTextPublisher: AnyPublisher<String, Never> {
        $streamingText.eraseToAnyPublisher()
    }
    
    /// Delegate for receiving streaming updates
    weak var streamingDelegate: ChatGPTStreamingDelegate?
    
    /// Whether the service is currently processing a message
    @Published private(set) var isBusy: Bool = false
    
    /// Last message sent (to detect duplicates)
    private var lastMessageSent: String = ""
    
    /// Message counter to make each message unique
    private var messageCounter: Int = 0
    
    // MARK: - Private Properties
    
    /// Hidden window hosting the webview - kept off-screen but active
    private var hiddenWindow: NSWindow!
    
    /// KVO observer for loading progress
    private var progressObserver: NSKeyValueObservation?
    
    /// KVO observer for URL changes
    private var urlObserver: NSKeyValueObservation?
    
    /// Script message handler name for streaming responses (DOM-based)
    private let streamingMessageHandlerName = "chatGPTStreaming"
    
    /// Script message handler name for fetch interceptor (Network-based)
    private let fetchInterceptorHandlerName = "chatGPTFetchInterceptor"
    
    /// Track the last known response text to detect changes
    private var lastKnownResponseText: String = ""
    
    // interceptedSSEData was deprecated in favor of JS-side parsing
    // @Published private(set) var interceptedSSEData: [String] = []
    
    /// Number of active fetch interceptor streams (can be >1 for concurrent requests)
    private var activeStreamCount: Int = 0
    
    /// Whether fetch interceptor has any active streams
    @Published private(set) var isInterceptorActive: Bool = false
    
    /// The ID of the last request sent by the app
    private var lastRequestId: String?
    
    /// The ID of the request currently being streamed/intercepted
    private var streamingRequestId: String?
    
    // MARK: - Constants
    
    private let chatGPTURL = URL(string: "https://chatgpt.com")!
    private let windowSize = NSSize(width: 1200, height: 800)
    private let offScreenPosition = NSPoint(x: -3000, y: -3000)
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        setupBrowser()
    }
    
    deinit {
        progressObserver?.invalidate()
        urlObserver?.invalidate()
    }
    
    // MARK: - Setup
    
    private func setupBrowser() {
        // Create configuration with persistent cookie storage
        let configuration = WKWebViewConfiguration()
        
        // Use default (non-ephemeral) data store for cookie/session persistence
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        
        // Enable JavaScript
        let preferences = WKPreferences()
        configuration.preferences = preferences
        
        // Add script message handlers
        let contentController = configuration.userContentController
        
        // DOM-based streaming handler (legacy/backup)
        contentController.add(StreamingMessageHandler(service: self), name: streamingMessageHandlerName)
        
        // Fetch interceptor handler (Network-based, primary)
        contentController.add(FetchInterceptorMessageHandler(service: self), name: fetchInterceptorHandlerName)
        
        // Inject fetch interceptor script at document start
        let fetchInterceptorScript = WKUserScript(
            source: createFetchInterceptorJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false  // Inject in all frames in case ChatGPT uses iframes
        )
        contentController.addUserScript(fetchInterceptorScript)
        
        // Create the webview with specified frame
        let frame = CGRect(origin: .zero, size: windowSize)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        // Allow inspection in Safari dev tools (useful for debugging)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        // Setup KVO observers
        setupObservers()
        
        // Create hidden window
        setupHiddenWindow()
        
        // Load ChatGPT
        loadChatGPT()
        
        print("[ChatGPTBrowser] Service initialized, loading ChatGPT...")
    }
    
    private func setupHiddenWindow() {
        // Create window positioned off-screen
        let contentRect = NSRect(origin: offScreenPosition, size: windowSize)
        
        hiddenWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        // Configure window properties
        hiddenWindow.title = "ChatGPT Browser"
        hiddenWindow.contentView = webView
        hiddenWindow.isReleasedWhenClosed = false  // Keep window alive when closed
        hiddenWindow.delegate = self
        
        // Prevent window from appearing in Mission Control or Cycle Windows
        hiddenWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        
        // Initial state: Stealth Mode
        hiddenWindow.alphaValue = 0.0
        hiddenWindow.ignoresMouseEvents = true
        hiddenWindow.makeKeyAndOrderFront(nil) // Keep it "visible" to system
    }
    
    private func setupObservers() {
        // Observe loading progress
        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.loadingProgress = webView.estimatedProgress
            }
        }
        
        // Observe URL changes
        urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.currentURL = webView.url
                self?.checkLoginStatus()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Load or reload the ChatGPT page
    func loadChatGPT() {
        let request = URLRequest(url: chatGPTURL)
        webView.load(request)
        isLoaded = false
        print("[ChatGPTBrowser] Loading \(chatGPTURL.absoluteString)")
    }
    
    /// Toggle visibility of the browser window
    /// - Parameter show: true to show the window for login/CAPTCHA, false to hide
    func toggleVisibility(show: Bool) {
        isVisible = show
        
        if show {
            // Center the window on screen and bring to front
            hiddenWindow.alphaValue = 1.0
            hiddenWindow.ignoresMouseEvents = false
            hiddenWindow.center()
            hiddenWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            print("[ChatGPTBrowser] Window shown for user interaction")
        } else {
            // "Stealth Mode": Keep window "visible" to system but invisible to user
            // This prevents WebKit from suspending the process/JS execution
            hiddenWindow.alphaValue = 0.0
            hiddenWindow.ignoresMouseEvents = true
            hiddenWindow.setFrameOrigin(offScreenPosition)
            // Do NOT call orderOut(nil) as it causes process suspension
            // hiddenWindow.orderBack(nil) // Optional: move to back
            print("[ChatGPTBrowser] Window entered stealth mode (alpha 0, off-screen)")
        }
    }
    
    /// Show the browser window (convenience method)
    func show() {
        toggleVisibility(show: true)
    }
    
    /// Hide the browser window (convenience method)
    func hide() {
        toggleVisibility(show: false)
    }
    
    // MARK: - Streaming State (Network Interceptor based)
    
    /// Check if ChatGPT is currently streaming a response
    /// Uses the fetch interceptor's activeStreamCount for reliable detection
    var isStreamingActive: Bool {
        return activeStreamCount > 0 || isInterceptorActive
    }
    
    /// Wait for any active streaming to finish before proceeding
    /// - Parameter timeout: Maximum wait time in seconds
    /// - Returns: true if streaming finished, false if timed out
    func waitForStreamingToFinish(timeout: TimeInterval = 30) async -> Bool {
        let startTime = Date()
        
        while isStreamingActive {
            if Date().timeIntervalSince(startTime) > timeout {
                print("[ChatGPTBrowser] Timeout waiting for streaming to finish")
                return false
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        return true
    }
    
    /// Reload the current page
    func reload() {
        webView.reload()
    }
    
    /// Clear all website data (cookies, cache, etc.) - for logout
    func clearWebsiteData() async {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: date)
        isLoggedIn = false
        print("[ChatGPTBrowser] Website data cleared")
        
        // Reload ChatGPT after clearing
        loadChatGPT()
    }
    
    // MARK: - Session Management
    
    /// Start a new chat session in ChatGPT
    /// Call this at the beginning of each Lyric Mode recording session
    /// to ensure all translations go to the same chat
    func startNewChatSession() async {
        guard isLoggedIn else {
            print("[ChatGPTBrowser] Cannot start new chat: not logged in")
            return
        }
        
        print("[ChatGPTBrowser] Starting new chat session...")
        
        // JavaScript to click the "New Chat" button or navigate to root
        let javascript = """
        (function() {
            // Try to find and click the "New Chat" button
            const newChatSelectors = [
                'a[href="/"]',
                'button[aria-label*="New chat"]',
                'button[aria-label*="new chat"]',
                '[data-testid="create-new-chat-button"]',
                'nav a[href="/"]',
                // Sidebar new chat button
                'button svg[class*="icon"]',
                'a[class*="new-chat"]'
            ];
            
            for (const selector of newChatSelectors) {
                const el = document.querySelector(selector);
                if (el && (el.tagName === 'A' || el.tagName === 'BUTTON')) {
                    el.click();
                    console.log('[ChatGPT] Clicked new chat button:', selector);
                    return "clicked";
                }
            }
            
            // Fallback: navigate directly to homepage for new chat
            if (window.location.pathname !== '/') {
                window.location.href = 'https://chatgpt.com/';
                return "navigated";
            }
            
            return "already_on_new_chat";
        })();
        """
        
        do {
            let result = try await webView.callAsyncJavaScript(
                javascript,
                arguments: [:],
                contentWorld: .page
            )
            print("[ChatGPTBrowser] New chat session result: \(result ?? "nil")")
            
            // Wait for the page to settle
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
        } catch {
            print("[ChatGPTBrowser] Error starting new chat: \(error.localizedDescription)")
            // Fallback: reload the main page
            loadChatGPT()
        }
    }
    
    // MARK: - Private Methods
    
    private func checkLoginStatus() {
        guard let url = currentURL else {
            isLoggedIn = false
            return
        }
        
        // Check URL patterns to determine login status
        // ChatGPT redirects to /auth/login when not logged in
        let urlString = url.absoluteString
        let isOnLoginPage = urlString.contains("/auth/") || urlString.contains("/login")
        
        // If we're on the main chat page, user is likely logged in
        isLoggedIn = !isOnLoginPage && (urlString.contains("chatgpt.com") || urlString.contains("chat.openai.com"))
        
        print("[ChatGPTBrowser] Login status: \(isLoggedIn ? "logged in" : "not logged in"), URL: \(urlString)")
    }
    
    // MARK: - Streaming Response Observer
    
    /// Start observing the chat container for streaming responses
    /// Call this after sending a message to capture the real-time response
    func startStreamingObserver() async {
        isStreaming = true
        streamingText = ""
        lastKnownResponseText = ""
        
        let javascript = createStreamingObserverJavaScript()
        
        do {
            try await webView.evaluateJavaScript(javascript)
            print("[ChatGPTBrowser] Streaming observer started")
        } catch {
            print("[ChatGPTBrowser] Failed to start streaming observer: \(error.localizedDescription)")
            streamingDelegate?.chatGPTStreamingDidFail(error: error)
        }
    }
    
    /// Stop the streaming observer
    func stopStreamingObserver() async {
        let javascript = """
        (function() {
            if (window.chatGPTStreamingObserver) {
                window.chatGPTStreamingObserver.disconnect();
                window.chatGPTStreamingObserver = null;
            }
            if (window.chatGPTStreamingInterval) {
                clearInterval(window.chatGPTStreamingInterval);
                window.chatGPTStreamingInterval = null;
            }
            return "stopped";
        })();
        """
        
        do {
            try await webView.evaluateJavaScript(javascript)
            print("[ChatGPTBrowser] Streaming observer stopped")
        } catch {
            print("[ChatGPTBrowser] Error stopping observer: \(error.localizedDescription)")
        }
        
        isStreaming = false
        isBusy = false  // Allow next message
    }
    
    /// Handle streaming message received from JavaScript
    func handleStreamingMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        
        switch type {
        case "update":
            if let text = message["text"] as? String {
                // Only update if text actually changed
                if text != lastKnownResponseText {
                    lastKnownResponseText = text
                    streamingText = text
                    streamingDelegate?.chatGPTDidUpdateStreamingText(text)
                }
            }
            
        case "complete":
            isStreaming = false
            isBusy = false  // Ready for next message
            if let text = message["text"] as? String {
                streamingText = text
                streamingDelegate?.chatGPTDidFinishStreaming(finalText: text)
            }
            print("[ChatGPTBrowser] Streaming complete")
            
        case "error":
            isStreaming = false
            isBusy = false  // Ready for next message
            let errorMessage = message["message"] as? String ?? "Unknown error"
            print("[ChatGPTBrowser] Streaming error: \(errorMessage)")
            
        default:
            break
        }
    }
    
    /// Creates JavaScript for MutationObserver to watch chat responses in real-time
    private func createStreamingObserverJavaScript() -> String {
        return """
        (function() {
            // Clean up any existing observer
            if (window.chatGPTStreamingObserver) {
                window.chatGPTStreamingObserver.disconnect();
            }
            if (window.chatGPTStreamingInterval) {
                clearInterval(window.chatGPTStreamingInterval);
            }
            
            // Selectors for ChatGPT's response elements
            const responseSelectors = [
                '[data-message-author-role="assistant"]',
                '.markdown.prose',
                '[class*="agent-turn"]',
                '.result-streaming'
            ];
            
            // Find the last assistant message container
            function findLastResponseElement() {
                for (const selector of responseSelectors) {
                    const elements = document.querySelectorAll(selector);
                    if (elements.length > 0) {
                        return elements[elements.length - 1];
                    }
                }
                return null;
            }
            
            // Get text content safely
            function getResponseText(element) {
                if (!element) return '';
                return element.innerText || element.textContent || '';
            }
            
            // Track the response element and its state
            let lastText = '';
            let noChangeCount = 0;
            let responseElement = null;
            
            // Send update to Swift
            function sendUpdate(text, isComplete = false) {
                const message = {
                    type: isComplete ? 'complete' : 'update',
                    text: text,
                    timestamp: Date.now()
                };
                window.webkit.messageHandlers.chatGPTStreaming.postMessage(message);
            }
            
            // Check for streaming indicators (stop button, loading states)
            function isStillStreaming() {
                const stopButton = document.querySelector('button[aria-label*="Stop"]');
                const streamingClass = document.querySelector('[class*="result-streaming"]');
                const thinkingIndicator = document.querySelector('[class*="thinking"]');
                return !!(stopButton || streamingClass || thinkingIndicator);
            }
            
            // MutationObserver callback
            function handleMutation(mutations) {
                const element = findLastResponseElement();
                if (!element) return;
                
                const currentText = getResponseText(element);
                
                // Only send if text changed
                if (currentText !== lastText && currentText.length > 0) {
                    lastText = currentText;
                    noChangeCount = 0;
                    sendUpdate(currentText, false);
                }
            }
            
            // Create observer for the entire chat container
            function startObserving() {
                const chatContainer = document.querySelector('main') || 
                                     document.querySelector('[class*="conversation"]') ||
                                     document.body;
                
                window.chatGPTStreamingObserver = new MutationObserver(handleMutation);
                
                window.chatGPTStreamingObserver.observe(chatContainer, {
                    childList: true,
                    subtree: true,
                    characterData: true,
                    characterDataOldValue: false
                });
                
                // Also use polling as backup (MutationObserver may miss some updates)
                window.chatGPTStreamingInterval = setInterval(() => {
                    const element = findLastResponseElement();
                    if (!element) return;
                    
                    const currentText = getResponseText(element);
                    
                    if (currentText !== lastText && currentText.length > 0) {
                        lastText = currentText;
                        noChangeCount = 0;
                        sendUpdate(currentText, false);
                    } else if (currentText.length > 0) {
                        noChangeCount++;
                        
                        // If no changes for 2 seconds and streaming stopped, consider complete
                        if (noChangeCount >= 20 && !isStillStreaming()) {
                            clearInterval(window.chatGPTStreamingInterval);
                            window.chatGPTStreamingObserver.disconnect();
                            sendUpdate(currentText, true);
                        }
                    }
                }, 100); // Check every 100ms
            }
            
            // Start observing
            startObserving();
            
            return "observer_started";
        })();
        """
    }
    
    // MARK: - Fetch Interceptor (Network-based API Interception)
    
    /// Creates JavaScript that monkey patches window.fetch to intercept ChatGPT API responses.
    /// Uses async/await and ensures original fetch continues even if interception fails.
    private func createFetchInterceptorJavaScript() -> String {
        return """
        (function() {
            'use strict';
            
            // Prevent multiple injections
            if (window.__voiceInkFetchInterceptorInstalled) {
                console.log('[VoiceInk Interceptor] Already installed, skipping.');
                return;
            }
            window.__voiceInkFetchInterceptorInstalled = true;
            
            // Store original fetch
            const originalFetch = window.fetch;
            
            // Send message to Swift
            function sendToSwift(type, data) {
                try {
                    window.webkit.messageHandlers.chatGPTFetchInterceptor.postMessage({
                        type: type,
                        data: data,
                        timestamp: Date.now()
                    });
                } catch (e) {
                    // Silently fail if message handler not available
                }
            }
            
            // Check if this is a ChatGPT conversation API request
            function isConversationRequest(url) {
                if (!url) return false;
                const urlString = typeof url === 'string' ? url : url.toString();
                
                // Must be a backend API conversation related endpoint
                if (!urlString.includes('/backend-api/') && !urlString.includes('/backend-anon/')) {
                    return false;
                }
                
                // Exclude common non-generation endpoints by name
                if (urlString.includes('/conversations')) return false; // Plural: chat history list
                if (urlString.includes('/init')) return false;          // Session init
                if (urlString.includes('/prepare')) return false;       // Pre-generation setup
                if (urlString.includes('/stream_status')) return false; // Status checks
                if (urlString.includes('/textdocs')) return false;      // Document/citation handling
                if (urlString.includes('/presign')) return false;       // File upload presigning
                
                // Must be a target generation endpoint
                // Common patterns:
                // - /backend-api/conversation (Standard)
                // - /backend-api/f/conversation (Newer standard)
                // - /backend-api/lat/r (Thinking models / reasoning)
                return urlString.includes('/conversation') || urlString.includes('/lat/r');
            }
            
            // Monkey patch fetch
            window.fetch = async function(resource, options) {
                const url = typeof resource === 'string' ? resource : resource?.url;
                
                // Log for debugging
                // sendToSwift('debug', { message: 'Fetch request: ' + url });
                
                // If not a conversation request, just call original fetch
                if (!isConversationRequest(url)) {
                    return originalFetch.apply(this, arguments);
                }
                
                console.log('[VoiceInk Interceptor] Intercepting request:', url);
                
                // Extract prompt from request body if available
                let prompt = null;
                if (options && options.body) {
                    try {
                        const body = JSON.parse(options.body);
                        if (body.messages && Array.isArray(body.messages) && body.messages.length > 0) {
                            const lastMessage = body.messages[body.messages.length - 1];
                            if (lastMessage.content && lastMessage.content.parts && lastMessage.content.parts.length > 0) {
                                prompt = lastMessage.content.parts[0];
                            }
                        }
                    } catch (e) {
                        // Ignore body parsing errors
                    }
                }
                
                sendToSwift('request_start', { url: url, prompt: prompt });
                
                let response;
                try {
                    response = await originalFetch.apply(this, arguments);
                } catch (fetchError) {
                    sendToSwift('error', { phase: 'fetch', message: fetchError.message });
                    throw fetchError;
                }
                
                if (!response.ok || !response.body) {
                    return response;
                }
                
                const clonedResponse = response.clone();
                
                // Read and parse stream in background
                (async () => {
                    try {
                        const reader = clonedResponse.body.getReader();
                        const decoder = new TextDecoder('utf-8');
                        let buffer = '';
                        
                        while (true) {
                            const { done, value } = await reader.read();
                            
                            if (done) {
                                sendToSwift('stream_end', null);
                                break;
                            }
                            
                            // Decode chunk and append to buffer
                            buffer += decoder.decode(value, { stream: true });
                            
                            // Process valid lines
                            const lines = buffer.split('\\n');
                            // Keep the last partial line in the buffer
                            buffer = lines.pop();
                            
                            for (const line of lines) {
                                if (line.trim() === '' || line === 'data: [DONE]') continue;
                                if (!line.startsWith('data: ')) continue;
                                
                                const jsonStr = line.substring(6); // remove 'data: '
                                try {
                                    const json = JSON.parse(jsonStr);
                                    
                                    // Extract text content
                                    // Path: message.content.parts[0]
                                    if (json.message && json.message.content && json.message.content.parts) {
                                        const text = json.message.content.parts[0];
                                        if (text) {
                                            sendToSwift('text_update', { text: text });
                                        }
                                    } else if (json.v) {
                                        // Handle 'lat/r' or other formats if they contain text
                                        // This handles the "v": "..." diff format if used
                                        sendToSwift('text_append', { text: json.v });
                                    }
                                } catch (e) {
                                    // Ignore parse errors for intermediate chunks
                                }
                            }
                        }
                    } catch (streamError) {
                        sendToSwift('error', { phase: 'stream', message: streamError.message });
                    }
                })();
                
                return response;
            };
            
            console.log('[VoiceInk Interceptor] Installed successfully');
            sendToSwift('installed', null);
        })();
        """
    }
    
    // MARK: - Fetch Interceptor Data Handling
    
    /// Handle messages from the fetch interceptor JavaScript
    func handleFetchInterceptorMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        
        switch type {
        case "installed":
            print("[ChatGPTBrowser] Fetch interceptor installed")
            
        case "request_start":
            if let data = message["data"] as? [String: Any], let url = data["url"] as? String {
                print("[ChatGPTBrowser] Intercepting request: \(url)")
                
                // Verify prompt correlation
                if let prompt = data["prompt"] as? String {
                    // Extract Request ID from prompt
                    // Format: ...[Ref: UUID]
                    // We look for just "[Ref: " to be robust against newline normalization
                    var extractedId: String? = nil
                    if let range = prompt.range(of: "[Ref: ", options: .backwards),
                       let endRange = prompt.range(of: "]", options: .backwards, range: range.upperBound..<prompt.endIndex) {
                        extractedId = String(prompt[range.upperBound..<endRange.lowerBound])
                        print("[ChatGPTBrowser] Extracted Request ID: \(extractedId ?? "nil")")
                    }
                    
                    if let id = extractedId {
                        self.streamingRequestId = id
                        // We trust the ID if it's present.
                        // Removing strict check against lastRequestId allows handling queued/lagging requests.
                        // The UI layer uses getLastResponse(forRequestId:) to filter for the one it wants.
                    } else {
                        print("[ChatGPTBrowser] WARNING: Could not extract ID from prompt. Prompt end: \(prompt.suffix(50))")
                        
                        // Fallback logic
                        // If we can't find an ID, we assume it's a generic request (or maybe we failed to tag it).
                        // We set generic active state. Strict waiters will timeout (safely), generic waiters will get text.
                        self.streamingRequestId = nil
                        
                        // Optional: Legacy text check only for logging
                        let cleanLastMsg = lastMessageSent.components(separatedBy: "\n\n[Ref:").first ?? lastMessageSent
                        if !cleanLastMsg.isEmpty && !prompt.contains(cleanLastMsg.prefix(30)) {
                             print("[ChatGPTBrowser] WARNING: Prompt content also mismatches last sent message.")
                        }
                    }
                }
            }
            
            isInterceptorActive = true
            activeStreamCount += 1
            
            // Only clear previous state if this is the FIRST stream for a new request
            // (Don't clear when second stream /lat/r starts while /f/conversation is active)
            if activeStreamCount == 1 {
                lastKnownResponseText = ""
            }
            
        case "text_update":
            guard isInterceptorActive else { return }
            if let data = message["data"] as? [String: Any], let text = data["text"] as? String {
                if text != lastKnownResponseText {
                    lastKnownResponseText = text
                    streamingText = text
                    streamingDelegate?.chatGPTDidUpdateStreamingText(text)
                }
            }
            
        case "text_append":
            guard isInterceptorActive else { return }
            if let data = message["data"] as? [String: Any], let text = data["text"] as? String {
                let newText = (lastKnownResponseText + text).trimmingCharacters(in: .whitespacesAndNewlines)
                if newText != lastKnownResponseText {
                    lastKnownResponseText = newText
                    streamingText = newText
                    streamingDelegate?.chatGPTDidUpdateStreamingText(newText)
                }
            }
            
        case "stream_end":
            activeStreamCount = max(0, activeStreamCount - 1)
            print("[ChatGPTBrowser] Stream ended. Final text length: \(streamingText.count). Active streams remaining: \(activeStreamCount)")
            
            // Only finalize when ALL streams have ended
            if activeStreamCount == 0 {
                isInterceptorActive = false
                finalizeInterceptedResponse()
            }
            
        case "error":
            if let data = message["data"] as? [String: Any] {
                let phase = data["phase"] as? String ?? "unknown"
                let errorMessage = data["message"] as? String ?? "Unknown error"
                print("[ChatGPTBrowser] Interceptor error (\(phase)): \(errorMessage)")
            }
            
        case "debug":
            if let data = message["data"] as? [String: Any], let msg = data["message"] as? String {
                print("[ChatGPTBrowser] Interceptor Debug: \(msg)")
            }
            
        default:
            break
        }
    }
    
    /// Finalize the response after stream ends
    private func finalizeInterceptedResponse() {
        if !streamingText.isEmpty {
            isStreaming = false
            isBusy = false
            streamingDelegate?.chatGPTDidFinishStreaming(finalText: streamingText)
            print("[ChatGPTBrowser] Finalized response: \(streamingText.prefix(100))...")
        }
    }
    
    /// Clear accumulated SSE data
    func clearInterceptedData() {
        // interceptedSSEData = [] // Deprecated
        lastKnownResponseText = ""
        streamingRequestId = nil
        activeStreamCount = 0
        isInterceptorActive = false
    }

    // MARK: - Message Sending (React/SPA Compatible)
    
    /// Configurable selectors for ChatGPT UI elements
    /// These can be updated if ChatGPT changes their HTML structure
    struct Selectors {
        /// Selector for the message input textarea
        static var inputBox = "#prompt-textarea"
        
        /// Selector for the send button
        static var sendButton = "button[data-testid='send-button']"
        
        /// Alternative selectors to try if primary ones fail
        static var inputBoxFallbacks = [
            "#prompt-textarea",
            "textarea[placeholder*='Message']",
            "textarea[placeholder*='Send']",
            "div[contenteditable='true'][data-placeholder]",
            "div[contenteditable='true']",
            "[id*='prompt'][contenteditable='true']",
            "form textarea"
        ]
        
        static var sendButtonFallbacks = [
            "button[data-testid='send-button']",
            "button[aria-label*='Send']",
            "button[aria-label*='send']",
            "button[class*='send']",
            "button svg[class*='send']",
            // Common SVG-based send button patterns
            "form button:not([aria-label*='Voice'])",
            "button[class*='absolute'][class*='right']",
            // The button near the textarea
            "#prompt-textarea ~ button",
            "#prompt-textarea + button",
            // Any button in the form that's not disabled
            "form button:not(:disabled)",
            // Fallback: any round/action button near bottom
            "button[class*='rounded-full']",
            "button[class*='circle']"
        ]
    }
    
    /// Result of a message send operation
    enum SendMessageResult {
        case success
        case notLoggedIn
        case inputNotFound
        case sendButtonNotFound
        case sendButtonDisabled
        case error(String)
    }
    
    /// Send a message to ChatGPT
    /// - Parameter text: The message text to send
    /// - Returns: Tuple containing Result and optional Request ID
    func sendMessage(_ text: String) async -> (SendMessageResult, String?) {
        guard isLoggedIn else {
            print("[ChatGPTBrowser] Cannot send message: not logged in")
            return (.notLoggedIn, nil)
        }
        
        guard isLoaded else {
            print("[ChatGPTBrowser] Cannot send message: page not loaded")
            return (.error("Page not loaded"), nil)
        }
        
        // Wait for any active streaming to finish before sending new message
        // Uses network interceptor (activeStreamCount) for reliable detection
        if isStreamingActive {
            print("[ChatGPTBrowser] ChatGPT is busy streaming, waiting for it to finish...")
            let finished = await waitForStreamingToFinish(timeout: 30)
            if !finished {
                print("[ChatGPTBrowser] Timeout waiting for previous stream to finish")
                // Continue anyway - the previous stream might be stuck
            } else {
                print("[ChatGPTBrowser] Previous stream finished, proceeding with new message")
            }
        }
        
        // Generate unique Request ID
        let requestId = UUID().uuidString
        let messageWithId = text + "\n\n[Ref: \(requestId)]"
        
        lastMessageSent = text // Store original text for reference
        lastRequestId = requestId
        streamingRequestId = nil // Reset streaming ID
        
        // Clear streaming text for new response
        streamingText = ""
        lastKnownResponseText = ""
        
        print("[ChatGPTBrowser] Sending message with ID: \(requestId)")
        
        // JavaScript that simulates natural typing for React apps
        let javascript = createTypingJavaScript(for: messageWithId)
        
        do {
            // Use callAsyncJavaScript which properly handlesPromises
            let result = try await webView.callAsyncJavaScript(
                javascript,
                arguments: [:],
                contentWorld: .page
            )
            
            if let resultString = result as? String {
                switch resultString {
                case "success":
                    print("[ChatGPTBrowser] Message sent successfully")
                    return (.success, requestId)
                case "input_not_found":
                    print("[ChatGPTBrowser] Input element not found")
                    return (.inputNotFound, nil)
                case "button_not_found":
                    print("[ChatGPTBrowser] Send button not found")
                    return (.sendButtonNotFound, nil)
                case "button_disabled":
                    print("[ChatGPTBrowser] Send button is disabled")
                    return (.sendButtonDisabled, nil)
                default:
                    print("[ChatGPTBrowser] Unexpected result: \(resultString)")
                    return (.error(resultString), nil)
                }
            }
            
            // If result is nil or not a string, assume success (Enter key fallback)
            print("[ChatGPTBrowser] Message sent (likely via Enter key)")
            return (.success, requestId)
        } catch {
            print("[ChatGPTBrowser] JavaScript error: \(error.localizedDescription)")
            return (.error(error.localizedDescription), nil)
        }
    }
    
    /// Creates JavaScript code that uses React Fiber/Props manipulation to send messages
    /// This is more reliable than DOM event simulation which React may not detect
    /// - Parameter text: The text to send
    /// - Returns: JavaScript code as string
    private func createTypingJavaScript(for text: String) -> String {
        // Escape the text for JavaScript string
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        
        let inputFallbacks = Selectors.inputBoxFallbacks.map { "\"\($0)\"" }.joined(separator: ", ")
        
        return """
        (function() {
            'use strict';
            
            const text = "\(escapedText)";
            
            // ============================================================
            // REACT FIBER/PROPS MANIPULATION
            // Instead of simulating DOM events, we directly access React's
            // internal state and handlers through the Fiber tree
            // ============================================================
            
            /**
             * Find React internal key on a DOM element
             * React attaches internal properties with keys like:
             * - __reactFiber$... (React 18+)
             * - __reactInternalInstance$... (React 16-17)
             * - __reactProps$... (Props including event handlers)
             */
            function getReactKey(element, prefix) {
                const keys = Object.keys(element);
                for (const key of keys) {
                    if (key.startsWith(prefix)) {
                        return key;
                    }
                }
                return null;
            }
            
            /**
             * Get React Fiber node from a DOM element
             */
            function getReactFiber(element) {
                // Try React 18+ fiber key
                let key = getReactKey(element, '__reactFiber$');
                if (key) return element[key];
                
                // Try React 16-17 internal instance
                key = getReactKey(element, '__reactInternalInstance$');
                if (key) return element[key];
                
                return null;
            }
            
            /**
             * Get React Props from a DOM element
             * This contains event handlers like onChange, onKeyDown, etc.
             */
            function getReactProps(element) {
                const key = getReactKey(element, '__reactProps$');
                if (key) return element[key];
                
                // Fallback: try to get props from fiber
                const fiber = getReactFiber(element);
                if (fiber && fiber.memoizedProps) {
                    return fiber.memoizedProps;
                }
                
                return null;
            }
            
            /**
             * Traverse up the Fiber tree to find a handler
             */
            function findHandlerInFiberTree(fiber, handlerName, maxDepth = 15) {
                let current = fiber;
                let depth = 0;
                
                while (current && depth < maxDepth) {
                    // Check memoizedProps
                    if (current.memoizedProps && typeof current.memoizedProps[handlerName] === 'function') {
                        return current.memoizedProps[handlerName];
                    }
                    
                    // Check pendingProps
                    if (current.pendingProps && typeof current.pendingProps[handlerName] === 'function') {
                        return current.pendingProps[handlerName];
                    }
                    
                    // Check stateNode props
                    if (current.stateNode && current.stateNode.props) {
                        if (typeof current.stateNode.props[handlerName] === 'function') {
                            return current.stateNode.props[handlerName];
                        }
                    }
                    
                    // Move up the tree
                    current = current.return;
                    depth++;
                }
                
                return null;
            }
            
            /**
             * Find element using selectors
             */
            function findElement(selectors) {
                for (const selector of selectors) {
                    const el = document.querySelector(selector);
                    if (el) return el;
                }
                return null;
            }
            
            /**
             * Find send button - explicitly excludes stop button via JS attribute check
             */
            function findSendButton() {
                // First try the specific send button selector
                const sendBtn = document.querySelector("button[data-testid='send-button']");
                if (sendBtn) return sendBtn;
                
                // Try other selectors, but filter out stop button
                const candidates = document.querySelectorAll("button[aria-label*='Send'], button[aria-label*='send'], form button:not(:disabled)");
                for (const btn of candidates) {
                    // Explicitly exclude stop button by checking data-testid
                    if (btn.getAttribute('data-testid') === 'stop-button') {
                        continue;
                    }
                    return btn;
                }
                return null;
            }
            
            /**
             * Create a synthetic React event object
             * React expects events with specific structure
             */
            function createSyntheticEvent(element, eventType, value) {
                return {
                    target: {
                        value: value,
                        name: element.name || '',
                        type: element.type || 'textarea',
                        tagName: element.tagName,
                        id: element.id,
                        getAttribute: (attr) => element.getAttribute(attr)
                    },
                    currentTarget: element,
                    type: eventType,
                    bubbles: true,
                    cancelable: true,
                    defaultPrevented: false,
                    eventPhase: 2,
                    isTrusted: true,
                    nativeEvent: new Event(eventType, { bubbles: true }),
                    preventDefault: function() { this.defaultPrevented = true; },
                    stopPropagation: function() {},
                    persist: function() {},
                    isPersistent: function() { return true; }
                };
            }
            
            /**
             * Create a synthetic keyboard event for Enter key submission
             */
            function createSyntheticKeyboardEvent(element, key, keyCode) {
                return {
                    target: element,
                    currentTarget: element,
                    key: key,
                    code: key,
                    keyCode: keyCode,
                    which: keyCode,
                    charCode: keyCode,
                    shiftKey: false,
                    ctrlKey: false,
                    altKey: false,
                    metaKey: false,
                    repeat: false,
                    type: 'keydown',
                    bubbles: true,
                    cancelable: true,
                    defaultPrevented: false,
                    eventPhase: 2,
                    isTrusted: true,
                    nativeEvent: new KeyboardEvent('keydown', { key, keyCode, bubbles: true }),
                    preventDefault: function() { this.defaultPrevented = true; },
                    stopPropagation: function() {},
                    persist: function() {},
                    isPersistent: function() { return true; }
                };
            }
            
            /**
             * Update React state via onChange handler
             */
            function updateReactState(element, value) {
                const props = getReactProps(element);
                const fiber = getReactFiber(element);
                
                // Method 1: Direct props onChange
                if (props && typeof props.onChange === 'function') {
                    console.log('[ChatGPT-React] Found onChange in direct props');
                    const event = createSyntheticEvent(element, 'change', value);
                    props.onChange(event);
                    return true;
                }
                
                // Method 2: Search in Fiber tree
                if (fiber) {
                    const onChangeHandler = findHandlerInFiberTree(fiber, 'onChange');
                    if (onChangeHandler) {
                        console.log('[ChatGPT-React] Found onChange in Fiber tree');
                        const event = createSyntheticEvent(element, 'change', value);
                        onChangeHandler(event);
                        return true;
                    }
                    
                    // Try onInput as alternative
                    const onInputHandler = findHandlerInFiberTree(fiber, 'onInput');
                    if (onInputHandler) {
                        console.log('[ChatGPT-React] Found onInput in Fiber tree');
                        const event = createSyntheticEvent(element, 'input', value);
                        onInputHandler(event);
                        return true;
                    }
                }
                
                return false;
            }
            
            /**
             * Trigger form submission via React handlers
             */
            function triggerReactSubmit(textareaElement, buttonElement) {
                // Method 1: Try Enter key handler on textarea
                const textareaProps = getReactProps(textareaElement);
                const textareaFiber = getReactFiber(textareaElement);
                
                // Check for onKeyDown handler (ChatGPT uses this for Enter submission)
                let keyDownHandler = textareaProps && textareaProps.onKeyDown ? textareaProps.onKeyDown : null;
                if (!keyDownHandler && textareaFiber) {
                    keyDownHandler = findHandlerInFiberTree(textareaFiber, 'onKeyDown');
                }
                
                if (keyDownHandler) {
                    console.log('[ChatGPT-React] Found onKeyDown handler, simulating Enter');
                    const enterEvent = createSyntheticKeyboardEvent(textareaElement, 'Enter', 13);
                    keyDownHandler(enterEvent);
                    
                    // If defaultPrevented wasn't called, submission likely triggered
                    if (!enterEvent.defaultPrevented) {
                        return true;
                    }
                    console.log('[ChatGPT-React] Enter was prevented, trying button click');
                }
                
                // Method 2: Try button onClick handler
                if (buttonElement) {
                    const buttonProps = getReactProps(buttonElement);
                    const buttonFiber = getReactFiber(buttonElement);
                    
                    let clickHandler = buttonProps && buttonProps.onClick ? buttonProps.onClick : null;
                    if (!clickHandler && buttonFiber) {
                        clickHandler = findHandlerInFiberTree(buttonFiber, 'onClick');
                    }
                    
                    if (clickHandler) {
                        console.log('[ChatGPT-React] Found onClick handler on button');
                        const clickEvent = {
                            target: buttonElement,
                            currentTarget: buttonElement,
                            type: 'click',
                            bubbles: true,
                            cancelable: true,
                            defaultPrevented: false,
                            button: 0,
                            buttons: 1,
                            clientX: 0,
                            clientY: 0,
                            nativeEvent: new MouseEvent('click', { bubbles: true }),
                            preventDefault: function() { this.defaultPrevented = true; },
                            stopPropagation: function() {},
                            persist: function() {}
                        };
                        clickHandler(clickEvent);
                        return true;
                    }
                    
                    // Method 3: Native button click as final fallback
                    if (!buttonElement.disabled) {
                        console.log('[ChatGPT-React] Using native button click');
                        buttonElement.click();
                        return true;
                    }
                }
                
                // Method 4: Find form and submit
                const form = textareaElement.closest('form');
                if (form) {
                    const formProps = getReactProps(form);
                    const formFiber = getReactFiber(form);
                    
                    let submitHandler = formProps && formProps.onSubmit ? formProps.onSubmit : null;
                    if (!submitHandler && formFiber) {
                        submitHandler = findHandlerInFiberTree(formFiber, 'onSubmit');
                    }
                    
                    if (submitHandler) {
                        console.log('[ChatGPT-React] Found form onSubmit handler');
                        const submitEvent = {
                            target: form,
                            currentTarget: form,
                            type: 'submit',
                            bubbles: true,
                            cancelable: true,
                            defaultPrevented: false,
                            nativeEvent: new Event('submit', { bubbles: true }),
                            preventDefault: function() { this.defaultPrevented = true; },
                            stopPropagation: function() {},
                            persist: function() {}
                        };
                        submitHandler(submitEvent);
                        return true;
                    }
                }
                
                return false;
            }
            
            /**
             * Fallback: DOM event simulation for contenteditable (ProseMirror)
             */
            function fallbackProseMirrorSimulation(element, value, buttonElement) {
                console.log('[ChatGPT-React] Using ProseMirror/contenteditable fallback');
                
                // Focus the element
                element.focus();
                
                // Clear existing content
                element.innerHTML = '';
                
                // For ProseMirror, we need to create a paragraph structure
                const p = document.createElement('p');
                p.textContent = value;
                element.appendChild(p);
                
                // Move cursor to end
                const range = document.createRange();
                const sel = window.getSelection();
                range.selectNodeContents(element);
                range.collapse(false);
                sel.removeAllRanges();
                sel.addRange(range);
                
                // Dispatch input event to notify ProseMirror of changes
                element.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: value
                }));
                
                // Also dispatch a generic input event
                element.dispatchEvent(new Event('input', { bubbles: true }));
                
                // Wait for ProseMirror to sync, then click button
                return new Promise((resolve) => {
                    const checkAndSubmit = (attempts) => {
                        if (buttonElement) {
                            // Re-query button in case it was replaced
                            const btn = document.querySelector("button[data-testid='send-button']") ||
                                        document.querySelector("button[aria-label*='Send']") ||
                                        buttonElement;
                            
                            if (btn && !btn.disabled) {
                                console.log('[ChatGPT-React] Clicking send button');
                                btn.click();
                                resolve('success');
                                return;
                            }
                        }
                        
                        if (attempts < 60) { // Try for 3 seconds
                            setTimeout(() => checkAndSubmit(attempts + 1), 50);
                        } else {
                            // Try Enter key as last resort
                            console.log('[ChatGPT-React] Button still disabled, trying Enter key');
                            element.dispatchEvent(new KeyboardEvent('keydown', {
                                key: 'Enter',
                                code: 'Enter',
                                keyCode: 13,
                                which: 13,
                                bubbles: true,
                                cancelable: true
                            }));
                            resolve('success');
                        }
                    };
                    
                    // Start checking after a short delay for ProseMirror to process
                    setTimeout(() => checkAndSubmit(0), 100);
                });
            }
            
            /**
             * Try to find React internals on parent elements (for ProseMirror wrappers)
             */
            function findReactInternalsInParents(element, maxDepth) {
                let current = element;
                let depth = 0;
                
                while (current && depth < maxDepth) {
                    const fiber = getReactFiber(current);
                    const props = getReactProps(current);
                    
                    if (fiber || props) {
                        return { element: current, fiber: fiber, props: props };
                    }
                    
                    current = current.parentElement;
                    depth++;
                }
                
                return null;
            }
            
            // ============================================================
            // MAIN EXECUTION
            // ============================================================
            
            const inputSelectors = [\(inputFallbacks)];
            const textarea = findElement(inputSelectors);
            
            if (!textarea) {
                console.error('[ChatGPT-React] Textarea not found with selectors:', inputSelectors);
                return "input_not_found";
            }
            
            console.log('[ChatGPT-React] Found textarea:', textarea);
            
            // Check if this is a contenteditable (ProseMirror) element
            const isContentEditable = textarea.getAttribute('contenteditable') === 'true';
            console.log('[ChatGPT-React] Is contenteditable:', isContentEditable);
            
            // Focus the textarea first
            textarea.focus();
            
            // Find send button early - ALL selectors must exclude stop button
            const buttonSelectors = [
                "button[data-testid='send-button']",
                "button[aria-label*='Send']:not([data-testid='stop-button'])",
                "button[aria-label*='send']:not([data-testid='stop-button'])",
                "form button:not(:disabled):not([data-testid='stop-button'])"
            ];
            
            // Try to find React internals on the element or its parents
            let reactData = null;
            const directFiber = getReactFiber(textarea);
            const directProps = getReactProps(textarea);
            
            if (directFiber || directProps) {
                reactData = { element: textarea, fiber: directFiber, props: directProps };
            } else {
                // Search parent elements (ProseMirror wraps the actual React component)
                reactData = findReactInternalsInParents(textarea, 10);
            }
            
            if (reactData) {
                console.log('[ChatGPT-React] Found React internals on:', reactData.element);
                
                // Try to update state via React
                const stateUpdated = updateReactState(reactData.element, text);
                
                if (stateUpdated) {
                    console.log('[ChatGPT-React] React state updated successfully');
                } else if (isContentEditable) {
                    // For contenteditable, directly set content
                    textarea.innerHTML = '';
                    const p = document.createElement('p');
                    p.textContent = text;
                    textarea.appendChild(p);
                    textarea.dispatchEvent(new Event('input', { bubbles: true }));
                }
            } else if (isContentEditable) {
                // Pure ProseMirror fallback - set content directly
                console.log('[ChatGPT-React] Using pure ProseMirror approach');
                
                textarea.innerHTML = '';
                const p = document.createElement('p');
                p.textContent = text;
                textarea.appendChild(p);
                
                // Set cursor to end
                const range = document.createRange();
                const sel = window.getSelection();
                range.selectNodeContents(textarea);
                range.collapse(false);
                sel.removeAllRanges();
                sel.addRange(range);
                
                // Trigger input event
                textarea.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: text
                }));
            } else {
                // Regular textarea fallback
                console.warn('[ChatGPT-React] No React internals found, using legacy fallback');
                const propDesc = Object.getOwnPropertyDescriptor(
                    window.HTMLTextAreaElement.prototype, 'value'
                );
                const nativeSetter = propDesc ? propDesc.set : null;
                
                if (nativeSetter) {
                    nativeSetter.call(textarea, text);
                } else {
                    textarea.value = text;
                }
                textarea.dispatchEvent(new Event('input', { bubbles: true }));
            }
            
            // Wait for UI to update, then submit
            return new Promise((resolve, reject) => {
                const checkButton = (attempts) => {
                    try {
                        // Safety Check: If Stop button exists, we are definitely busy. Wait.
                        const stopButton = document.querySelector('button[data-testid="stop-button"]');
                        if (stopButton) {
                            console.log('[ChatGPT-React] Stop button found, waiting for generation to finish...');
                            // Check again in 500ms
                            setTimeout(() => checkButton(attempts), 500); 
                            return;
                        }

                        const sendButton = findSendButton();
                        
                        if (sendButton && !sendButton.disabled) {
                            console.log('[ChatGPT-React] Send button enabled, clicking');
                            
                            // Try React onClick first
                            const btnProps = getReactProps(sendButton);
                            const btnFiber = getReactFiber(sendButton);
                            let clickHandler = btnProps && btnProps.onClick ? btnProps.onClick : null;
                            if (!clickHandler && btnFiber) {
                                clickHandler = findHandlerInFiberTree(btnFiber, 'onClick');
                            }
                            
                            if (clickHandler) {
                                console.log('[ChatGPT-React] Using React onClick handler');
                                const clickEvent = {
                                    target: sendButton,
                                    currentTarget: sendButton,
                                    type: 'click',
                                    bubbles: true,
                                    cancelable: true,
                                    defaultPrevented: false,
                                    button: 0,
                                    preventDefault: function() { this.defaultPrevented = true; },
                                    stopPropagation: function() {},
                                    persist: function() {}
                                };
                                clickHandler(clickEvent);
                            } else {
                                // Native click
                                sendButton.click();
                            }
                            
                            resolve("success");
                            return;
                        }
                        
                        // Simple short retry just to find the button if it hasn't rendered yet
                        if (attempts < 20) { // Try for 1 second (50ms * 20)
                            setTimeout(() => checkButton(attempts + 1), 50);
                        } else {
                            // Timeout - try Enter key as last resort
                            console.log('[ChatGPT-React] Button not enabled after 1s, trying Enter key');
                            
                            textarea.focus();
                            textarea.dispatchEvent(new KeyboardEvent('keydown', {
                                key: 'Enter',
                                code: 'Enter',
                                keyCode: 13,
                                which: 13,
                                bubbles: true,
                                cancelable: true
                            }));
                            
                            resolve("success");
                        }
                    } catch (error) {
                         console.error('[ChatGPT-React] Error in checkButton:', error);
                         reject(error.toString());
                    }
                };
                
                // Start checking after a short delay
                try {
                    setTimeout(() => checkButton(0), 100);
                } catch (error) {
                    reject(error.toString());
                }
            });
        })();
        """
    }
    
    /// Check if a response is currently being generated
    func isGeneratingResponse() async -> Bool {
        let javascript = """
        (function() {
            // Look for stop button or loading indicators
            const stopButton = document.querySelector('button[aria-label*="Stop"]');
            const loadingIndicator = document.querySelector('[class*="loading"]');
            const streamingText = document.querySelector('[class*="streaming"]');
            
            return !!(stopButton || loadingIndicator || streamingText);
        })();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(javascript)
            return result as? Bool ?? false
        } catch {
            return false
        }
    }
    
    /// Get the last response from ChatGPT
    /// - Parameter requestId: Optional Request ID to enforce strict matching
    func getLastResponse(forRequestId requestId: String? = nil) async -> String? {
        // If Request ID is provided, enforce strict matching with streaming content
        if let targetId = requestId {
            if let currentId = streamingRequestId, currentId == targetId {
                 // IDs match, return the streaming text
                 return !streamingText.isEmpty ? streamingText : nil
            } else if streamingRequestId == nil {
                // Wait... no stream active yet
                return nil
            } else {
                // Mismatch (streaming a different request)
                return nil
            }
        }
        
        // Legacy/Fallback behavior: Prefer intercepted streaming text if available
        if !streamingText.isEmpty {
            return streamingText
        }
        
        let javascript = """
        (function() {
            // Helper to get text content efficiently
            function getText(el) {
                if (!el) return '';
                // Prefer textContent to capture text even if element is hidden/fading in (opacity: 0)
                return el.textContent || el.innerText || '';
            }
            
            console.log('[ChatGPT] Getting last response...');
            
            // Try multiple selectors for assistant messages
            const selectors = [
                // New "result-thinking" class seen in recent UI
                '.result-thinking',
                
                // Prioritize content-rich elements
                '[data-message-author-role="assistant"] .markdown',
                '[data-message-author-role="assistant"] .prose',
                '[data-message-author-role="assistant"] p',
                
                // Message container fallback
                '[data-message-author-role="assistant"]',
                
                // Alternative patterns
                '[class*="agent-turn"] .markdown',
                'div[data-message-id] .markdown'
            ];
            
            for (const selector of selectors) {
                const messages = document.querySelectorAll(selector);
                if (messages.length > 0) {
                    // Get the last message
                    const lastMessage = messages[messages.length - 1];
                    let text = getText(lastMessage).trim();
                    
                    if (text.length > 0) {
                        // Minimal filtering in JS - let Swift handle the logic
                        if (/^(ChatGPT|You|User|Assistant):?$/i.test(text)) continue;
                        
                        console.log('[ChatGPT] Found response (' + text.length + ' chars)');
                        return text;
                    }
                }
            }
            
            // Fallback: look for generic prose/response containers
            const proseElements = document.querySelectorAll('.prose, .markdown');
            if (proseElements.length > 0) {
                const lastProse = proseElements[proseElements.length - 1];
                let text = getText(lastProse).trim();
                
                // Ensure it's not the input prompt (simple heuristic)
                if (text.length > 0 && !text.includes('Translate the following')) {
                    return text;
                }
            }
            
            return null;
        })();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(javascript)
            if let text = result as? String, !text.isEmpty {
                // print("[ChatGPTBrowser] Got response: \(text.prefix(50))...") // Reduce noise
                return text
            }
            return nil
        } catch {
            print("[ChatGPTBrowser] Error getting response: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - WKNavigationDelegate

extension ChatGPTBrowserService: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("[ChatGPTBrowser] Started loading...")
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        currentURL = webView.url
        checkLoginStatus()
        print("[ChatGPTBrowser] Finished loading: \(webView.url?.absoluteString ?? "unknown")")
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[ChatGPTBrowser] Navigation failed: \(error.localizedDescription)")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[ChatGPTBrowser] Provisional navigation failed: \(error.localizedDescription)")
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow all navigation within ChatGPT/OpenAI domains
        if let url = navigationAction.request.url {
            let host = url.host ?? ""
            if host.contains("chatgpt.com") || host.contains("openai.com") || host.contains("auth0.com") {
                decisionHandler(.allow)
                return
            }
            
            // For other domains (e.g., OAuth providers), also allow
            decisionHandler(.allow)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - WKUIDelegate

extension ChatGPTBrowserService: WKUIDelegate {
    
    // Handle JavaScript alerts
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "ChatGPT"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }
    
    // Handle JavaScript confirms
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "ChatGPT"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        completionHandler(result == .alertFirstButtonReturn)
    }
    
    // Handle new window requests (open in same webview)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Load the request in the same webview instead of opening a new window
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - NSWindowDelegate

extension ChatGPTBrowserService: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        // When user closes the window manually, just hide it instead
        if isVisible {
            toggleVisibility(show: false)
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        isVisible = true
    }
}

// MARK: - WKScriptMessageHandler for Streaming Responses

/// Handler for receiving streaming messages from JavaScript
/// Uses a separate class to avoid retain cycles with WKUserContentController
class StreamingMessageHandler: NSObject, WKScriptMessageHandler {
    
    /// Weak reference to the browser service
    private weak var service: ChatGPTBrowserService?
    
    init(service: ChatGPTBrowserService) {
        self.service = service
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Ensure we're on the main thread
        Task { @MainActor in
            guard let messageBody = message.body as? [String: Any] else {
                print("[ChatGPTBrowser] Invalid message format received")
                return
            }
            
            self.service?.handleStreamingMessage(messageBody)
        }
    }
}

// MARK: - WKScriptMessageHandler for Fetch Interceptor

/// Handler for receiving fetch-intercepted SSE chunks from JavaScript
/// Uses a separate class to avoid retain cycles with WKUserContentController
class FetchInterceptorMessageHandler: NSObject, WKScriptMessageHandler {
    
    /// Weak reference to the browser service
    private weak var service: ChatGPTBrowserService?
    
    init(service: ChatGPTBrowserService) {
        self.service = service
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Ensure we're on the main thread
        Task { @MainActor in
            guard let messageBody = message.body as? [String: Any] else {
                print("[ChatGPTBrowser] Invalid fetch interceptor message format")
                return
            }
            
            self.service?.handleFetchInterceptorMessage(messageBody)
        }
    }
}
