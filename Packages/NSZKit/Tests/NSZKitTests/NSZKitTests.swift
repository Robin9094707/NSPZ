import XCTest
import CommonCrypto
import CryptoKit
import libzstd
@testable import NSZKit

/// Erzeugt synthetische NCAs, komprimiert sie wie `nsz` zu NCZ und prüft die bitgenaue Rückwandlung.
final class NSZKitTests: XCTestCase {

    struct FakeSection {
        let offset: UInt64
        let size: UInt64
        let cryptoType: UInt64
        let key: [UInt8]
        let counter: [UInt8]
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("nszkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Hilfsfunktionen (unabhängig von der Implementierung)

    private func random(_ count: Int, seed: inout UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            out[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        return out
    }

    /// Referenz-AES-CTR über AES-ECB (unabhängig von `AESCTR`).
    private func ctrReference(_ data: inout [UInt8], range: Range<Int>, key: [UInt8], nonce: [UInt8]) {
        var pos = range.lowerBound
        while pos < range.upperBound {
            var counter = Array(nonce[0..<8])
            var block = UInt64(pos >> 4)
            var low = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { low[7 - i] = UInt8(truncatingIfNeeded: block); block >>= 8 }
            counter += low
            var keystream = [UInt8](repeating: 0, count: 16)
            var moved = 0
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                 key, 16, nil, counter, 16, &keystream, 16, &moved)
            precondition(status == kCCSuccess)
            let skip = pos & 15
            let n = min(16 - skip, range.upperBound - pos)
            for i in 0..<n { data[pos + i] ^= keystream[skip + i] }
            pos += n
        }
    }

    private func zstdCompress(_ data: [UInt8], level: Int32 = 3) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let n = ZSTD_compress(&out, out.count, data, data.count, level)
        precondition(ZSTD_isError(n) == 0)
        return Array(out[0..<n])
    }

    private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { Array($0) }
    }

    /// Baut (plaintextNCA, originalNCA, ncz).
    private func makeNCA(sections: [FakeSection], blockExponent: UInt8?, seed: UInt64) -> (original: [UInt8], ncz: [UInt8]) {
        var seed = seed
        let size = Int(sections.map { $0.offset + $0.size }.max()!)
        var plain = random(size, seed: &seed)
        // Teilweise gut komprimierbare Bereiche
        for i in stride(from: 0x4000, to: size, by: 3) where (i / 0x3000) % 2 == 0 {
            plain[i] = 0x41; if i + 1 < size { plain[i + 1] = 0x42 }; if i + 2 < size { plain[i + 2] = 0 }
        }
        var original = plain
        for s in sections where s.cryptoType == 3 || s.cryptoType == 4 {
            ctrReference(&original, range: Int(s.offset)..<Int(s.offset + s.size), key: s.key, nonce: s.counter)
        }

        var ncz = Array(original[0..<0x4000])
        ncz += Array("NCZSECTN".utf8) + le(UInt64(sections.count))
        for s in sections {
            ncz += le(s.offset) + le(s.size) + le(s.cryptoType) + le(UInt64(0)) + s.key + s.counter
        }
        let body = Array(plain[0x4000...])
        if let exponent = blockExponent {
            let blockSize = 1 << Int(exponent)
            var blocks: [[UInt8]] = []
            var sizes: [UInt32] = []
            var i = 0
            while i < body.count {
                let chunk = Array(body[i..<min(body.count, i + blockSize)])
                let compressed = zstdCompress(chunk)
                if compressed.count < chunk.count {
                    blocks.append(compressed); sizes.append(UInt32(compressed.count))
                } else {
                    blocks.append(chunk); sizes.append(UInt32(chunk.count))
                }
                i += blockSize
            }
            ncz += Array("NCZBLOCK".utf8) + [2, 1, 0, exponent] + le(UInt32(blocks.count)) + le(UInt64(body.count))
            for s in sizes { ncz += le(s) }
            for b in blocks { ncz += b }
        } else {
            ncz += zstdCompress(body)
        }
        return (original, ncz)
    }

    private func sha256Hex(_ data: [UInt8]) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writePFS0(_ files: [(String, [UInt8])], to url: URL) throws {
        var data = PFS0.buildHeader(names: files.map(\.0), sizes: files.map { UInt64($0.1.count) })
        for f in files { data.append(contentsOf: f.1) }
        try data.write(to: url)
    }

    private func standardSections(seed: UInt64, firstOffset: UInt64 = 0x4000) -> [FakeSection] {
        var s = seed
        let k1 = random(16, seed: &s), c1 = random(8, seed: &s) + [UInt8](repeating: 0, count: 8)
        let k2 = random(16, seed: &s), c2 = random(8, seed: &s) + [UInt8](repeating: 0, count: 8)
        return [
            FakeSection(offset: firstOffset, size: 0x4A000 - firstOffset, cryptoType: 3, key: k1, counter: c1),
            FakeSection(offset: 0x4A000, size: 0x12200, cryptoType: 1, key: [UInt8](repeating: 0, count: 16), counter: [UInt8](repeating: 0, count: 16)),
            FakeSection(offset: 0x5C200, size: 0x31E00, cryptoType: 4, key: k2, counter: c2),
        ]
    }

