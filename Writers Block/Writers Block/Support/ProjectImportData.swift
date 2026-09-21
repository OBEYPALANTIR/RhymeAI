import Foundation

enum ProjectImportData {
    static let maximumBytes = 5 * 1_024 * 1_024

    enum ImportError: LocalizedError {
        case fileTooLarge

        var errorDescription: String? {
            "This project file is too large. Choose a project JSON file of 5 MiB or less."
        }
    }

    static func read(from url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1_024, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ImportError.fileTooLarge }
        }
        return data
    }
}
