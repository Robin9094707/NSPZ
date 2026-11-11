import Foundation
import CryptoKit
import libzstd

// MARK: - Öffentliche Typen

public struct NSZEntryInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case nczSolid, nczBlock, plain }
    public var id: String { name }
    public let name: String
    public let outputName: String
    public let inputSize: UInt64
    public let outputSize: UInt64
    public let kind: Kind
}

public struct NSZAnalysis: Sendable {
    public let entries: [NSZEntryInfo]
    public let inputSize: UInt64
    public let outputSize: UInt64
    /// `true`, wenn mindestens eine Datei komprimiert (NCZ) ist.
    public var isCompressed: Bool { entries.contains { $0.kind != .plain } }
}

public struct NSZConversionOptions: Sendable {
    /// SHA-256 jeder NCA prüfen (Dateiname = Hash-Präfix).
    public var verifyHashes: Bool
    /// Anzahl paralleler Threads für Block-NCZ (0 = automatisch).
    public var threads: Int

    public init(verifyHashes: Bool = true, threads: Int = 0) {
        self.verifyHashes = verifyHashes
        self.threads = threads
    }
}

public struct NSZProgress: Sendable {
    public let bytesWritten: UInt64
    public let totalBytes: UInt64
    public let currentFile: String
    public var fraction: Double { totalBytes == 0 ? 0 : Double(bytesWritten) / Double(totalBytes) }
}

public struct NSZFileVerification: Sendable, Hashable {
    public enum Status: Sendable, Hashable { case verified, skipped }
    public let name: String
    public let status: Status
}

public struct NSZConversionReport: Sendable {
    public let outputURL: URL
    public let outputSize: UInt64
    public let duration: TimeInterval
    public let files: [NSZFileVerification]
    public var verifiedCount: Int { files.filter { $0.status == .verified }.count }
}

// MARK: - Konverter

public enum NSZConverter {

    /// Liest nur die Header und berechnet die Zielgröße – sehr schnell, auch bei riesigen Dateien.
    public static func analyze(url: URL) throws -> NSZAnalysis {
        let file = try ReadFile(url: url)
        let pfs = try PFS0.parse(file)
        var entries: [NSZEntryInfo] = []
        for entry in pfs.entries {
            if entry.name.lowercased().hasSuffix(".ncz") {
                let layout = try NCZLayout.parse(file, entry: entry)
                entries.append(NSZEntryInfo(
                    name: entry.name,
                    outputName: String(entry.name.dropLast(4)) + ".nca",
                    inputSize: entry.size, outputSize: layout.ncaSize,
                    kind: layout.block == nil ? .nczSolid : .nczBlock))
            } else {
                entries.append(NSZEntryInfo(name: entry.name, outputName: entry.name,
                                            inputSize: entry.size, outputSize: entry.size, kind: .plain))
            }
        }
        let header = PFS0.buildHeader(names: entries.map(\.outputName), sizes: entries.map(\.outputSize))
        let total = entries.reduce(UInt64(header.count)) { $0 + $1.outputSize }
        return NSZAnalysis(entries: entries, inputSize: file.size, outputSize: total)
    }

