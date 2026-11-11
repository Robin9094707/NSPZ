import Foundation
import NSZKit
import Observation
import UIKit
import os

enum SettingsKey {
    static let verifyHashes = "verifyHashes"
    static let keepAwake = "keepAwake"
    static let deleteSource = "deleteSourceAfterSuccess"
    static let threads = "threadCount"
    static let autoStart = "autoStart"
    static let watchFolder = "watchAppFolder"
    static let convertedSources = "convertedSources"
}

/// Warteschlange: Dateien werden nacheinander konvertiert (jede Datei nutzt intern alle Kerne).
@Observable
@MainActor
final class ConversionQueue {
    private(set) var jobs: [ConversionJob] = []
    private(set) var isProcessing = false
    /// Zählt erfolgreiche Konvertierungen – Auslöser für Haptik.
    private(set) var completedCount = 0
    private(set) var failedCount = 0

    let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
        UserDefaults.standard.register(defaults: [
            SettingsKey.verifyHashes: true,
            SettingsKey.keepAwake: true,
            SettingsKey.deleteSource: false,
            SettingsKey.threads: 0,
            SettingsKey.autoStart: false,
            SettingsKey.watchFolder: true,
        ])
        library.onScan = { [weak self] in self?.importFromAppFolder() }
        importFromAppFolder()
    }

    /// Quelldateien, die der Nutzer entfernt hat – werden nicht erneut automatisch übernommen.
    @ObservationIgnored private var dismissed: Set<URL> = []

    private var convertedSources: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: SettingsKey.convertedSources) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: SettingsKey.convertedSources) }
    }

    func wasConverted(_ item: LibraryItem) -> Bool {
        item.alreadyConverted || convertedSources.contains(item.url.path)
    }

    /// Übernimmt NSZ-Dateien, die per Dateien-App/Finder in den App-Ordner gelegt wurden.
    func importFromAppFolder() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.watchFolder) else { return }
        let known = Set(jobs.map { $0.sourceURL.standardizedFileURL })
        let converted = convertedSources
        for item in library.storedNSZ where item.isStable && !item.alreadyConverted {
            let url = item.url.standardizedFileURL
            guard !known.contains(url), !dismissed.contains(url), !converted.contains(url.path) else { continue }
            add(urls: [url], securityScoped: false)
        }
    }

    var activeJob: ConversionJob? { jobs.first { $0.state == .converting } }
    var readyJobs: [ConversionJob] { jobs.filter { $0.state == .ready } }
    var hasFinishedJobs: Bool { jobs.contains { $0.isFinished } }

    /// Gesamtfortschritt über alle aktiven/wartenden Jobs.
    var overallFraction: Double {
        let relevant = jobs.filter { $0.isActive || ($0.state == .done && isProcessing) }
        let total = relevant.reduce(UInt64(0)) { $0 + max($1.totalBytes, $1.analysis?.outputSize ?? 0) }
        guard total > 0 else { return 0 }
        let done = relevant.reduce(UInt64(0)) { $0 + ($1.state == .done ? max($1.totalBytes, $1.analysis?.outputSize ?? 0) : $1.bytesWritten) }
        return Double(done) / Double(total)
    }

    // MARK: Hinzufügen

    func add(urls: [URL], securityScoped: Bool = true) {
        for url in urls {
            dismissed.remove(url.standardizedFileURL)
            if jobs.contains(where: { $0.sourceURL == url && !$0.isFinished }) { continue }
            let owns = securityScoped && url.startAccessingSecurityScopedResource()
            let job = ConversionJob(sourceURL: url, ownsSecurityScope: owns)
            jobs.insert(job, at: 0)
            analyze(job)
        }
    }

    private func analyze(_ job: ConversionJob) {
        let url = job.sourceURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NSZConverter.analyze(url: url) }
            }.value
            switch result {
            case let .success(analysis):
                job.analysis = analysis
                job.totalBytes = analysis.outputSize
                job.state = .ready
                if UserDefaults.standard.bool(forKey: SettingsKey.autoStart) { start(job) }
            case let .failure(error):
                job.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Steuerung

    func start(_ job: ConversionJob) {
        guard job.state == .ready || job.state == .cancelled || isRetryable(job) else { return }
        if job.analysis == nil {
            job.state = .analyzing
            analyze(job)
            return
        }
        job.state = .queued
        processNext()
    }

    func startAll() {
        for job in jobs.reversed() where job.state == .ready { job.state = .queued }
        processNext()
    }

    func cancel(_ job: ConversionJob) {
        switch job.state {
        case .queued: job.state = .ready
        case .converting: job.cancelFlag.set()
        default: break
        }
    }

    func remove(_ job: ConversionJob) {
        if job.state == .converting { job.cancelFlag.set(); return }
        job.releaseSecurityScope()
        dismissed.insert(job.sourceURL.standardizedFileURL)
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        for job in jobs where job.isFinished {
            job.releaseSecurityScope()
            dismissed.insert(job.sourceURL.standardizedFileURL)
        }
        jobs.removeAll { $0.isFinished }
    }

    private func isRetryable(_ job: ConversionJob) -> Bool {
        if case .failed = job.state { return true }
        return false
    }

    // MARK: Verarbeitung

    private func processNext() {
        guard !isProcessing else { return }
        // Älteste zuerst (Liste ist neueste-zuerst sortiert)
        guard let next = jobs.last(where: { $0.state == .queued }) else {
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        isProcessing = true
        Task {
            await run(next)
            isProcessing = false
            processNext()
        }
    }

    private func run(_ job: ConversionJob) async {
        let defaults = UserDefaults.standard
        let options = NSZConversionOptions(
            verifyHashes: defaults.bool(forKey: SettingsKey.verifyHashes),
            threads: defaults.integer(forKey: SettingsKey.threads))
        if defaults.bool(forKey: SettingsKey.keepAwake) {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        job.beginRun()
        let input = job.sourceURL
        let output = library.outputURL(for: job.outputFileName)
        let flag = job.cancelFlag
        let title = job.metadata.title

        let activity = BackgroundActivity(title: "Konvertiere \(title)", subtitle: "NSZ → NSP") {
            flag.set()
        }

        let throttle = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let progressHandler: @Sendable (NSZProgress) -> Void = { progress in
            let now = Date()
            let shouldPublish = throttle.withLock { last -> Bool in
                if now.timeIntervalSince(last) >= 0.1 || progress.bytesWritten == progress.totalBytes {
                    last = now
                    return true
                }
                return false
            }
            guard shouldPublish else { return }
            activity.update(fraction: progress.fraction,
                            subtitle: "\(Int(progress.fraction * 100)) % · \(Format.size(progress.bytesWritten)) von \(Format.size(progress.totalBytes))")
            Task { @MainActor in job.apply(progress) }
        }

        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try NSZConverter.convert(input: input, output: output, options: options,
                                         progress: progressHandler, isCancelled: { flag.isSet })
            }
        }.value

        job.finishedAt = Date()
        switch result {
        case let .success(report):
            job.report = report
            job.outputURL = report.outputURL
            job.bytesWritten = report.outputSize
            job.totalBytes = report.outputSize
            job.state = .done
            completedCount += 1
            convertedSources.insert(input.standardizedFileURL.path)
            activity.end(success: true)
            if defaults.bool(forKey: SettingsKey.deleteSource) {
                try? FileManager.default.removeItem(at: input)
            }
        case let .failure(error):
            if (error as? NSZError) == .cancelled {
                job.state = .cancelled
            } else {
                job.state = .failed(error.localizedDescription)
                failedCount += 1
            }
            activity.end(success: false)
        }
        library.refresh()
    }
}
