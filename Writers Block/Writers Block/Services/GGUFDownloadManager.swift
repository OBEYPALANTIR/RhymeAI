import Combine
import CryptoKit
import Darwin
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
    // Model versions:
    // - E2B: v2, trained 2026-10-06 on teacher-data-v2 (embeds a revised chat template).
    // - E4B: v1, unchanged; the pinned revision still serves the same E4B bytes.
    nonisolated static let huggingFaceRevision = "1647aace10f942ba8dca76e9e37d6be22566fef9"

    nonisolated static let options: [GGUFDownloadOption] = [
        GGUFDownloadOption(
            id: "gemma-4-e2b",
            title: "RhymeAI Gemma 4 E2B",
            subtitle: "Recommended for iPhone and iPad",
            size: "3.43 GB",
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 3_427_880_800,
            sha256: "b250c2f6a91d9f7659f7ac2c90ccc563ca96a84aea4c1e8a3463fafc77d004af",
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

nonisolated func ggufDownloadRequest(for option: GGUFDownloadOption) -> URLRequest {
    var request = URLRequest(url: option.url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
}

nonisolated func isLegacyGGUFDownloadArtifact(fileName: String) -> Bool {
    GGUFDownloadCatalog.options.contains { option in
        fileName == "\(option.fileName).download" ||
            (fileName.hasPrefix("\(option.id).segment-") &&
                (fileName.hasSuffix(".part") || fileName.hasSuffix(".resume")))
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
        var directory = baseURL
            .appendingPathComponent("RhymeAI", isDirectory: true)
            .appendingPathComponent("Gemma", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return directory
    }

    nonisolated static func installedModelFileNames() -> [String] {
        guard let directory = try? modelsDirectory(create: false) else { return [] }
        return installedModelFileNames(in: directory)
    }

    /// A catalog file name counts as installed only when its size matches the current
    /// catalog entry, so a previous model version kept under the same name is offered
    /// for re-download instead of being reported as ready. The full SHA-256 check still
    /// runs at download install and model load.
    nonisolated static func installedModelFileNames(in directory: URL) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return []
        }
        return contents
            .filter { url in
                let fileName = url.lastPathComponent
                guard fileName.lowercased().hasSuffix(".gguf") else { return false }
                guard let option = GGUFDownloadCatalog.options.first(where: { $0.fileName == fileName }) else {
                    return true
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                return bytes == option.expectedBytes
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Resume data is keyed by the artifact SHA-256, so a paused download of a previous
    /// model version is never resumed into the current catalog entry.
    nonisolated static func resumeDataURL(for option: GGUFDownloadOption, in directory: URL) -> URL {
        directory.appendingPathComponent("\(option.fileName).\(option.sha256.prefix(16)).resume")
    }

    /// Removes what a previous version of `option` left under the same name: an installed
    /// file whose size no longer matches the catalog entry (it can never pass load-time
    /// validation) and resume data keyed to another artifact. Returns the bytes freed.
    @discardableResult
    nonisolated static func removeStaleArtifacts(for option: GGUFDownloadOption, in directory: URL) throws -> Int64 {
        let fileManager = FileManager.default
        var freedBytes: Int64 = 0
        let installedURL = directory.appendingPathComponent(option.fileName)
        if let bytes = try? installedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(bytes) != option.expectedBytes {
            try fileManager.removeItem(at: installedURL)
            freedBytes += Int64(bytes)
        }
        let currentResumeName = resumeDataURL(for: option, in: directory).lastPathComponent
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name.hasPrefix("\(option.fileName).") && name.hasSuffix(".resume") && name != currentResumeName {
                try fileManager.removeItem(at: url)
            }
        }
        return freedBytes
    }

    /// Reclaims stale artifacts first, then requires room for the full download plus a
    /// reserve, so a device that only has room once the previous version is gone can upgrade.
    nonisolated static func prepareSpace(
        for option: GGUFDownloadOption,
        in directory: URL,
        availableCapacity: (URL) throws -> Int64?
    ) throws {
        try removeStaleArtifacts(for: option, in: directory)
        guard let available = try availableCapacity(directory) else { return }
        let required = option.expectedBytes + downloadReserveBytes
        guard available >= required else {
            throw GGUFDownloadError.insufficientSpace(required: required, available: available)
        }
    }

    nonisolated static let downloadReserveBytes: Int64 = 512 * 1024 * 1024
}

@MainActor
final class GGUFDownloadManager: NSObject, ObservableObject {
    static let shared = GGUFDownloadManager()
    nonisolated static let backgroundIdentifier = "ShaydeTree.Writers-Block.model-downloads"
    nonisolated private static let progressUpdateBytes: Int64 = 1024 * 1024
    nonisolated private static let verificationBufferBytes = 8 * 1024 * 1024

    @Published private(set) var installedModelFiles: Set<String> = []
    @Published private(set) var activeDownloadID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedModelFileName = GGUFModelSelection.currentFileName
    @Published private(set) var engineChoice = GGUFEngineChoice.current
    @Published private(set) var isRestoringDownloads = true
    @Published private(set) var isPausing = false
    @Published private(set) var isVerifying = false
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var progressSampleTime = Date()
    private var progressSampleBytes: Int64 = 0

    override init() {
        super.init()
        let configuration = Self.downloadConfiguration()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        refreshInstalledModels()
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                if let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first(where: {
                    GGUFDownloadCatalog.option(id: $0.taskDescription) != nil &&
                    $0.state != .completed && $0.state != .canceling
                }), let option = GGUFDownloadCatalog.option(id: task.taskDescription) {
                    self.activeTask = task
                    self.beginDownload(option: option, receivedBytes: max(0, task.countOfBytesReceived))
                    task.resume()
                }
                self.isRestoringDownloads = false
            }
        }
    }

    nonisolated static func downloadConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return configuration
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
        guard activeTask == nil, !isRestoringDownloads, !isPausing, !isVerifying else { return }
        refreshInstalledModels()
        if installedModelFiles.contains(option.fileName) {
            select(option)
            statusMessage = "\(option.title) is ready to use."
            return
        }

        do {
            let directory = try GGUFModelStorage.modelsDirectory(create: true)
            let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
            if let size = try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) == option.expectedBytes {
                beginDownload(option: option, receivedBytes: option.expectedBytes)
                setVerifying(optionID: option.id)
                Task {
                    do {
                        try await Task.detached {
                            try Self.installDownload(from: stagingURL, in: directory, option: option)
                        }.value
                        finish(option: option)
                    } catch {
                        isVerifying = false
                        activeDownloadID = nil
                        statusMessage = nil
                        errorMessage = "Could not recover \(option.title): \(error.localizedDescription)"
                    }
                }
                return
            }
            try removeLegacyDownloadArtifacts(in: directory, for: option)
            try GGUFModelStorage.prepareSpace(for: option, in: directory) { directory in
                try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }
            let resumeURL = resumeDataURL(for: option, directory: directory)
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: ggufDownloadRequest(for: option))
            }
            task.taskDescription = option.id
            task.priority = URLSessionTask.highPriority
            activeTask = task
            beginDownload(option: option, receivedBytes: 0)
            task.resume()
        } catch {
            errorMessage = "Could not start \(option.title): \(error.localizedDescription)"
        }
    }

    func pauseDownload() {
        guard !isPausing, !isVerifying, let task = activeTask,
              let option = GGUFDownloadCatalog.option(id: task.taskDescription),
              let directory = try? GGUFModelStorage.modelsDirectory(create: true) else {
            return
        }
        isPausing = true
        statusMessage = "Pausing download…"
        let resumeURL = resumeDataURL(for: option, directory: directory)
        task.cancel { [weak self] resumeData in
            let saved = resumeData.map { data in
                (try? data.write(to: resumeURL, options: .atomic)) != nil
            } ?? false
            Task { @MainActor in
                guard let self else { return }
                self.activeTask = nil
                self.activeDownloadID = nil
                self.isPausing = false
                self.statusMessage = saved
                    ? "Download paused. Tap Download to resume."
                    : "Download stopped. Tap Download to restart."
            }
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

    func selectCustom(_ model: GGUFCustomModel) -> Bool {
        guard activeDownloadID == nil, !isRestoringDownloads, !isVerifying else { return false }
        do {
            let url = try GGUFModelStorage.modelsDirectory(create: false).appendingPathComponent(model.fileName)
            try GGUFModelCatalog.validateCustomFile(at: url)
            GGUFModelSelection.save(fileName: model.fileName)
            GGUFEngineChoice.gemma.save()
            selectedModelFileName = model.fileName
            engineChoice = .gemma
            statusMessage = "\(model.displayName) selected."
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not select the custom model: \(error.localizedDescription)"
            return false
        }
    }

    func importCustomModel(from sourceURL: URL) async -> Bool {
        guard activeDownloadID == nil, !isRestoringDownloads, !isVerifying else { return false }
        isVerifying = true
        statusMessage = "Importing \(sourceURL.lastPathComponent)…"
        errorMessage = nil
        do {
            let task = Task.detached(priority: .userInitiated) {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                try GGUFModelCatalog.validateCustomFile(at: sourceURL)
                let directory = try GGUFModelStorage.modelsDirectory(create: true)
                let fileName = "custom-\(UUID().uuidString).gguf"
                let destination = directory.appendingPathComponent(fileName)
                let staging = directory.appendingPathComponent("\(fileName).import")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: sourceURL, to: staging)
                try Task.checkCancellation()
                try GGUFModelCatalog.validateCustomFile(at: staging)
                try FileManager.default.moveItem(at: staging, to: destination)
                return GGUFCustomModel(id: fileName, displayName: sourceURL.deletingPathExtension().lastPathComponent, fileName: fileName)
            }
            let model = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            GGUFCustomModelRegistry.register(model)
            isVerifying = false
            refreshInstalledModels()
            return selectCustom(model)
        } catch is CancellationError {
            isVerifying = false
            statusMessage = nil
            return false
        } catch {
            isVerifying = false
            statusMessage = nil
            errorMessage = "Could not import the model: \(error.localizedDescription)"
            return false
        }
    }

    func selectEngine(_ choice: GGUFEngineChoice) {
        choice.save()
        engineChoice = choice
        if choice == .appleIntelligence { Task { await AIService.unloadGGUFRunner() } }
    }

    private func beginDownload(option: GGUFDownloadOption, receivedBytes: Int64) {
        activeDownloadID = option.id
        progressSampleTime = Date()
        progressSampleBytes = receivedBytes
        self.receivedBytes = receivedBytes
        progress = min(1, Double(receivedBytes) / Double(option.expectedBytes))
        statusMessage = "Downloading \(option.title)… \(Int(progress * 100))%"
        errorMessage = nil
    }

    private func resumeDataURL(for option: GGUFDownloadOption, directory: URL) -> URL {
        GGUFModelStorage.resumeDataURL(for: option, in: directory)
    }

    private func removeLegacyDownloadArtifacts(in directory: URL, for option: GGUFDownloadOption) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents where isLegacyGGUFDownloadArtifact(fileName: url.lastPathComponent) &&
            (url.lastPathComponent == "\(option.fileName).download" ||
             url.lastPathComponent.hasPrefix("\(option.id).segment-")) {
            try FileManager.default.removeItem(at: url)
        }
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
        let elapsed = Date().timeIntervalSince(progressSampleTime)
        let speed = elapsed >= 1
            ? Int64(Double(max(0, bytes - progressSampleBytes)) / elapsed)
            : 0
        let transfer = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let rate = speed > 0 ? " · " + ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s" : ""
        statusMessage = "Downloading \(option.title)… \(Int(progress * 100))% · \(transfer)\(rate)"
    }

    private func finish(option: GGUFDownloadOption) {
        activeTask = nil
        activeDownloadID = nil
        isVerifying = false
        progress = 1
        receivedBytes = option.expectedBytes
        refreshInstalledModels()
        select(option)
        statusMessage = "\(option.title) downloaded and selected."
    }

    private func fail(taskIdentifier: Int, option: GGUFDownloadOption?, error: Error) {
        guard activeTask?.taskIdentifier == taskIdentifier, !isPausing else { return }
        activeTask = nil
        activeDownloadID = nil
        isVerifying = false
        statusMessage = nil
        errorMessage = "Download failed\(option.map { " for \($0.title)" } ?? ""): \(error.localizedDescription)"
    }

    private func setVerifying(optionID: String?) {
        guard activeDownloadID == optionID,
              let option = GGUFDownloadCatalog.option(id: optionID) else {
            return
        }
        progress = 1
        isVerifying = true
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
        guard totalBytesWritten / Self.progressUpdateBytes !=
                (totalBytesWritten - bytesWritten) / Self.progressUpdateBytes ||
                totalBytesWritten == totalBytesExpectedToWrite else { return }
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
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            try Self.installDownload(from: stagingURL, in: directory, option: option)
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
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let option = GGUFDownloadCatalog.option(id: task.taskDescription)
        if let option,
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let directory = try? GGUFModelStorage.modelsDirectory(create: true) {
            try? resumeData.write(
                to: GGUFModelStorage.resumeDataURL(for: option, in: directory),
                options: .atomic
            )
        }
        Task { @MainActor [weak self] in
            self?.fail(taskIdentifier: task.taskIdentifier, option: option, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let completion = self?.backgroundCompletionHandler
            self?.backgroundCompletionHandler = nil
            completion?()
        }
    }

    nonisolated static func installDownload(
        from stagingURL: URL,
        in directory: URL,
        option: GGUFDownloadOption
    ) throws {
        let resumeURL = GGUFModelStorage.resumeDataURL(for: option, in: directory)
        do {
            try validateDownload(at: stagingURL, option: option)
        } catch let error as GGUFDownloadError {
            // Invalid bytes cannot be recovered or resumed. Keep valid staging
            // files on filesystem failures so a later retry need not download again.
            switch error {
            case .invalidFormat, .checksumMismatch, .incomplete:
                try FileManager.default.removeItem(at: stagingURL)
                if FileManager.default.fileExists(atPath: resumeURL.path) {
                    try FileManager.default.removeItem(at: resumeURL)
                }
            default:
                break
            }
            throw error
        }
        var excludedStagingURL = stagingURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedStagingURL.setResourceValues(values)
        let destinationURL = directory.appendingPathComponent(option.fileName)
        // Staging and destination share a directory. rename publishes atomically,
        // preserving both the old model and staging if replacement fails.
        guard Darwin.rename(stagingURL.path, destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: resumeURL)
    }

    nonisolated static func validateDownload(at url: URL, option: GGUFDownloadOption) throws {
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