    /// Wandelt eine NSZ in eine NSP um. Blockiert den aufrufenden Thread – aus einem Hintergrund-Task aufrufen.
    public static func convert(
        input: URL,
        output: URL,
        options: NSZConversionOptions = .init(),
        progress: @escaping @Sendable (NSZProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> NSZConversionReport {
        let started = Date()
        let file = try ReadFile(url: input)
        let pfs = try PFS0.parse(file)

        var layouts: [String: NCZLayout] = [:]
        var names: [String] = []
        var sizes: [UInt64] = []
        for entry in pfs.entries {
            if entry.name.lowercased().hasSuffix(".ncz") {
                let layout = try NCZLayout.parse(file, entry: entry)
                layouts[entry.name] = layout
                names.append(String(entry.name.dropLast(4)) + ".nca")
                sizes.append(layout.ncaSize)
            } else {
                names.append(entry.name)
                sizes.append(entry.size)
            }
        }
        let header = PFS0.buildHeader(names: names, sizes: sizes)
        let total = sizes.reduce(UInt64(header.count), +)

        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available > 0, UInt64(available) < total {
            throw NSZError.insufficientSpace(required: total, available: UInt64(available))
        }

        let partial = output.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        let out = try WriteFile(url: partial)
        var success = false
        defer {
            if !success { try? FileManager.default.removeItem(at: partial) }
        }
        out.preallocate(total)
        try out.write(header)

        let context = RunContext(
            out: out, total: total, headerBytes: UInt64(header.count),
            threads: options.threads > 0 ? options.threads : max(2, ProcessInfo.processInfo.activeProcessorCount),
            progress: progress, isCancelled: isCancelled)

        var reports: [NSZFileVerification] = []
        for (index, entry) in pfs.entries.enumerated() {
            let outName = names[index]
            let expectedHash = options.verifyHashes ? expectedHashPrefix(for: outName) : nil
            context.currentFile = outName
            let hasher = expectedHash != nil ? HashBox() : nil
            let before = out.position

            if let layout = layouts[entry.name] {
                let emitter = NCAEmitter(sections: layout.sections, out: out, hasher: hasher, context: context)
                try decompress(file: file, entry: entry, layout: layout, emitter: emitter, context: context)
            } else {
                try copy(file: file, entry: entry, hasher: hasher, context: context)
            }

            let written = out.position - before
            guard written == sizes[index] else {
                throw NSZError.sizeMismatch(outName, expected: sizes[index], actual: written)
            }
            if let expectedHash, let hasher {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest.hasPrefix(expectedHash) else { throw NSZError.hashMismatch(outName) }
                reports.append(NSZFileVerification(name: outName, status: .verified))
            } else {
                reports.append(NSZFileVerification(name: outName, status: .skipped))
            }
        }

        try out.close()
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        success = true
        progress(NSZProgress(bytesWritten: total, totalBytes: total, currentFile: ""))
        return NSZConversionReport(outputURL: output, outputSize: total,
                                   duration: Date().timeIntervalSince(started), files: reports)
    }

    /// NCA-Dateinamen sind die ersten 16 Bytes des SHA-256 (32 Hex-Zeichen).
    static func expectedHashPrefix(for name: String) -> String? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".nca") else { return nil }
        let stem = String(lower.prefix { $0 != "." })
        guard stem.count == 32, stem.allSatisfy(\.isHexDigit) else { return nil }
        return stem
    }
}

// MARK: - Interna

final class HashBox {
    private var hasher = SHA256()
    func update(_ ptr: UnsafeRawPointer, count: Int) {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: count))
    }
    func finalize() -> SHA256.Digest { hasher.finalize() }
}

final class RunContext {
    let out: WriteFile
    let total: UInt64
    let threads: Int
    let progress: @Sendable (NSZProgress) -> Void
    let isCancelled: @Sendable () -> Bool
    var currentFile = ""
    private var written: UInt64
    private var lastReport: UInt64 = 0

    init(out: WriteFile, total: UInt64, headerBytes: UInt64, threads: Int,
         progress: @escaping @Sendable (NSZProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
        self.out = out
        self.total = total
        self.written = headerBytes
        self.threads = threads
        self.progress = progress
        self.isCancelled = isCancelled
    }

    func didWrite(_ count: Int) {
        written += UInt64(count)
        if written - lastReport >= 4 << 20 || written == total {
            lastReport = written
            progress(NSZProgress(bytesWritten: written, totalBytes: total, currentFile: currentFile))
        }
    }

    func checkCancelled() throws {
        if isCancelled() { throw NSZError.cancelled }
    }
}

/// Schreibt dekomprimierte NCA-Daten, verschlüsselt dabei die betroffenen Sektionen wieder
/// und berechnet optional den SHA-256.
final class NCAEmitter {
    private let sections: [NCZSection]
    private let out: WriteFile
    private let hasher: HashBox?
    private let context: RunContext
    private var cipher: AESCTR?
    private var cipherSection = -1
    private var cipherPosition: UInt64 = 0

    init(sections: [NCZSection], out: WriteFile, hasher: HashBox?, context: RunContext) {
        self.sections = sections
        self.out = out
        self.hasher = hasher
        self.context = context
    }

    /// Index der ersten Sektion mit `offset > position` (Binärsuche, Sektionen sind sortiert).
    private func firstSection(startingAfter position: UInt64) -> Int? {
        var low = 0, high = sections.count
        while low < high {
            let mid = (low + high) / 2
            if sections[mid].offset <= position { low = mid + 1 } else { high = mid }
        }
        return low < sections.count ? low : nil
    }

    private func sectionIndex(containing position: UInt64) -> Int? {
        if cipherSection >= 0, cipherSection < sections.count,
           position >= sections[cipherSection].offset, position < sections[cipherSection].end {
            return cipherSection
        }
        let after = firstSection(startingAfter: position) ?? sections.count
        // Kandidat ist die letzte Sektion, die bei oder vor `position` beginnt.
        var i = after - 1
        while i >= 0 {
            if position < sections[i].end { return i }
            if sections[i].size > 0 { break }
            i -= 1
        }
        return nil
    }

