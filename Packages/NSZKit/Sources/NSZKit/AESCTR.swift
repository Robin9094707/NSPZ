import Foundation
import CommonCrypto

/// Hardwarebeschleunigtes AES-128-CTR im Nintendo-Format:
/// Zähler = Nonce[0..<8] ‖ BigEndian64(offset / 16).
final class AESCTR {
    private var cryptor: CCCryptorRef?

    init(key: [UInt8], nonce: [UInt8], offset: UInt64) throws {
        precondition(key.count == 16 && nonce.count == 16)
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { iv[i] = nonce[i] }
        var block = offset >> 4
        for i in 0..<8 {
            iv[15 - i] = UInt8(truncatingIfNeeded: block)
            block >>= 8
        }
        let status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, key, kCCKeySizeAES128, nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard status == CCCryptorStatus(kCCSuccess) else { throw NSZError.crypto(status) }

        let skip = Int(offset & 0xF)
        if skip > 0 {
            var scratch = [UInt8](repeating: 0, count: skip)
            try scratch.withUnsafeMutableBytes { try apply($0.baseAddress!, count: skip) }
        }
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    /// Verschlüsselt (bzw. entschlüsselt) die Bytes an Ort und Stelle.
    func apply(_ ptr: UnsafeMutableRawPointer, count: Int) throws {
        var moved = 0
        let status = CCCryptorUpdate(cryptor, ptr, count, ptr, count, &moved)
        guard status == CCCryptorStatus(kCCSuccess), moved == count else { throw NSZError.crypto(status) }
    }
}
