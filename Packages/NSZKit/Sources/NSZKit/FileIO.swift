import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fehler, die bei Analyse und Konvertierung auftreten können.
public enum NSZError: LocalizedError, Sendable, Equatable {
    case cannotOpen(String, Int32)
    case io(String, Int32)
    case truncated
    case notPFS0
    case invalidHeader(String)
    case notNCZ(String)
    case decompression(String)
    case crypto(Int32)
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    case hashMismatch(String)
    case insufficientSpace(required: UInt64, available: UInt64)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            return "Datei konnte nicht geöffnet werden: \((path as NSString).lastPathComponent) (\(String(cString: strerror(code))))"
        case let .io(what, code):
            return "Ein-/Ausgabefehler beim \(what): \(String(cString: strerror(code)))"
        case .truncated:
            return "Die Datei ist unvollständig oder beschädigt (vorzeitiges Dateiende)."
        case .notPFS0:
            return "Keine gültige NSZ/NSP-Datei (PFS0-Header fehlt)."
        case let .invalidHeader(detail):
            return "Ungültiger Header: \(detail)"
        case let .notNCZ(name):
            return "\(name) ist keine gültige NCZ-Datei (NCZSECTN fehlt)."
        case let .decompression(detail):
            return "Dekomprimierung fehlgeschlagen: \(detail)"
        case let .crypto(status):
            return "Verschlüsselungsfehler (CommonCrypto \(status))."
        case let .sizeMismatch(name, expected, actual):
            return "\(name): erwartete Größe \(expected) Bytes, erhalten \(actual) Bytes."
        case let .hashMismatch(name):
            return "Prüfsumme von \(name) stimmt nicht – die Quelldatei ist vermutlich beschädigt."
        case let .insufficientSpace(required, available):
            let f = ByteCountFormatter()
            return "Nicht genug Speicherplatz: benötigt \(f.string(fromByteCount: Int64(required))), frei \(f.string(fromByteCount: Int64(available)))."
        case .cancelled:
            return "Abgebrochen."
        }
    }
}

/// Schneller, positionsbasierter Lesezugriff (pread) ohne die Datei in den Speicher zu laden.
final class ReadFile {
    let fd: Int32
    let size: UInt64

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw NSZError.cannotOpen(url.path, errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            close(fd)
            throw NSZError.io("Lesen der Dateigröße", code)
        }
        self.fd = fd
        self.size = UInt64(st.st_size)
        _ = fcntl(fd, F_RDAHEAD, 1)
    }

    deinit { close(fd) }

    func read(into ptr: UnsafeMutableRawPointer, count: Int, at offset: UInt64) throws {
        var done = 0
        while done < count {
            let r = pread(fd, ptr + done, count - done, off_t(offset) + off_t(done))
            if r < 0 {
                if errno == EINTR { continue }
                throw NSZError.io("Lesen", errno)
            }
            if r == 0 { throw NSZError.truncated }
            done += r
        }
    }

    func readData(count: Int, at offset: UInt64) throws -> Data {
        guard offset + UInt64(count) <= size else { throw NSZError.truncated }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buf in
            if count > 0 { try read(into: buf.baseAddress!, count: count, at: offset) }
        }
        return data
    }
}

/// Sequentieller Schreibzugriff mit großen Blöcken.
final class WriteFile {
    private var fd: Int32
    private(set) var position: UInt64 = 0

    init(url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        guard fd >= 0 else { throw NSZError.cannotOpen(url.path, errno) }
        self.fd = fd
        // Große Dateien nicht im Page-Cache halten – entlastet den Arbeitsspeicher.
        _ = fcntl(fd, F_NOCACHE, 1)
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func preallocate(_ length: UInt64) {
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0, fst_length: off_t(length), fst_bytesalloc: 0)
        _ = fcntl(fd, F_PREALLOCATE, &store)
    }

    func write(_ ptr: UnsafeRawPointer, count: Int) throws {
        var done = 0
        while done < count {
            let r = Darwin.write(fd, ptr + done, count - done)
            if r < 0 {
                if errno == EINTR { continue }
                throw NSZError.io("Schreiben", errno)
            }
            done += r
        }
        position += UInt64(count)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            if let base = buf.baseAddress { try write(base, count: buf.count) }
        }
    }

    func close() throws {
        guard fd >= 0 else { return }
        let r = Darwin.close(fd)
        fd = -1
        if r != 0 { throw NSZError.io("Schließen", errno) }
    }
}

extension Data {
    @inline(__always)
    func le<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dst in
            let start = startIndex + offset
            _ = copyBytes(to: dst, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// Seitenausgerichteter Puffer für schnelle I/O.
final class AlignedBuffer {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 16)
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: self.capacity, alignment: 16384)
    }

    deinit { pointer.deallocate() }
}
