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

struct GGUFDownloadSegment: Equatable, Sendable {
    let start: Int64
    let endInclusive: Int64

    nonisolated var length: Int64 {
        endInclusive - start + 1
    }
}

private struct GGUFSegmentTask: Sendable {
    let optionID: String
    let index: Int
    let segment: GGUFDownloadSegment
}

nonisolated func ggufDownloadSegments(
    expectedBytes: Int64,
    connectionCount: Int = 4
) -> [GGUFDownloadSegment] {
    precondition(expectedBytes > 0)
    let count = min(max(connectionCount, 1), Int(expectedBytes))
    let segmentBytes = (expectedBytes + Int64(count) - 1) / Int64(count)
    return (0..<count).map { index in
        let start = Int64(index) * segmentBytes
        return GGUFDownloadSegment(
            start: start,
            endInclusive: min(expectedBytes - 1, start + segmentBytes - 1)
        )
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
    nonisolated private static let downloadConnectionCount = 4
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
    private var activeSegmentTasks: [Int: URLSessionDownloadTask] = [:]
    private var segmentProgress: [Int: Int64] = [:]
    private var completedSegmentBytes: Int64 = 0

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = Self.downloadConnectionCount
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
        guard activeDownloadID == nil, activeTask == nil, activeSegmentTasks.isEmpty else { return }
        refreshInstalledModels()
        if installedModelFiles.contains(option.fileName) {
            select(option)
            statusMessage = "\(option.title) is ready to use."
            return
        }

        do {
            let directory = try GGUFModelStorage.modelsDirectory(create: true)
            let resumeURL = resumeDataURL(for: option, directory: directory)
            if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                try verifyFreeSpace(for: option, in: directory)
                let task = session.downloadTask(withResumeData: resumeData)
                task.taskDescription = option.id
                activeTask = task
                beginDownload(option: option, receivedBytes: 0)
                task.resume()
            } else {
                try startSegmentedDownload(option, directory: directory)
            }
        } catch {
            errorMessage = "Could not start \(option.title): \(error.localizedDescription)"
        }
    }

    func pauseDownload() {
        guard let directory = try? GGUFModelStorage.modelsDirectory(create: true) else {
            return
        }

        if let task = activeTask,
           let option = GGUFDownloadCatalog.option(id: task.taskDescription) {
            activeTask = nil
            activeDownloadID = nil
            statusMessage = "Download paused. Tap Download to resume."
            let resumeURL = resumeDataURL(for: option, directory: directory)
            task.cancel { resumeData in
                guard let resumeData else { return }
                try? resumeData.write(to: resumeURL, options: .atomic)
            }
            return
        }

        guard !activeSegmentTasks.isEmpty else { return }
        let tasks = Array(activeSegmentTasks.values)
        activeSegmentTasks.removeAll()
        segmentProgress.removeAll()
        activeDownloadID = nil
        statusMessage = "Download paused. Tap Download to resume."
        tasks.forEach { task in
            guard let segmentTask = Self.segmentTask(from: task.taskDescription) else {
                task.cancel()
                return
            }
            task.cancel { resumeData in
                guard let resumeData else { return }
                try? resumeData.write(
                    to: Self.segmentResumeURL(
                        optionID: segmentTask.optionID,
                        segmentIndex: segmentTask.index,
                        directory: directory
                    ),
                    options: .atomic
                )
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

    func selectEngine(_ choice: GGUFEngineChoice) {
        choice.save()
        engineChoice = choice
    }

    private func startSegmentedDownload(
        _ option: GGUFDownloadOption,
        directory: URL
    ) throws {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(option.fileName).download")
        )
        let segments = ggufDownloadSegments(
            expectedBytes: option.expectedBytes,
            connectionCount: Self.downloadConnectionCount
        )
        var completedBytes: Int64 = 0
        var pending: [(Int, GGUFDownloadSegment)] = []

        for (index, segment) in segments.enumerated() {
            let partURL = Self.segmentPartURL(
                optionID: option.id,
                segmentIndex: index,
                directory: directory
            )
            if Self.fileSize(at: partURL) == segment.length {
                completedBytes += segment.length
            } else {
                try? FileManager.default.removeItem(at: partURL)
                pending.append((index, segment))
            }
        }

        try verifyFreeSpace(
            for: option,
            in: directory,
            completedBytes: completedBytes,
            largestSegmentBytes: segments.map(\.length).max() ?? 0
        )
        beginDownload(option: option, receivedBytes: completedBytes)
        completedSegmentBytes = completedBytes
        segmentProgress.removeAll()

        for (index, segment) in pending {
            let resumeURL = Self.segmentResumeURL(
                optionID: option.id,
                segmentIndex: index,
                directory: directory
            )
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: option.url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue(
                    "bytes=\(segment.start)-\(segment.endInclusive)",
                    forHTTPHeaderField: "Range"
                )
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session.downloadTask(with: request)
            }
            task.taskDescription = Self.segmentTaskDescription(
                optionID: option.id,
                index: index,
                segment: segment
            )
            activeSegmentTasks[task.taskIdentifier] = task
            segmentProgress[task.taskIdentifier] = 0
        }

        if activeSegmentTasks.isEmpty {
            beginSegmentFinalization(option: option, directory: directory)
        } else {
            activeSegmentTasks.values.forEach { $0.resume() }
        }
    }

    private func beginDownload(option: GGUFDownloadOption, receivedBytes: Int64) {
        activeDownloadID = option.id
        self.receivedBytes = receivedBytes
        progress = min(1, Double(receivedBytes) / Double(option.expectedBytes))
        statusMessage = "Downloading \(option.title)… \(Int(progress * 100))%"
        errorMessage = nil
    }

    private func verifyFreeSpace(
        for option: GGUFDownloadOption,
        in directory: URL,
        completedBytes: Int64 = 0,
        largestSegmentBytes: Int64 = 0
    ) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let reserve: Int64 = 512 * 1024 * 1024
        let required = option.expectedBytes - completedBytes + largestSegmentBytes + reserve
        guard available >= required else {
            throw GGUFDownloadError.insufficientSpace(required: required, available: available)
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

    private func receiveSegmentProgress(
        taskIdentifier: Int,
        segmentTask: GGUFSegmentTask,
        bytes: Int64
    ) {
        guard activeDownloadID == segmentTask.optionID,
              activeSegmentTasks[taskIdentifier] != nil else {
            return
        }
        segmentProgress[taskIdentifier] = min(bytes, segmentTask.segment.length)
        receiveProgress(
            optionID: segmentTask.optionID,
            bytes: completedSegmentBytes + segmentProgress.values.reduce(0, +)
        )
    }

    private func segmentFinished(
        taskIdentifier: Int,
        segmentTask: GGUFSegmentTask,
        option: GGUFDownloadOption,
        directory: URL
    ) {
        guard activeDownloadID == option.id,
              activeSegmentTasks.removeValue(forKey: taskIdentifier) != nil else {
            return
        }
        segmentProgress.removeValue(forKey: taskIdentifier)
        completedSegmentBytes += segmentTask.segment.length
        try? FileManager.default.removeItem(
            at: Self.segmentResumeURL(
                optionID: option.id,
                segmentIndex: segmentTask.index,
                directory: directory
            )
        )
        receiveProgress(optionID: option.id, bytes: completedSegmentBytes)
        if activeSegmentTasks.isEmpty {
            beginSegmentFinalization(option: option, directory: directory)
        }
    }

    private func beginSegmentFinalization(option: GGUFDownloadOption, directory: URL) {
        setVerifying(optionID: option.id)
        Task.detached(priority: .utility) { [weak self] in
            do {
                try Self.assembleSegments(option: option, directory: directory)
                await self?.finishSegmented(option: option)
            } catch {
                await self?.failSegmented(option: option, error: error)
            }
        }
    }

    private func finishSegmented(option: GGUFDownloadOption) {
        guard activeDownloadID == option.id else { return }
        finish(option: option)
    }

    private func finish(option: GGUFDownloadOption) {
        activeTask = nil
        activeSegmentTasks.removeAll()
        segmentProgress.removeAll()
        completedSegmentBytes = 0
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

    private func failSegmented(option: GGUFDownloadOption?, error: Error) {
        guard activeDownloadID == option?.id else { return }
        let tasks = Array(activeSegmentTasks.values)
        activeSegmentTasks.removeAll()
        segmentProgress.removeAll()
        completedSegmentBytes = 0
        activeDownloadID = nil
        statusMessage = nil
        errorMessage = "Download failed\(option.map { " for \($0.title)" } ?? ""): \(error.localizedDescription)"

        guard let directory = try? GGUFModelStorage.modelsDirectory(create: true) else {
            tasks.forEach { $0.cancel() }
            return
        }
        tasks.forEach { task in
            guard let segmentTask = Self.segmentTask(from: task.taskDescription) else {
                task.cancel()
                return
            }
            task.cancel { resumeData in
                guard let resumeData else { return }
                try? resumeData.write(
                    to: Self.segmentResumeURL(
                        optionID: segmentTask.optionID,
                        segmentIndex: segmentTask.index,
                        directory: directory
                    ),
                    options: .atomic
                )
            }
        }
    }

    private func setVerifying(optionID: String?) {
        guard activeDownloadID == optionID,
              let option = GGUFDownloadCatalog.option(id: optionID) else {
            return
        }
        progress = 1
        statusMessage = "Verifying \(option.title)…"
    }

    nonisolated private static func segmentTaskDescription(
        optionID: String,
        index: Int,
        segment: GGUFDownloadSegment
    ) -> String {
        "segment|\(optionID)|\(index)|\(segment.start)|\(segment.endInclusive)"
    }

    nonisolated private static func segmentTask(from description: String?) -> GGUFSegmentTask? {
        guard let description else { return nil }
        let fields = description.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0] == "segment",
              let index = Int(fields[2]),
              let start = Int64(fields[3]),
              let endInclusive = Int64(fields[4]) else {
            return nil
        }
        return GGUFSegmentTask(
            optionID: String(fields[1]),
            index: index,
            segment: GGUFDownloadSegment(start: start, endInclusive: endInclusive)
        )
    }

    nonisolated private static func segmentPartURL(
        optionID: String,
        segmentIndex: Int,
        directory: URL
    ) -> URL {
        directory.appendingPathComponent("\(optionID).segment-\(segmentIndex).part")
    }

    nonisolated private static func segmentResumeURL(
        optionID: String,
        segmentIndex: Int,
        directory: URL
    ) -> URL {
        directory.appendingPathComponent("\(optionID).segment-\(segmentIndex).resume")
    }

    nonisolated private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
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
        if let segmentTask = Self.segmentTask(from: downloadTask.taskDescription) {
            Task { @MainActor [weak self] in
                self?.receiveSegmentProgress(
                    taskIdentifier: downloadTask.taskIdentifier,
                    segmentTask: segmentTask,
                    bytes: totalBytesWritten
                )
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.receiveProgress(optionID: downloadTask.taskDescription, bytes: totalBytesWritten)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let segmentTask = Self.segmentTask(from: downloadTask.taskDescription) {
            guard let option = GGUFDownloadCatalog.option(id: segmentTask.optionID) else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse else {
                    throw GGUFDownloadError.invalidResponse
                }
                guard (200...299).contains(response.statusCode) else {
                    throw GGUFDownloadError.httpStatus(response.statusCode)
                }
                guard response.statusCode == 206 else {
                    throw GGUFDownloadError.rangeUnsupported(response.statusCode)
                }
                let expectedRangePrefix = "bytes \(segmentTask.segment.start)-"
                guard response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix(expectedRangePrefix) == true else {
                    throw GGUFDownloadError.unexpectedRange
                }

                let directory = try GGUFModelStorage.modelsDirectory(create: true)
                let partURL = Self.segmentPartURL(
                    optionID: option.id,
                    segmentIndex: segmentTask.index,
                    directory: directory
                )
                try? FileManager.default.removeItem(at: partURL)
                try FileManager.default.moveItem(at: location, to: partURL)
                let actualBytes = Self.fileSize(at: partURL) ?? 0
                guard actualBytes == segmentTask.segment.length else {
                    throw GGUFDownloadError.incomplete(
                        expected: segmentTask.segment.length,
                        actual: actualBytes
                    )
                }
                Task { @MainActor [weak self] in
                    self?.segmentFinished(
                        taskIdentifier: downloadTask.taskIdentifier,
                        segmentTask: segmentTask,
                        option: option,
                        directory: directory
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.failSegmented(option: option, error: error)
                }
            }
            return
        }

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
        if let segmentTask = Self.segmentTask(from: task.taskDescription) {
            let option = GGUFDownloadCatalog.option(id: segmentTask.optionID)
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let directory = try? GGUFModelStorage.modelsDirectory(create: true) {
                try? resumeData.write(
                    to: Self.segmentResumeURL(
                        optionID: segmentTask.optionID,
                        segmentIndex: segmentTask.index,
                        directory: directory
                    ),
                    options: .atomic
                )
            }
            Task { @MainActor [weak self] in
                self?.failSegmented(option: option, error: error)
            }
            return
        }

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

    nonisolated private static func assembleSegments(
        option: GGUFDownloadOption,
        directory: URL
    ) throws {
        let segments = ggufDownloadSegments(
            expectedBytes: option.expectedBytes,
            connectionCount: downloadConnectionCount
        )
        let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
        let destinationURL = directory.appendingPathComponent(option.fileName)
        try? FileManager.default.removeItem(at: stagingURL)
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
            throw GGUFDownloadError.couldNotCreateStagingFile
        }

        var output: FileHandle?
        do {
            let outputHandle = try FileHandle(forWritingTo: stagingURL)
            output = outputHandle
            for (index, segment) in segments.enumerated() {
                let partURL = segmentPartURL(
                    optionID: option.id,
                    segmentIndex: index,
                    directory: directory
                )
                guard fileSize(at: partURL) == segment.length else {
                    throw GGUFDownloadError.incomplete(
                        expected: segment.length,
                        actual: fileSize(at: partURL) ?? 0
                    )
                }
                let input = try FileHandle(forReadingFrom: partURL)
                do {
                    while let chunk = try input.read(upToCount: verificationBufferBytes), !chunk.isEmpty {
                        try outputHandle.write(contentsOf: chunk)
                    }
                    try input.close()
                } catch {
                    try? input.close()
                    throw error
                }
                try FileManager.default.removeItem(at: partURL)
            }
            try outputHandle.synchronize()
            try outputHandle.close()
            output = nil
        } catch {
            try? output?.close()
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        try validateDownload(at: stagingURL, option: option)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(option.fileName).resume")
        )
        for index in segments.indices {
            try? FileManager.default.removeItem(
                at: segmentResumeURL(
                    optionID: option.id,
                    segmentIndex: index,
                    directory: directory
                )
            )
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
    case invalidResponse
    case httpStatus(Int)
    case rangeUnsupported(Int)
    case unexpectedRange
    case incomplete(expected: Int64, actual: Int64)
    case couldNotCreateStagingFile
    case invalidFormat
    case checksumMismatch
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "the server returned an invalid response"
        case .httpStatus(let status):
            return "the server returned HTTP \(status)"
        case .rangeUnsupported(let status):
            return "the server did not honor a ranged download request (HTTP \(status))"
        case .unexpectedRange:
            return "the server returned an unexpected byte range"
        case .incomplete(let expected, let actual):
            return "the file was incomplete: \(Self.format(actual)) of \(Self.format(expected))"
        case .couldNotCreateStagingFile:
            return "the model staging file could not be created"
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