    func emitHeader(_ ptr: UnsafeMutableRawPointer, count: Int) throws {
        hasher?.update(ptr, count: count)
        try out.write(ptr, count: count)
        context.didWrite(count)
    }

    /// `position` ist der absolute Offset innerhalb der NCA.
    func emit(_ ptr: UnsafeMutableRawPointer, count: Int, at position: UInt64) throws {
        var done = 0
        while done < count {
            let p = position + UInt64(done)
            let remaining = UInt64(count - done)
            if let index = sectionIndex(containing: p) {
                let section = sections[index]
                let n = Int(min(remaining, section.end - p))
                if section.isEncrypted {
                    if cipherSection != index || cipherPosition != p || cipher == nil {
                        cipher = try AESCTR(key: section.key, nonce: section.counter, offset: p)
                        cipherSection = index
                    }
                    try cipher!.apply(ptr + done, count: n)
                    cipherPosition = p + UInt64(n)
                }
                done += n
            } else {
                let next = firstSection(startingAfter: p).map { sections[$0].offset } ?? UInt64.max
                done += Int(min(remaining, next - p))
            }
        }
        hasher?.update(ptr, count: count)
        try out.write(ptr, count: count)
        context.didWrite(count)
    }
}

/// Zwei-Stufen-Pipeline: Während ein Puffer verschlüsselt/gehasht/geschrieben wird,
/// wird bereits der nächste dekomprimiert.
final class EmitPipeline {
    private let queue = DispatchQueue(label: "nszkit.emit", qos: .userInitiated)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure: Error?

    func submit(_ work: @escaping () throws -> Void) throws {
        group.wait()
        try rethrow()
        group.enter()
        queue.async {
            do { try work() } catch {
                self.lock.lock(); self.failure = error; self.lock.unlock()
            }
            self.group.leave()
        }
    }

    func drain() throws {
        group.wait()
        try rethrow()
    }

    private func rethrow() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }
}

private func zstdError(_ code: Int) -> String {
    String(cString: ZSTD_getErrorName(code))
}

private func decompress(file: ReadFile, entry: PFS0Entry, layout: NCZLayout,
                        emitter: NCAEmitter, context: RunContext) throws {
    // 1. Unkomprimierter Header (0x4000 Bytes, unverändert übernehmen)
    let header = AlignedBuffer(capacity: Int(nczUncompressableHeaderSize))
    try file.read(into: header.pointer, count: Int(nczUncompressableHeaderSize), at: entry.offset)
    let headerCount = Int(min(nczUncompressableHeaderSize, layout.ncaSize))
    try emitter.emitHeader(header.pointer, count: headerCount)

    if let block = layout.block {
        try decompressBlocks(file: file, entry: entry, layout: layout, block: block, emitter: emitter, context: context)
    } else {
        try decompressSolid(file: file, entry: entry, layout: layout, emitter: emitter, context: context)
    }
}

private func decompressSolid(file: ReadFile, entry: PFS0Entry, layout: NCZLayout,
                             emitter: NCAEmitter, context: RunContext) throws {
    guard let stream = ZSTD_createDStream() else { throw NSZError.decompression("kein Speicher") }
    defer { ZSTD_freeDStream(stream) }
    let initResult = ZSTD_initDStream(stream)
    if ZSTD_isError(initResult) != 0 { throw NSZError.decompression(zstdError(initResult)) }

    let inCapacity = 4 << 20
    let outCapacity = 16 << 20
    let inBuffer = AlignedBuffer(capacity: inCapacity)
    let outBuffers = [AlignedBuffer(capacity: outCapacity), AlignedBuffer(capacity: outCapacity)]
    var current = 0
    let pipeline = EmitPipeline()

    var filePos = entry.offset + layout.dataOffset
    let fileEnd = entry.offset + entry.size
    var input = ZSTD_inBuffer(src: UnsafeRawPointer(inBuffer.pointer), size: 0, pos: 0)
    var ncaPos = nczUncompressableHeaderSize
    let ncaEnd = layout.ncaSize

    func refill() throws {
        let n = Int(min(UInt64(inCapacity), fileEnd - filePos))
        try file.read(into: inBuffer.pointer, count: n, at: filePos)
        filePos += UInt64(n)
        input = ZSTD_inBuffer(src: UnsafeRawPointer(inBuffer.pointer), size: n, pos: 0)
    }

    while ncaPos < ncaEnd {
        try context.checkCancelled()
        let target = outBuffers[current]
        var output = ZSTD_outBuffer(dst: target.pointer, size: outCapacity, pos: 0)
        while output.pos < output.size {
            if input.pos == input.size {
                if filePos >= fileEnd { break }
                try refill()
            }
            let outBefore = output.pos
            let inBefore = input.pos
            let result = ZSTD_decompressStream(stream, &output, &input)
            if ZSTD_isError(result) != 0 { throw NSZError.decompression(zstdError(result)) }
            if output.pos == outBefore && input.pos == inBefore
                && input.pos == input.size && filePos >= fileEnd { break }
        }
        let produced = Int(min(UInt64(output.pos), ncaEnd - ncaPos))
        if produced == 0 { break }
        let position = ncaPos
        ncaPos += UInt64(produced)
        try pipeline.submit {
            try emitter.emit(target.pointer, count: produced, at: position)
        }
        current ^= 1
    }
    try pipeline.drain()
    guard ncaPos == ncaEnd else { throw NSZError.sizeMismatch(entry.name, expected: ncaEnd, actual: ncaPos) }
}

