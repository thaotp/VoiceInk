import WebKit
import AppKit
import Combine

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
    
    // MARK: - Private Properties
    
    /// Hidden window hosting the webview - kept off-screen but active
    private var hiddenWindow: NSWindow!
    
    /// KVO observer for loading progress
    private var progressObserver: NSKeyValueObservation?
    
    /// KVO observer for URL changes
    private var urlObserver: NSKeyValueObservation?
    
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