    private func roundTrip(blockExponent: UInt8?, firstOffset: UInt64 = 0x4000, threads: Int = 0) throws {
        let ncaA = makeNCA(sections: standardSections(seed: 1, firstOffset: firstOffset), blockExponent: blockExponent, seed: 11)
        let ncaB = makeNCA(sections: standardSections(seed: 2), blockExponent: blockExponent, seed: 22)
        let nameA = String(sha256Hex(ncaA.original).prefix(32))
        let nameB = String(sha256Hex(ncaB.original).prefix(32))
        var seed: UInt64 = 99
        let ticket = random(0x2C0, seed: &seed)
        let cnmt = random(0x1000, seed: &seed)
        let cnmtName = String(sha256Hex(cnmt).prefix(32)) + ".cnmt.nca"

        let nsz = workDir.appendingPathComponent("Game [0100000000010000][v0].nsz")
        try writePFS0([
            (nameA + ".ncz", ncaA.ncz),
            (nameB + ".ncz", ncaB.ncz),
            (cnmtName, cnmt),
            ("0100000000010000000000000000000a.tik", ticket),
        ], to: nsz)
        let expected = workDir.appendingPathComponent("expected.nsp")
        try writePFS0([
            (nameA + ".nca", ncaA.original),
            (nameB + ".nca", ncaB.original),
            (cnmtName, cnmt),
            ("0100000000010000000000000000000a.tik", ticket),
        ], to: expected)

        let analysis = try NSZConverter.analyze(url: nsz)
        XCTAssertTrue(analysis.isCompressed)
        XCTAssertEqual(analysis.outputSize, UInt64(try Data(contentsOf: expected).count))
        XCTAssertEqual(analysis.entries.first?.kind, blockExponent == nil ? .nczSolid : .nczBlock)

        let output = workDir.appendingPathComponent("Game.nsp")
        let report = try NSZConverter.convert(input: nsz, output: output,
                                              options: .init(verifyHashes: true, threads: threads))
        XCTAssertEqual(report.verifiedCount, 3)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
    }

    // MARK: Tests

    func testSolidRoundTrip() throws { try roundTrip(blockExponent: nil) }
    func testBlockRoundTrip() throws { try roundTrip(blockExponent: 14) }
    func testBlockRoundTripSingleThread() throws { try roundTrip(blockExponent: 15, threads: 1) }
    func testSectionStartingInsideHeader() throws { try roundTrip(blockExponent: nil, firstOffset: 0xC00) }
    func testBlockSectionStartingInsideHeader() throws { try roundTrip(blockExponent: 16, firstOffset: 0xC00) }

    /// Updates (BKTR) haben oft über tausend Sektionen mit jeweils eigenem Zähler.
    func testUpdateWithManySections() throws {
        var s: UInt64 = 77
        var sections: [FakeSection] = []
        var offset: UInt64 = 0x4000
        let key = random(16, seed: &s)
        for i in 0..<1500 {
            let size = UInt64(0x200 * (1 + i % 7))
            let counter = random(8, seed: &s) + [UInt8](repeating: 0, count: 8)
            sections.append(FakeSection(offset: offset, size: size, cryptoType: i % 5 == 0 ? 1 : 4,
                                        key: key, counter: counter))
            offset += size
        }
        for exponent: UInt8? in [nil, 14] {
            let nca = makeNCA(sections: sections, blockExponent: exponent, seed: 7)
            let name = String(sha256Hex(nca.original).prefix(32))
            let nsz = workDir.appendingPathComponent("update.nsz")
            try writePFS0([(name + ".ncz", nca.ncz)], to: nsz)
            let output = workDir.appendingPathComponent("update.nsp")
            let report = try NSZConverter.convert(input: nsz, output: output)
            XCTAssertEqual(report.verifiedCount, 1)
            let expected = workDir.appendingPathComponent("update-expected.nsp")
            try writePFS0([(name + ".nca", nca.original)], to: expected)
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: expected))
            try FileManager.default.removeItem(at: output)
        }
    }

    func testUnalignedCTROffset() throws {
        var s: UInt64 = 5
        let key = random(16, seed: &s), nonce = random(16, seed: &s)
        let plain = random(1000, seed: &s)
        var reference = plain
        ctrReference(&reference, range: 0..<1000, key: key, nonce: nonce)
        var mine = Array(plain[37...])
        let cipher = try AESCTR(key: key, nonce: nonce, offset: 37)
        try mine.withUnsafeMutableBytes { try cipher.apply($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(mine, Array(reference[37...]))
    }

    func testCorruptedDataFailsVerification() throws {
        let nca = makeNCA(sections: standardSections(seed: 3), blockExponent: nil, seed: 33)
        let wrongName = String(repeating: "ab", count: 16)
        let nsz = workDir.appendingPathComponent("broken.nsz")
        try writePFS0([(wrongName + ".ncz", nca.ncz)], to: nsz)
        let output = workDir.appendingPathComponent("broken.nsp")
        XCTAssertThrowsError(try NSZConverter.convert(input: nsz, output: output)) { error in
            XCTAssertEqual(error as? NSZError, .hashMismatch(wrongName + ".nca"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
    }

    func testCancellationRemovesPartialFile() throws {
        let nca = makeNCA(sections: standardSections(seed: 4), blockExponent: 14, seed: 44)
        let nsz = workDir.appendingPathComponent("cancel.nsz")
        try writePFS0([("x.ncz", nca.ncz)], to: nsz)
        let output = workDir.appendingPathComponent("cancel.nsp")
        XCTAssertThrowsError(try NSZConverter.convert(input: nsz, output: output, isCancelled: { true })) { error in
            XCTAssertEqual(error as? NSZError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
    }

    func testRejectsNonPFS0() throws {
        let url = workDir.appendingPathComponent("junk.nsz")
        try Data(repeating: 7, count: 100).write(to: url)
        XCTAssertThrowsError(try NSZConverter.analyze(url: url)) { error in
            XCTAssertEqual(error as? NSZError, .notPFS0)
        }
    }
}
