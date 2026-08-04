import Combine
import CryptoKit
import Foundation

struct GGUFDownloadOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let size: String
    let fileName: String
    let expectedBytes: Int64
    let sha256: String
    let url: URL
    let isRecommended: Bool
}

enum GGUFDownloadCatalog {
    nonisolated static let huggingFaceRevision = "27492c6696f2f868bbbe3aeafb633009ef932598"

    nonisolated static let options: [GGUFDownloadOption] = [
        GGUFDownloadOption(
            id: "gemma-4-e2b",
            title: "RhymeAI Gemma 4 E2B",
            subtitle: "Recommended for iPhone and iPad",
            size: "3.43 GB",
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 3_427_878_784,
            sha256: "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626",
            url: requiredURL(
                "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/\(huggingFaceRevision)/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true"
            ),
            isRecommended: true
        ),
        GGUFDownloadOption(
            id: "gemma-4-e4b",
            title: "RhymeAI Gemma 4 E4B",
            subtitle: "For devices with at least 10 GB memory",
            size: "5.34 GB",
            fileName: "gemma-4-E4B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 5_335_290_784,
            sha256: "e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3",
            url: requiredURL(
                "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/\(huggingFaceRevision)/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true"
            ),
            isRecommended: false
        ),
    ]

    nonisolated static func option(id: String?) -> GGUFDownloadOption? {
        options.first { $0.id == id }
    }

    nonisolated private static func requiredURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid GGUF download URL: \(string)")
        }
        return url
    }
}

enum GGUFModelStorage {
    nonisolated static func modelsDirectory(create: Bool) throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let directory = baseURL
            .appendingPathComponent("RhymeAI", isDirectory: true)
            .appendingPathComponent("Gemma", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    nonisolated static func installedModelFileNames() -> [String] {
        guard let directory = try? modelsDirectory(create: false),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else {
            return []
        }
        return contents
            .map(\.lastPathComponent)
            .filter { $0.lowercased().hasSuffix(".gguf") }
            .sorted()
    }
}

enum GGUFModelSelection {
    private static let defaultsKey = "selectedGGUFModelFileName"

    static var currentFileName: String? {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              value == URL(fileURLWithPath: value).lastPathComponent,
              value.lowercased().hasSuffix(".gguf") else {
            return nil
        }
        return value
    }

    static func save(fileName: String) {
        precondition(fileName == URL(fileURLWithPath: fileName).lastPathComponent)
        UserDefaults.standard.set(fileName, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func preferredFileName(in installedFileNames: [String]) -> String? {
        let installed = Set(installedFileNames.filter { $0.lowercased().hasSuffix(".gguf") })
        if let currentFileName, installed.contains(currentFileName) {
            return currentFileName
        }
        if let catalogMatch = GGUFDownloadCatalog.options.first(where: { installed.contains($0.fileName) }) {
            return catalogMatch.fileName
        }
        return installed.sorted().first
    }
}

@MainActor
final class GGUFDownloadManager: NSObject, ObservableObject {
    nonisolated private static let progressUpdateBytes: Int64 = 8 * 1024 * 1024
    nonisolated private static let verificationBufferBytes = 8 * 1024 * 1024

    @Published private(set) var installedModelFiles: Set<String> = []
    @Published private(set) var activeDownloadID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedModelFileName = GGUFModelSelection.currentFileName
    @Published private(set) var engineChoice = GGUFEngineChoice.current

    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        installedModelFiles = Set(GGUFModelStorage.installedModelFileNames())
        if let preferred = GGUFModelSelection.preferredFileName(in: Array(installedModelFiles)) {
            selectedModelFileName = preferred
        } else {
            selectedModelFileName = nil
        }
    }

    func start(_ option: GGUFDownloadOption) {
        guard activeTask == nil else { return }
        refreshInstalledModels()
        if installedModelFiles.contains(option.fileName) {
            select(option)
            statusMessage = "\(option.title) is ready to use."
            return
        }

        do {
            let directory = try GGUFModelStorage.modelsDirectory(create: true)
            try verifyFreeSpace(for: option, in: directory)
            let resumeURL = resumeDataURL(for: option, directory: directory)
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: option.url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                task = session.downloadTask(with: request)
            }
            task.taskDescription = option.id
            activeTask = task
            activeDownloadID = option.id
            progress = 0
            receivedBytes = 0
            statusMessage = "Downloading \(option.title)…"
            errorMessage = nil
            task.resume()
        } catch {
            errorMessage = "Could not start \(option.title): \(error.localizedDescription)"
        }
    }

    func pauseDownload() {
        guard let task = activeTask,
              let option = GGUFDownloadCatalog.option(id: task.taskDescription),
              let directory = try? GGUFModelStorage.modelsDirectory(create: true) else {
            return
        }
        activeTask = nil
        activeDownloadID = nil
        statusMessage = "Download paused. Tap Download to resume."
        let resumeURL = resumeDataURL(for: option, directory: directory)
        task.cancel { resumeData in
            guard let resumeData else { return }
            try? resumeData.write(to: resumeURL, options: .atomic)
        }
    }