private func decompressBlocks(file: ReadFile, entry: PFS0Entry, layout: NCZLayout, block: NCZBlockHeader,
                              emitter: NCAEmitter, context: RunContext) throws {
    let blockSize = block.blockSize
    let count = block.compressedSizes.count
    var offsets = [UInt64](repeating: 0, count: count)
    var running = entry.offset + layout.dataOffset
    for i in 0..<count {
        offsets[i] = running
        running += UInt64(block.compressedSizes[i])
        guard Int(block.compressedSizes[i]) <= blockSize else {
            throw NSZError.invalidHeader("\(entry.name): Block \(i) größer als Blockgröße")
        }
    }

    let memoryBudget = 96 << 20
    let batch = max(1, min(context.threads * 2, memoryBudget / blockSize))
    let inBuffer = AlignedBuffer(capacity: batch * blockSize)
    let outBuffers = [AlignedBuffer(capacity: batch * blockSize), AlignedBuffer(capacity: batch * blockSize)]
    var current = 0
    let pipeline = EmitPipeline()
    var ncaPos = nczUncompressableHeaderSize
    let ncaEnd = layout.ncaSize

    var start = 0
    while start < count && ncaPos < ncaEnd {
        try context.checkCancelled()
        let end = min(count, start + batch)
        let readStart = offsets[start]
        let readLength = Int(offsets[end - 1] + UInt64(block.compressedSizes[end - 1]) - readStart)
        try file.read(into: inBuffer.pointer, count: readLength, at: readStart)

        let target = outBuffers[current]
        let errorLock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: end - start) { k in
            let i = start + k
            let compressedSize = Int(block.compressedSizes[i])
            let decompressedSize = block.decompressedSize(ofBlock: i)
            let src = inBuffer.pointer + Int(offsets[i] - readStart)
            let dst = target.pointer + k * blockSize
            if compressedSize < decompressedSize {
                let r = ZSTD_decompress(dst, decompressedSize, src, compressedSize)
                if ZSTD_isError(r) != 0 || r != decompressedSize {
                    errorLock.lock()
                    failure = NSZError.decompression(ZSTD_isError(r) != 0 ? zstdError(r) : "Block \(i) unvollständig")
                    errorLock.unlock()
                }
            } else {
                dst.copyMemory(from: src, byteCount: decompressedSize)
            }
        }
        if let failure { throw failure }

        let batchBytes = (end - start - 1) * blockSize + block.decompressedSize(ofBlock: end - 1)
        let produced = Int(min(UInt64(batchBytes), ncaEnd - ncaPos))
        let position = ncaPos
        ncaPos += UInt64(produced)
        try pipeline.submit {
            try emitter.emit(target.pointer, count: produced, at: position)
        }
        current ^= 1
        start = end
    }
    try pipeline.drain()
    guard ncaPos == ncaEnd else { throw NSZError.sizeMismatch(entry.name, expected: ncaEnd, actual: ncaPos) }
}

private func copy(file: ReadFile, entry: PFS0Entry, hasher: HashBox?, context: RunContext) throws {
    let capacity = 16 << 20
    let buffers = [AlignedBuffer(capacity: capacity), AlignedBuffer(capacity: capacity)]
    var current = 0
    let pipeline = EmitPipeline()
    var position = entry.offset
    let end = entry.offset + entry.size
    let out = context.out
    while position < end {
        try context.checkCancelled()
        let n = Int(min(UInt64(capacity), end - position))
        let buffer = buffers[current]
        try file.read(into: buffer.pointer, count: n, at: position)
        position += UInt64(n)
        try pipeline.submit {
            hasher?.update(buffer.pointer, count: n)
            try out.write(buffer.pointer, count: n)
            context.didWrite(n)
        }
        current ^= 1
    }
    try pipeline.drain()
}
