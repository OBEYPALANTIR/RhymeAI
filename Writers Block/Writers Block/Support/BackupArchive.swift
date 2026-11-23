import Compression
import Foundation

enum BackupArchiveError: Error, Equatable {
    case unreadable
    case tooLarge
    /// An entry path that climbs out (`..`), is absolute, or names a drive.
    case unsafePath
}

/// The "Export all songs" zip: written uncompressed (audio does not compress),
/// read back stored or deflated so a zip re-packed by another tool still imports.
/// No ZIP64, so an archive is limited to 4 GiB.
enum BackupArchive {
    struct Budget {
        let entryBytes: Int
        let totalBytes: Int

        static let production = Self(entryBytes: BackupArchive.maxEntryBytes, totalBytes: BackupArchive.maxTotalBytes)

        func add(_ bytes: Int, compressedBytes: Int? = nil, to total: inout Int) throws {
            let (next, overflow) = total.addingReportingOverflow(bytes)
            guard bytes >= 0, bytes <= entryBytes, (compressedBytes ?? bytes) <= entryBytes,
                  !overflow, next <= totalBytes else { throw BackupArchiveError.tooLarge }
            total = next
        }
    }

    static func zip(_ entries: [(path: String, data: Data)], budget: Budget = .production) throws -> Data {
        var total = 0
        for entry in entries {
            try budget.add(entry.data.count, to: &total)
        }
        var archive = Data()
        var central = Data()
        for entry in entries {
            archive.append(try header(entry.path, crc: crc32(entry.data), size: entry.data.count, offset: archive.count, central: &central))
            archive.append(entry.data)
        }
        archive.append(try endRecord(central, offset: archive.count, count: entries.count))
        return archive
    }

    /// Bytes the file writer reads from a source at a time.
    static let chunkBytes = 64 * 1024