    func select(_ option: GGUFDownloadOption) {
        guard installedModelFiles.contains(option.fileName) else { return }
        GGUFModelSelection.save(fileName: option.fileName)
        GGUFEngineChoice.gemma.save()
        selectedModelFileName = option.fileName
        engineChoice = .gemma
        statusMessage = "\(option.title) selected."
        errorMessage = nil
    }

    func selectEngine(_ choice: GGUFEngineChoice) {
        choice.save()
        engineChoice = choice
    }

    private func verifyFreeSpace(for option: GGUFDownloadOption, in directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let reserve: Int64 = 512 * 1024 * 1024
        guard available >= option.expectedBytes + reserve else {
            throw GGUFDownloadError.insufficientSpace(required: option.expectedBytes + reserve, available: available)
        }
    }

    private func resumeDataURL(for option: GGUFDownloadOption, directory: URL) -> URL {
        directory.appendingPathComponent("\(option.fileName).resume")
    }

    private func receiveProgress(optionID: String?, bytes: Int64) {
        guard activeDownloadID == optionID,
              let option = GGUFDownloadCatalog.option(id: optionID) else {
            return
        }
        let nextProgress = min(1, Double(bytes) / Double(option.expectedBytes))
        let percentChanged = Int(nextProgress * 100) != Int(progress * 100)
        guard bytes >= option.expectedBytes ||
              bytes - receivedBytes >= Self.progressUpdateBytes ||
              percentChanged else {
            return
        }
        receivedBytes = bytes
        progress = nextProgress
        statusMessage = "Downloading \(option.title)… \(Int(progress * 100))%"
    }

    private func finish(option: GGUFDownloadOption) {
        activeTask = nil
        activeDownloadID = nil
        progress = 1
        receivedBytes = option.expectedBytes
        refreshInstalledModels()
        select(option)
        statusMessage = "\(option.title) downloaded and selected."
    }

    private func fail(taskIdentifier: Int, option: GGUFDownloadOption?, error: Error) {
        guard activeTask?.taskIdentifier == taskIdentifier else { return }
        activeTask = nil
        activeDownloadID = nil
        statusMessage = nil
        errorMessage = "Download failed\(option.map { " for \($0.title)" } ?? ""): \(error.localizedDescription)"
    }

    private func setVerifying(optionID: String?) {
        guard activeDownloadID == optionID,
              let option = GGUFDownloadCatalog.option(id: optionID) else {
            return
        }
        progress = 1
        statusMessage = "Verifying \(option.title)…"
    }
}

extension GGUFDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            self?.receiveProgress(optionID: downloadTask.taskDescription, bytes: totalBytesWritten)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let optionID = downloadTask.taskDescription
        guard let option = GGUFDownloadCatalog.option(id: optionID) else { return }
        Task { @MainActor [weak self] in
            self?.setVerifying(optionID: optionID)
        }

        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw GGUFDownloadError.httpStatus(response.statusCode)
            }
            let directory = try GGUFModelStorage.modelsDirectory(create: true)
            let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
            let destinationURL = directory.appendingPathComponent(option.fileName)
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            try Self.validateDownload(at: stagingURL, option: option)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(option.fileName).resume")
            )
            Task { @MainActor [weak self] in
                self?.finish(option: option)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.fail(taskIdentifier: downloadTask.taskIdentifier, option: option, error: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let option = GGUFDownloadCatalog.option(id: task.taskDescription)
        if let option,
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let directory = try? GGUFModelStorage.modelsDirectory(create: true) {
            try? resumeData.write(
                to: directory.appendingPathComponent("\(option.fileName).resume"),
                options: .atomic
            )
        }
        Task { @MainActor [weak self] in
            self?.fail(taskIdentifier: task.taskIdentifier, option: option, error: error)
        }
    }

    nonisolated private static func validateDownload(at url: URL, option: GGUFDownloadOption) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualBytes == option.expectedBytes else {
            throw GGUFDownloadError.incomplete(expected: option.expectedBytes, actual: actualBytes)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw GGUFDownloadError.invalidFormat
        }
        try handle.seek(toOffset: 0)

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: verificationBufferBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == option.sha256 else {
            throw GGUFDownloadError.checksumMismatch
        }
    }
}

private enum GGUFDownloadError: LocalizedError {
    case httpStatus(Int)
    case incomplete(expected: Int64, actual: Int64)
    case invalidFormat
    case checksumMismatch
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "the server returned HTTP \(status)"
        case .incomplete(let expected, let actual):
            return "the file was incomplete: \(Self.format(actual)) of \(Self.format(expected))"
        case .invalidFormat:
            return "the downloaded file is not a GGUF model"
        case .checksumMismatch:
            return "the downloaded file failed its integrity check"
        case .insufficientSpace(let required, let available):
            return "not enough free storage: \(Self.format(required)) required, \(Self.format(available)) available"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
