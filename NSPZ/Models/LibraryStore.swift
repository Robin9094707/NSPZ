import Foundation
import Observation

struct LibraryItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let size: UInt64
    let date: Date
    let metadata: GameMetadata

    var name: String { url.lastPathComponent }
}

/// Verwaltet die konvertierten NSP-Dateien im Dokumente-Ordner der App
/// (sichtbar in der Dateien-App unter „Auf meinem iPhone › NSPZ").
@Observable
@MainActor
final class LibraryStore {
    enum Sort: String, CaseIterable, Identifiable {
        case date = "Neueste zuerst"
        case name = "Name"
        case size = "Größe"
        var id: String { rawValue }
    }

    private(set) var items: [LibraryItem] = []
    /// NSZ-Dateien, die per Dateien-App/Finder in den App-Ordner kopiert wurden.
    private(set) var storedNSZ: [LibraryItem] = []
    private(set) var freeSpace: UInt64 = 0
    var sort: Sort = .date { didSet { applySort() } }

    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }

    init() {
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        refresh()
    }

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
        let folders = [documents, documents.appendingPathComponent("Inbox")]
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let item = LibraryItem(url: url, size: UInt64(values.fileSize ?? 0),
                                       date: values.contentModificationDate ?? .distantPast,
                                       metadata: GameMetadata(fileName: url.lastPathComponent))
                switch url.pathExtension.lowercased() {
                case "nsp" where folder == documents: nsp.append(item)
                case "nsz": nsz.append(item)
                default: break
                }
            }
        }
        items = nsp
        storedNSZ = nsz.sorted { $0.date > $1.date }
        applySort()
        if let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            freeSpace = UInt64(max(0, capacity))
        }
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
