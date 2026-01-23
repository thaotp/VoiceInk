import Foundation

/// A simple actor to ensure translation tasks are executed sequentially.
/// This prevents race conditions where multiple requests try to use the single browser input simultaneously.
actor TranslationQueue {
    static let shared = TranslationQueue()
    
    private var previousTask: Task<Void, Never>?
    
    /// Enqueue a translation operation to run sequentially.
    /// - Parameter operation: The async operation to perform.
    func enqueue(_ operation: @escaping () async -> Void) {
        let task = Task { [previousTask] in
            // Wait for the previous task to complete (ignore its result/cancellation)
            _ = await previousTask?.result
            await operation()
        }
        previousTask = task
    }
}
