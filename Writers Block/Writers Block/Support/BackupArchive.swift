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
    static func zip(_ entries: [(path: String, data: Data)]) throws -> Data {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let offset = archive.count
            let crc = crc32(entry.data)
            guard entry.data.count < Int(UInt32.max), offset < Int(UInt32.max) else { throw BackupArchiveError.tooLarge }
            // Version 2.0, UTF-8 names, stored, 1980-01-01 00:00.
            let common: [Any] = [UInt16(20), UInt16(0x0800), UInt16(0), UInt16(0), UInt16(0x21),
                                 crc, UInt32(entry.data.count), UInt32(entry.data.count), UInt16(name.count), UInt16(0)]
            archive.append(le(UInt32(0x0403_4b50)))
            common.forEach { archive.append(le($0)) }
            archive.append(name)
            archive.append(entry.data)

            central.append(le(UInt32(0x0201_4b50)))
            central.append(le(UInt16(20)))
            common.forEach { central.append(le($0)) }
            [UInt16(0), UInt16(0), UInt16(0)].forEach { central.append(le($0)) }
            central.append(le(UInt32(0)))
            central.append(le(UInt32(offset)))
            central.append(name)
        }
        guard archive.count < Int(UInt32.max), entries.count < Int(UInt16.max) else { throw BackupArchiveError.tooLarge }
        let centralOffset = archive.count
        archive.append(central)
        archive.append(le(UInt32(0x0605_4b50)))
        [UInt16(0), UInt16(0), UInt16(entries.count), UInt16(entries.count)].forEach { archive.append(le($0)) }
        archive.append(le(UInt32(central.count)))
        archive.append(le(UInt32(centralOffset)))
        archive.append(le(UInt16(0)))
        return archive
    }

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04])
    }

    /// Files by path; directories are skipped.
    static func unzip(_ input: Data) throws -> [String: Data] {
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
        var files: [String: Data] = [:]
        for _ in 0..<count {
            guard try u32(cursor) == 0x0201_4b50 else { throw BackupArchiveError.unreadable }
            let method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20)
            let size = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            let local = try u32(cursor + 42)
            guard cursor + 46 + nameLength <= data.count,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else {
                throw BackupArchiveError.unreadable
            }
            cursor += 46 + nameLength + extraLength + commentLength
            guard isSafePath(name) else { throw BackupArchiveError.unsafePath }
            guard !name.hasSuffix("/") else { continue }
            guard try u32(local) == 0x0403_4b50 else { throw BackupArchiveError.unreadable }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start + compressed <= data.count else { throw BackupArchiveError.unreadable }
            let body = data[start..<(start + compressed)]
            switch method {
            case 0:
                files[name] = Data(body)
            case 8:
                guard let inflated = try? (Data(body) as NSData).decompressed(using: .zlib) as Data,
                      inflated.count == size else { throw BackupArchiveError.unreadable }
                files[name] = inflated
            default:
                throw BackupArchiveError.unreadable
            }
        }
        return files
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

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    }
}