    /// The same stored zip as `zip(_:budget:)`, written to `destination` while each
    /// source file is read `chunkBytes` at a time, so no whole member or archive is
    /// held in memory. It is built in a hidden file beside `destination` and moved
    /// there only when complete; on any error that file is removed and an existing
    /// `destination` is left as it was. `read` is the chunk reader, replaceable in tests.
    static func zip(_ entries: [(path: String, source: URL)], to destination: URL, budget: Budget = .production,
                    read: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }) throws {
        // Every size is checked against the budget before anything is written.
        var total = 0
        let sizes = try entries.map { entry in
            guard let size = try entry.source.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw BackupArchiveError.unreadable }
            try budget.add(size, to: &total)
            return size
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)") // fixed length, so any valid destination name works
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw BackupArchiveError.unreadable }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var offset = 0
            var central = Data()
            for (entry, size) in Swift.zip(entries, sizes) {
                let input = try FileHandle(forReadingFrom: entry.source)
                defer { try? input.close() }
                var unused = Data()
                let local = try header(entry.path, crc: 0, size: size, offset: offset, central: &unused)
                try output.write(contentsOf: local)
                var crc: UInt32 = 0
                var remaining = size
                while remaining > 0 {
                    try autoreleasepool {
                        guard let chunk = try read(input, min(chunkBytes, remaining)), !chunk.isEmpty, chunk.count <= remaining else {
                            throw BackupArchiveError.unreadable
                        }
                        crc = crc32(chunk, continuing: crc)
                        try output.write(contentsOf: chunk)
                        remaining -= chunk.count
                    }
                }
                // A source that grew since it was measured would be cut short.
                guard try read(input, 1)?.isEmpty ?? true else { throw BackupArchiveError.unreadable }
                // The CRC sits 14 bytes into the local header; a data descriptor would change the format.
                try output.seek(toOffset: UInt64(offset + 14))
                try output.write(contentsOf: le(crc))
                try output.seekToEnd()
                _ = try header(entry.path, crc: crc, size: size, offset: offset, central: &central)
                offset += local.count + size
            }
            try output.write(contentsOf: try endRecord(central, offset: offset, count: entries.count))
            try output.close()
            // rename(2) swaps the file in one step on this volume, or fails leaving the destination as it was.
            guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The local header of one stored member at `offset`; its central record is appended to `central`.
    private static func header(_ path: String, crc: UInt32, size: Int, offset: Int, central: inout Data) throws -> Data {
        let name = Data(path.utf8)
        guard size < Int(UInt32.max), offset < Int(UInt32.max), name.count <= Int(UInt16.max) else { throw BackupArchiveError.tooLarge }
        // Version 2.0, UTF-8 names, stored, 1980-01-01 00:00.
        let common: [Any] = [UInt16(20), UInt16(0x0800), UInt16(0), UInt16(0), UInt16(0x21),
                             crc, UInt32(size), UInt32(size), UInt16(name.count), UInt16(0)]
        var local = le(UInt32(0x0403_4b50))
        common.forEach { local.append(le($0)) }
        local.append(name)

        central.append(le(UInt32(0x0201_4b50)))
        central.append(le(UInt16(20)))
        common.forEach { central.append(le($0)) }
        [UInt16(0), UInt16(0), UInt16(0)].forEach { central.append(le($0)) }
        central.append(le(UInt32(0)))
        central.append(le(UInt32(offset)))
        central.append(name)
        return local
    }

    /// The central directory and end record for `count` members ending at `offset`.
    private static func endRecord(_ central: Data, offset: Int, count: Int) throws -> Data {
        guard offset + central.count < Int(UInt32.max), count < Int(UInt16.max) else { throw BackupArchiveError.tooLarge }
        var end = central
        end.append(le(UInt32(0x0605_4b50)))
        [UInt16(0), UInt16(0), UInt16(count), UInt16(count)].forEach { end.append(le($0)) }
        end.append(le(UInt32(central.count)))
        end.append(le(UInt32(offset)))
        end.append(le(UInt16(0)))
        return end
    }

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04])
    }

    /// Shared per-entry and total payload limits; recordings are at most 16 MiB.
    static let maxEntryBytes = 64 * 1024 * 1024
    static let maxTotalBytes = 1024 * 1024 * 1024

    /// Files by path; directories are skipped. Every entry, directories included,
    /// must be a safe path that `allow` accepts, and declared sizes must fit the
    /// limits, before anything is inflated; inflation stops at the declared size.
    static func unzip(_ input: Data, budget: Budget = .production, allow: (String) -> Bool = { _ in true }) throws -> [String: Data] {
        let data = Data(input)
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw BackupArchiveError.unreadable }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            try u16(offset) | (try u16(offset + 2)) << 16
        }
        // The end-of-central-directory record sits within the last 64 KiB + 22 bytes.
        var end = data.count - 22
        while end >= max(0, data.count - 65_557), try u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= 0, end >= data.count - 65_557 else { throw BackupArchiveError.unreadable }
        let count = try u16(end + 10)
        var cursor = try u32(end + 16)

        var entries: [(name: String, method: Int, compressed: Int, size: Int, local: Int)] = []
        var total = 0
        for _ in 0..<count {
            guard try u32(cursor) == 0x0201_4b50 else { throw BackupArchiveError.unreadable }
            let nameLength = try u16(cursor + 28)
            guard cursor + 46 + nameLength <= data.count,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else {
                throw BackupArchiveError.unreadable
            }
            guard isSafePath(name), allow(name) else { throw BackupArchiveError.unsafePath }
            let entry = (name: name, method: try u16(cursor + 10), compressed: try u32(cursor + 20), size: try u32(cursor + 24), local: try u32(cursor + 42))
            try budget.add(entry.size, compressedBytes: entry.compressed, to: &total)
            entries.append(entry)
            cursor += 46 + nameLength + (try u16(cursor + 30)) + (try u16(cursor + 32))
        }

        var files: [String: Data] = [:]
        for entry in entries where !entry.name.hasSuffix("/") {
            guard try u32(entry.local) == 0x0403_4b50 else { throw BackupArchiveError.unreadable }
            let start = entry.local + 30 + (try u16(entry.local + 26)) + (try u16(entry.local + 28))
            guard start + entry.compressed <= data.count else { throw BackupArchiveError.unreadable }
            let body = data[start..<(start + entry.compressed)]
            switch entry.method {
            case 0:
                guard entry.compressed == entry.size else { throw BackupArchiveError.unreadable }
                files[entry.name] = Data(body)
            case 8:
                files[entry.name] = try inflate(Data(body), expectedSize: entry.size)
            default:
                throw BackupArchiveError.unreadable
            }
        }
        return files
    }

    /// Raw DEFLATE into a buffer one byte larger than declared: more output than
    /// declared means the entry lies about its size and is refused.
    private static func inflate(_ body: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize + 1)
        let written = output.withUnsafeMutableBytes { destination in
            body.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw BackupArchiveError.unreadable }
        return output.prefix(expectedSize)
    }

    /// Relative, forward-slash paths with no `..` or `.` parts and no drive letter.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.dropLast(path.hasSuffix("/") ? 1 : 0).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func le(_ value: Any) -> Data {
        switch value {
        case let value as UInt16: return withUnsafeBytes(of: value.littleEndian) { Data($0) }
        case let value as UInt32: return withUnsafeBytes(of: value.littleEndian) { Data($0) }
        default: preconditionFailure("zip fields are UInt16 or UInt32")
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    /// Pass the previous result as `continuing` to extend a CRC over a following chunk.
    static func crc32(_ data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        ~data.reduce(~crc) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    }
}
