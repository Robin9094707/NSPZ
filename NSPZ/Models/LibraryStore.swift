import Foundation
import Observation

struct LibraryItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let size: UInt64
    let date: Date
    let metadata: GameMetadata
    /// Datei wird nicht mehr geschrieben (z. B. Kopiervorgang in der Dateien-App abgeschlossen).
    var isStable = true
    /// Zu dieser NSZ existiert bereits eine NSP in der Bibliothek.
    var alreadyConverted = false

    var name: String { url.lastPathComponent }
    var stem: String { (url.lastPathComponent as NSString).deletingPathExtension }
}

/// Verwaltet die konvertierten NSP-Dateien im Dokumente-Ordner der App
/// (sichtbar in der Dateien-App unter „Auf meinem iPhone › NSPZ") und
/// überwacht den Ordner auf neu abgelegte NSZ-Dateien.
@Observable
@MainActor
final class LibraryStore {
    enum Sort: String, CaseIterable, Identifiable {
        case date = "Neueste zuerst"
        case name = "Name"
        case size = "Größe"
        var id: String { rawValue }
    }

    static let dropFolderName = "NSZ hier ablegen"

    private(set) var items: [LibraryItem] = []
    /// NSZ-Dateien, die per Dateien-App/Finder irgendwo in den App-Ordner gelegt wurden.
    private(set) var storedNSZ: [LibraryItem] = []
    private(set) var freeSpace: UInt64 = 0
    var sort: Sort = .date { didSet { applySort() } }

    /// Wird nach jedem Scan aufgerufen (die Warteschlange übernimmt neue Dateien automatisch).
    @ObservationIgnored var onScan: (() -> Void)?

    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var dropFolder: URL { documents.appendingPathComponent(Self.dropFolderName, isDirectory: true) }

    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var lastSizes: [URL: UInt64] = [:]

    init() {
        try? FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        refresh()
        startWatching()
    }

    // MARK: Überwachung

    private func startWatching() {
        for folder in [documents, dropFolder, documents.appendingPathComponent("Inbox")] {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        // Zusätzlich regelmäßig prüfen: erkennt Unterordner und laufende Kopiervorgänge.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRefresh = false
                self?.refresh()
            }
        }
    }

    // MARK: Scan

    func outputURL(for fileName: String) -> URL {
        var candidate = documents.appendingPathComponent(fileName)
        let stem = (fileName as NSString).deletingPathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = documents.appendingPathComponent("\(stem) (\(counter)).nsp")
            counter += 1
        }
        return candidate
    }

    func refresh() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var nsp: [LibraryItem] = []
        var nsz: [LibraryItem] = []
        var sizes: [URL: UInt64] = [:]

        if let enumerator = FileManager.default.enumerator(
            at: documents, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "nsp" || ext == "nsz" else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let size = UInt64(values.fileSize ?? 0)
                let date = values.contentModificationDate ?? .distantPast
                let url = url.standardizedFileURL
                sizes[url] = size
                // Stabil = Größe seit dem letzten Scan unverändert und seit 3 s nicht mehr geändert.
                let stable = size > 0 && lastSizes[url] == size && Date().timeIntervalSince(date) > 3
                let item = LibraryItem(url: url, size: size, date: date,
                                       metadata: GameMetadata(fileName: url.lastPathComponent),
                                       isStable: stable)
                if ext == "nsp" { nsp.append(item) } else { nsz.append(item) }
            }
        }
        lastSizes = sizes

        let converted = Set(nsp.map { $0.stem.lowercased() })
        nsz = nsz.map { item in
            var copy = item
            copy.alreadyConverted = converted.contains(item.stem.lowercased())
            return copy
        }

        if items.map(\.url) != nsp.map(\.url) || items.map(\.size) != nsp.map(\.size) {
            items = nsp
            applySort()
        }
        let sortedNSZ = nsz.sorted { $0.date > $1.date }
        if sortedNSZ != storedNSZ { storedNSZ = sortedNSZ }

        if let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            let free = UInt64(max(0, capacity))
            if free / 50_000_000 != freeSpace / 50_000_000 { freeSpace = free }
        }
        onScan?()
    }

    private func applySort() {
        switch sort {
        case .date: items.sort { $0.date > $1.date }
        case .name: items.sort { $0.metadata.title.localizedStandardCompare($1.metadata.title) == .orderedAscending }
        case .size: items.sort { $0.size > $1.size }
        }
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        refresh()
    }

    @discardableResult
    func rename(_ item: LibraryItem, to newName: String) -> Bool {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return false }
        if !name.lowercased().hasSuffix(".nsp") { name += ".nsp" }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != item.url, !FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            refresh()
            return true
        } catch {
            return false
        }
    }
}
