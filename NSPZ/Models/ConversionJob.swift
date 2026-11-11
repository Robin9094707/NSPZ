import Foundation
import NSZKit
import os

/// Thread-sicheres Abbruch-Flag für den Hintergrund-Konverter.
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
    func reset() { state.withLock { $0 = false } }
}

@Observable
@MainActor
final class ConversionJob: Identifiable {
    enum State: Equatable {
        case analyzing
        case ready
        case queued
        case converting
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL
    let fileName: String
    let metadata: GameMetadata
    let ownsSecurityScope: Bool

    var state: State = .analyzing
    var analysis: NSZAnalysis?
    var bytesWritten: UInt64 = 0
    var totalBytes: UInt64 = 0
    var currentFile = ""
    var bytesPerSecond: Double = 0
    var startedAt: Date?
    var finishedAt: Date?
    var report: NSZConversionReport?
    var outputURL: URL?

    @ObservationIgnored let cancelFlag = CancelFlag()
    @ObservationIgnored private var lastSample: (date: Date, bytes: UInt64)?

    init(sourceURL: URL, ownsSecurityScope: Bool) {
        self.sourceURL = sourceURL
        self.ownsSecurityScope = ownsSecurityScope
        self.fileName = sourceURL.lastPathComponent
        self.metadata = GameMetadata(fileName: sourceURL.lastPathComponent)
    }

    var fraction: Double {
        switch state {
        case .done: 1
        case .converting: totalBytes == 0 ? 0 : min(1, Double(bytesWritten) / Double(totalBytes))
        default: 0
        }
    }

    var remainingTime: TimeInterval? {
        guard state == .converting, bytesPerSecond > 1, totalBytes > bytesWritten else { return nil }
        return Double(totalBytes - bytesWritten) / bytesPerSecond
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isActive: Bool { state == .converting || state == .queued }
    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: true
        default: false
        }
    }

    var outputFileName: String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem + ".nsp"
    }

    func beginRun() {
        cancelFlag.reset()
        state = .converting
        bytesWritten = 0
        bytesPerSecond = 0
        startedAt = Date()
        finishedAt = nil
        lastSample = nil
        report = nil
    }

    func apply(_ progress: NSZProgress) {
        guard state == .converting else { return }
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.date)
            if dt >= 0.25, progress.bytesWritten > last.bytes {
                let instant = Double(progress.bytesWritten - last.bytes) / dt
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
                lastSample = (now, progress.bytesWritten)
            }
        } else {
            lastSample = (now, progress.bytesWritten)
        }
        bytesWritten = progress.bytesWritten
        totalBytes = progress.totalBytes
        if !progress.currentFile.isEmpty { currentFile = progress.currentFile }
    }

    func releaseSecurityScope() {
        if ownsSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
    }
}
