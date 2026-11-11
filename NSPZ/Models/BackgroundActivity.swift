import BackgroundTasks
import UIKit

/// Hält die App während einer Konvertierung am Leben – auch wenn sie in den Hintergrund geht.
/// Nutzt `BGContinuedProcessingTask` (iOS 26, mit System-Fortschrittsanzeige) und zusätzlich
/// klassische Hintergrundzeit als Fallback.
final class BackgroundActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var finished = false
    private var fraction: Double = 0
    private var lastSubtitleUpdate = Date.distantPast
    private let title: String
    private let onExpire: @Sendable () -> Void
    @MainActor private var legacyTask: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    init(title: String, subtitle: String, onExpire: @escaping @Sendable () -> Void) {
        self.title = title
        self.onExpire = onExpire
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "NSZ-Konvertierung") { [weak self] in
            self?.endLegacy()
        }
        startContinuedProcessing(subtitle: subtitle)
    }

    private func startContinuedProcessing(subtitle: String) {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "de.nspz.app").convert.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] bgTask in
            guard let continued = bgTask as? BGContinuedProcessingTask, let self else {
                bgTask.setTaskCompleted(success: false)
                return
            }
            self.attach(continued)
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Kein Problem: die Konvertierung läuft im Vordergrund trotzdem weiter.
        }
    }

    private func attach(_ continued: BGContinuedProcessingTask) {
        lock.lock()
        if finished {
            lock.unlock()
            continued.setTaskCompleted(success: true)
            return
        }
        task = continued
        continued.progress.totalUnitCount = 1000
        continued.progress.completedUnitCount = Int64(fraction * 1000)
        lock.unlock()
        continued.expirationHandler = { [weak self] in
            self?.onExpire()
        }
    }

    func update(fraction: Double, subtitle: String) {
        lock.lock(); defer { lock.unlock() }
        self.fraction = fraction
        guard let task else { return }
        task.progress.completedUnitCount = Int64(fraction * 1000)
        if Date().timeIntervalSince(lastSubtitleUpdate) > 1 {
            lastSubtitleUpdate = Date()
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func end(success: Bool) {
        lock.lock()
        finished = true
        let current = task
        task = nil
        lock.unlock()
        current?.setTaskCompleted(success: success)
        endLegacy()
    }

    private func endLegacy() {
        Task { @MainActor in
            if self.legacyTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.legacyTask)
                self.legacyTask = .invalid
            }
        }
    }
}
