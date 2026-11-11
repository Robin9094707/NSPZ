import Foundation

/// Größe des unkomprimierten NCA-Header-Bereichs am Anfang jeder NCZ.
let nczUncompressableHeaderSize: UInt64 = 0x4000

/// Eine Sektion im NCZSECTN-Header. Enthält den bereits entschlüsselten Sektionsschlüssel,
/// daher werden für die Rückwandlung keine Konsolen-Schlüssel (prod.keys) benötigt.
struct NCZSection: Sendable {
    let offset: UInt64
    let size: UInt64
    let cryptoType: UInt64
    let key: [UInt8]
    let counter: [UInt8]

    var end: UInt64 { offset + size }
    /// 3 = AES-CTR, 4 = AES-CTR (BKTR / Update-Patch).
    var isEncrypted: Bool { cryptoType == 3 || cryptoType == 4 }
}

struct NCZBlockHeader: Sendable {
    let version: UInt8
    let type: UInt8
    let blockSizeExponent: UInt8
    let decompressedSize: UInt64
    let compressedSizes: [UInt32]

    var blockSize: Int { 1 << Int(blockSizeExponent) }

    func decompressedSize(ofBlock index: Int) -> Int {
        if index < compressedSizes.count - 1 { return blockSize }
        return Int(decompressedSize - UInt64(compressedSizes.count - 1) * UInt64(blockSize))
    }
}

struct NCZLayout: Sendable {
    let sections: [NCZSection]
    let block: NCZBlockHeader?
    /// Offset der komprimierten Daten relativ zum Anfang der NCZ.
    let dataOffset: UInt64
    /// Größe der resultierenden NCA.
    let ncaSize: UInt64

    static func parse(_ file: ReadFile, entry: PFS0Entry) throws -> NCZLayout {
        let base = entry.offset
        guard entry.size >= nczUncompressableHeaderSize + 16 else { throw NSZError.notNCZ(entry.name) }
        let sectHead = try file.readData(count: 16, at: base + nczUncompressableHeaderSize)
        guard sectHead.prefix(8) == Data("NCZSECTN".utf8) else { throw NSZError.notNCZ(entry.name) }
        let count = sectHead.le(UInt64.self, at: 8)
        guard count > 0, count <= 64 else { throw NSZError.invalidHeader("\(entry.name): \(count) Sektionen") }

        var cursor = nczUncompressableHeaderSize + 16
        let raw = try file.readData(count: Int(count) * 0x40, at: base + cursor)
        cursor += count * 0x40

        var sections: [NCZSection] = []
        for i in 0..<Int(count) {
            let o = i * 0x40
            let start = raw.startIndex + o
            sections.append(NCZSection(
                offset: raw.le(UInt64.self, at: o),
                size: raw.le(UInt64.self, at: o + 8),
                cryptoType: raw.le(UInt64.self, at: o + 16),
                key: Array(raw[(start + 0x20)..<(start + 0x30)]),
                counter: Array(raw[(start + 0x30)..<(start + 0x40)])
            ))
        }
        sections.sort { $0.offset < $1.offset }

        var block: NCZBlockHeader?
        if cursor + 0x18 <= entry.size {
            let magic = try file.readData(count: 8, at: base + cursor)
            if magic == Data("NCZBLOCK".utf8) {
                let bh = try file.readData(count: 0x18, at: base + cursor)
                let exponent = bh[bh.startIndex + 11]
                let blockCount = Int(bh.le(UInt32.self, at: 12))
                let decompressed = bh.le(UInt64.self, at: 16)
                guard (14...32).contains(exponent), blockCount > 0, blockCount < 0x1000_0000 else {
                    throw NSZError.invalidHeader("\(entry.name): ungültiger NCZBLOCK-Header")
                }
                cursor += 0x18
                let list = try file.readData(count: blockCount * 4, at: base + cursor)
                cursor += UInt64(blockCount * 4)
                let sizes = (0..<blockCount).map { list.le(UInt32.self, at: $0 * 4) }
                block = NCZBlockHeader(version: bh[bh.startIndex + 8], type: bh[bh.startIndex + 9],
                                       blockSizeExponent: exponent, decompressedSize: decompressed,
                                       compressedSizes: sizes)
            }
        }

        let ncaSize = max(nczUncompressableHeaderSize, sections.map(\.end).max() ?? 0)
        if let block {
            let total = block.compressedSizes.reduce(UInt64(0)) { $0 + UInt64($1) }
            guard cursor + total <= entry.size else { throw NSZError.truncated }
        }
        return NCZLayout(sections: sections, block: block, dataOffset: cursor, ncaSize: ncaSize)
    }
}
