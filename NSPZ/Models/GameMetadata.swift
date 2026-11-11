import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let nsz = UTType(importedAs: "de.nspz.nsz", conformingTo: .data)
    static let nsp = UTType(importedAs: "de.nspz.nsp", conformingTo: .data)
}

/// Informationen, die sich aus dem üblichen Dateinamen-Schema
/// `Spielname [TitleID][vVersion].nsz` ablesen lassen.
struct GameMetadata: Hashable, Sendable {
    enum Kind: String, Sendable {
        case base = "Spiel"
        case update = "Update"
        case dlc = "DLC"
        case unknown = "Paket"

        var symbol: String {
            switch self {
            case .base: "gamecontroller.fill"
            case .update: "arrow.down.circle.fill"
            case .dlc: "puzzlepiece.extension.fill"
            case .unknown: "shippingbox.fill"
            }
        }
    }

    let title: String
    let titleID: String?
    let version: String?
    let kind: Kind

    init(fileName: String) {
        let stem = (fileName as NSString).deletingPathExtension

        let idMatch = stem.firstMatch(of: /\[([0-9A-Fa-f]{16})\]/)
        titleID = idMatch.map { String($0.1).uppercased() }

        let versionMatch = stem.firstMatch(of: /\[v(\d+)\]/)
        version = versionMatch.map { String($0.1) }

        if let id = titleID {
            let suffix = id.suffix(3)
            if suffix == "000" { kind = .base }
            else if suffix == "800" { kind = .update }
            else { kind = .dlc }
        } else {
            kind = .unknown
        }

        var cleaned = stem.replacing(/\[[^\]]*\]/, with: "")
        cleaned = cleaned.replacing(/\s{2,}/, with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_")))
        title = cleaned.isEmpty ? stem : cleaned
    }

    var versionLabel: String? {
        guard let version, let number = Int(version) else { return nil }
        if number == 0 { return "v0" }
        // Switch-Versionen sind Vielfache von 65536 (z. B. 196608 = Update 3)
        if number % 65536 == 0 { return "v\(number) · #\(number / 65536)" }
        return "v\(number)"
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB, .useTB]
        return f
    }()

    static func size(_ value: UInt64) -> String { bytes.string(fromByteCount: Int64(value)) }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "–" }
        return bytes.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
