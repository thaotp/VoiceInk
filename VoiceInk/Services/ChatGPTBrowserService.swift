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
    
    // MARK: - Private Properties
    
    /// Hidden window hosting the webview - kept off-screen but active
    private var hiddenWindow: NSWindow!
    
    /// KVO observer for loading progress
    private var progressObserver: NSKeyValueObservation?
    
    /// KVO observer for URL changes
    private var urlObserver: NSKeyValueObservation?
    
    /// Script message handler name for streaming responses
    private let streamingMessageHandlerName = "chatGPTStreaming"
    
    /// Track the last known response text to detect changes
    private var lastKnownResponseText: String = ""
    
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
        
        // Add script message handler for streaming responses
        let contentController = configuration.userContentController
        contentController.add(StreamingMessageHandler(service: self), name: streamingMessageHandlerName)
        
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
        
        // Keep it hidden but not deallocated
        hiddenWindow.orderOut(nil)
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
            hiddenWindow.center()
            hiddenWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            print("[ChatGPTBrowser] Window shown for user interaction")
        } else {
            // Move off-screen and hide
            hiddenWindow.setFrameOrigin(offScreenPosition)
            hiddenWindow.orderOut(nil)
            print("[ChatGPTBrowser] Window hidden (stealth mode)")
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
            if let text = message["text"] as? String {
                streamingText = text
                streamingDelegate?.chatGPTDidFinishStreaming(finalText: text)
            }
            print("[ChatGPTBrowser] Streaming complete")
            
        case "error":
            isStreaming = false
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
    /// - Returns: Result indicating success or failure reason
    func sendMessage(_ text: String) async -> SendMessageResult {
        guard isLoggedIn else {
            print("[ChatGPTBrowser] Cannot send message: not logged in")
            return .notLoggedIn
        }
        
        guard isLoaded else {
            print("[ChatGPTBrowser] Cannot send message: page not loaded")
            return .error("Page not loaded")
        }
        
        print("[ChatGPTBrowser] Sending message: \(text.prefix(50))...")
        
        // JavaScript that simulates natural typing for React apps
        let javascript = createTypingJavaScript(for: text)
        
        do {
            // Use callAsyncJavaScript which properly handles Promises
            let result = try await webView.callAsyncJavaScript(
                javascript,
                arguments: [:],
                contentWorld: .page
            )
            
            if let resultString = result as? String {
                switch resultString {
                case "success":
                    print("[ChatGPTBrowser] Message sent successfully")
                    return .success
                case "input_not_found":
                    print("[ChatGPTBrowser] Input element not found")
                    return .inputNotFound
                case "button_not_found":
                    print("[ChatGPTBrowser] Send button not found")
                    return .sendButtonNotFound
                case "button_disabled":
                    print("[ChatGPTBrowser] Send button is disabled")
                    return .sendButtonDisabled
                default:
                    print("[ChatGPTBrowser] Unexpected result: \(resultString)")
                    return .error(resultString)
                }
            }
            
            // If result is nil or not a string, assume success (Enter key fallback)
            print("[ChatGPTBrowser] Message sent (likely via Enter key)")
            return .success
        } catch {
            print("[ChatGPTBrowser] JavaScript error: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }
    
    /// Creates JavaScript code that simulates natural typing for React applications
    /// - Parameter text: The text to type
    /// - Returns: JavaScript code as string
    private func createTypingJavaScript(for text: String) -> String {
        // Escape the text for JavaScript string
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        
        let inputSelector = Selectors.inputBox
        let buttonSelector = Selectors.sendButton
        let inputFallbacks = Selectors.inputBoxFallbacks.map { "\"\($0)\"" }.joined(separator: ", ")
        let buttonFallbacks = Selectors.sendButtonFallbacks.map { "\"\($0)\"" }.joined(separator: ", ")
        
        return """
        (function() {
            const text = "\(escapedText)";
            
            // Helper: Find element using primary selector or fallbacks
            function findElement(primary, fallbacks) {
                let el = document.querySelector(primary);
                if (el) return el;
                
                for (const selector of fallbacks) {
                    el = document.querySelector(selector);
                    if (el) return el;
                }
                return null;
            }
            
            // Helper: Simulate natural typing events for React
            function simulateTyping(element, text) {
                // Focus the element
                element.focus();
                
                // For contenteditable divs (ProseMirror, etc.)
                if (element.getAttribute('contenteditable') === 'true') {
                    // Clear existing content
                    element.innerHTML = '';
                    
                    // Create a text node
                    const textNode = document.createTextNode(text);
                    element.appendChild(textNode);
                    
                    // Dispatch input event
                    element.dispatchEvent(new InputEvent('input', {
                        bubbles: true,
                        cancelable: true,
                        inputType: 'insertText',
                        data: text
                    }));
                    
                    return;
                }
                
                // For textarea/input elements (React-controlled)
                // We need to use native setter to trigger React's synthetic events
                const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                    window.HTMLTextAreaElement.prototype, 'value'
                )?.set || Object.getOwnPropertyDescriptor(
                    window.HTMLInputElement.prototype, 'value'
                )?.set;
                
                if (nativeInputValueSetter) {
                    nativeInputValueSetter.call(element, text);
                } else {
                    element.value = text;
                }
                
                // Dispatch events in the order React expects
                element.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                element.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                
                // Also dispatch a more specific InputEvent
                element.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: text
                }));
            }
            
            // Helper: Wait for button to become enabled
            function waitForButtonEnabled(button, maxWaitMs = 2000) {
                return new Promise((resolve) => {
                    const startTime = Date.now();
                    
                    function check() {
                        if (!button.disabled && !button.getAttribute('aria-disabled')) {
                            resolve(true);
                            return;
                        }
                        
                        if (Date.now() - startTime > maxWaitMs) {
                            resolve(false);
                            return;
                        }
                        
                        setTimeout(check, 50);
                    }
                    
                    check();
                });
            }
            
            // Helper: Submit using keyboard Enter key
            function submitWithEnterKey(element) {
                // Dispatch keydown event for Enter
                const enterEvent = new KeyboardEvent('keydown', {
                    key: 'Enter',
                    code: 'Enter',
                    keyCode: 13,
                    which: 13,
                    bubbles: true,
                    cancelable: true
                });
                element.dispatchEvent(enterEvent);
                
                // Also try keypress and keyup
                element.dispatchEvent(new KeyboardEvent('keypress', {
                    key: 'Enter',
                    code: 'Enter',
                    keyCode: 13,
                    which: 13,
                    bubbles: true
                }));
                element.dispatchEvent(new KeyboardEvent('keyup', {
                    key: 'Enter',
                    code: 'Enter',
                    keyCode: 13,
                    which: 13,
                    bubbles: true
                }));
            }
            
            // Find input element
            const inputSelectors = [\(inputFallbacks)];
            const input = findElement("\(inputSelector)", inputSelectors);
            
            if (!input) {
                console.log('[ChatGPT] Input not found with selectors:', inputSelectors);
                return "input_not_found";
            }
            
            console.log('[ChatGPT] Found input element:', input);
            
            // Simulate typing
            simulateTyping(input, text);
            
            // Find send button
            const buttonSelectors = [\(buttonFallbacks)];
            const sendButton = findElement("\(buttonSelector)", buttonSelectors);
            
            // Wait a moment for React to process the input
            return new Promise((resolve) => {
                setTimeout(async () => {
                    if (sendButton) {
                        console.log('[ChatGPT] Found send button:', sendButton);
                        // Check if button is enabled
                        const isEnabled = await waitForButtonEnabled(sendButton);
                        
                        if (isEnabled) {
                            // Click the send button
                            sendButton.click();
                            
                            // Also try dispatching click events
                            sendButton.dispatchEvent(new MouseEvent('click', {
                                bubbles: true,
                                cancelable: true,
                                view: window
                            }));
                            
                            resolve("success");
                            return;
                        }
                        console.log('[ChatGPT] Button found but disabled, trying Enter key');
                    } else {
                        console.log('[ChatGPT] Send button not found, trying Enter key fallback');
                    }
                    
                    // Fallback: Try submitting with Enter key
                    submitWithEnterKey(input);
                    
                    // Wait a bit and check if submission happened
                    setTimeout(() => {
                        resolve("success");
                    }, 200);
                }, 100);
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
    func getLastResponse() async -> String? {
        let javascript = """
        (function() {
            // Find all assistant messages
            const messages = document.querySelectorAll('[data-message-author-role="assistant"]');
            if (messages.length === 0) {
                // Try alternative selector
                const altMessages = document.querySelectorAll('.markdown.prose');
                if (altMessages.length > 0) {
                    return altMessages[altMessages.length - 1].innerText;
                }
                return null;
            }
            
            // Get the last assistant message
            const lastMessage = messages[messages.length - 1];
            return lastMessage.innerText || lastMessage.textContent;
        })();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(javascript)
            return result as? String
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
