import Foundation

/// Ein Eintrag in einem PFS0-Container (NSP/NSZ).
public struct PFS0Entry: Sendable, Hashable {
    public let name: String
    /// Absoluter Offset der Daten in der Datei.
    public let offset: UInt64
    public let size: UInt64
}

/// PFS0 ("Partition File System") – das Containerformat von NSP und NSZ.
struct PFS0 {
    let entries: [PFS0Entry]
    let headerSize: UInt64

    static func parse(_ file: ReadFile) throws -> PFS0 {
        guard file.size >= 0x10 else { throw NSZError.notPFS0 }
        let head = try file.readData(count: 0x10, at: 0)
        guard head.prefix(4) == Data("PFS0".utf8) else { throw NSZError.notPFS0 }
        let count = Int(head.le(UInt32.self, at: 4))
        let stringTableSize = Int(head.le(UInt32.self, at: 8))
        guard count <= 0x10000, stringTableSize <= 0x100_0000 else {
            throw NSZError.invalidHeader("unplausible Anzahl an Dateien (\(count))")
        }
        let tableSize = 0x18 * count + stringTableSize
        let table = try file.readData(count: tableSize, at: 0x10)
        let headerSize = UInt64(0x10 + tableSize)
        let strings = table.subdata(in: (0x18 * count)..<tableSize)

        var entries: [PFS0Entry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 0x18
            let offset = table.le(UInt64.self, at: base)
            let size = table.le(UInt64.self, at: base + 8)
            let nameOffset = Int(table.le(UInt32.self, at: base + 16))
            guard nameOffset < strings.count else {
                throw NSZError.invalidHeader("Dateiname außerhalb der String-Tabelle")
            }
            let nameBytes = strings[(strings.startIndex + nameOffset)...].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let absolute = headerSize + offset
            guard absolute + size <= file.size else { throw NSZError.truncated }
            entries.append(PFS0Entry(name: name, offset: absolute, size: size))
        }
        return PFS0(entries: entries, headerSize: headerSize)
    }

    /// Erstellt einen PFS0-Header für die gegebenen Dateien (in Reihenfolge).
    static func buildHeader(names: [String], sizes: [UInt64]) -> Data {
        precondition(names.count == sizes.count)
        var strings = Data()
        var nameOffsets: [UInt32] = []
        for name in names {
            nameOffsets.append(UInt32(strings.count))
            strings.append(contentsOf: Array(name.utf8))
            strings.append(0)
        }
        // Header auf 0x20 Bytes auffüllen (wie bei gängigen Tools üblich).
        let unpadded = 0x10 + 0x18 * names.count + strings.count
        let padded = (unpadded + 0x1F) & ~0x1F
        strings.append(Data(count: padded - unpadded))

        var header = Data()
        header.append(contentsOf: Array("PFS0".utf8))
        header.appendLE(UInt32(names.count))
        header.appendLE(UInt32(strings.count))
        header.appendLE(UInt32(0))
        var offset: UInt64 = 0
        for (i, size) in sizes.enumerated() {
            header.appendLE(offset)
            header.appendLE(size)
            header.appendLE(nameOffsets[i])
            header.appendLE(UInt32(0))
            offset += size
        }
        header.append(strings)
        return header
    }
}
