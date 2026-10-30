import Combine
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
    // - E2B: v6, trained 2026-10-14 on teacher-data v6 (Gemma 4 31B teacher, current app
    //   prompts). Same file name, byte size and embedded chat template as v2.1, so only the
    //   SHA-256 (and the verified-artifact marker below) tells the versions apart.
    // - E4B: v2.1, trained 2026-10-06 on teacher-data-v2 plus the shipped rewrite/synonym rows.
    nonisolated static let huggingFaceRevision = "990bc8e01700f05d0cea805a66b43a7424a4b36b"

    nonisolated static let options: [GGUFDownloadOption] = [
        GGUFDownloadOption(
            id: "gemma-4-e2b",
            title: "RhymeAI Gemma 4 E2B",
            subtitle: "Recommended for iPhone and iPad",
            size: "3.43 GB",
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 3_427_880_800,
            sha256: "902e5d83a86393f064b1c8abc1a9d25fec5b3634683317792b02856c01c604e0",
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
            expectedBytes: 5_335_292_800,
            sha256: "6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944",
            url: requiredURL(
                "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/\(huggingFaceRevision)/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true"
            ),
            isRecommended: false
        ),
    ]

    nonisolated static func option(id: String?) -> GGUFDownloadOption? {
        options.first { $0.id == id }
    }

    /// Mirrors Android `RAM_THRESHOLD_E4B_BYTES` and `gemmaModelNeedsMoreMemory`: only E4B
    /// needs more than the app's minimum, and it thrashes on an 8 GB device.
    nonisolated static let ramThresholdE4BBytes: UInt64 = 10 * 1024 * 1024 * 1024
    nonisolated static let needsMoreMemoryMessage = "May be slow on this device — needs more memory"

    nonisolated static func needsMoreMemory(_ option: GGUFDownloadOption, totalRAMBytes: UInt64) -> Bool {
        option.fileName == options[1].fileName && totalRAMBytes < ramThresholdE4BBytes
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

/// The catalog artifact (SHA-256) an installed file was last verified as, plus the file
/// identity at that moment. Model versions that share a name and byte size are told apart
/// by this marker, so launch-time checks never re-hash gigabytes.
nonisolated struct GGUFVerifiedArtifact: Codable, Equatable, Sendable {
    let sha256: String
    let size: Int64
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(sha256: String, identity: GGUFModelFileIdentity) {
        self.sha256 = sha256
        size = identity.size
        device = identity.device
        inode = identity.inode
        modifiedSeconds = identity.modifiedSeconds
        modifiedNanoseconds = identity.modifiedNanoseconds
    }

    /// True when this marker was written for exactly the file now on disk.
    func describes(_ identity: GGUFModelFileIdentity) -> Bool {
        self == GGUFVerifiedArtifact(sha256: sha256, identity: identity)
    }
}

nonisolated enum GGUFVerifiedArtifactStore {
    private static let key = "verifiedGGUFArtifacts"
    private static let lock = NSLock()

    static func marker(fileName: String, defaults: UserDefaults = .standard) -> GGUFVerifiedArtifact? {
        lock.withLock { load(defaults)[fileName] }
    }

    /// Records that the file at `url` was just verified as `sha256`.
    static func record(sha256: String, at url: URL, defaults: UserDefaults = .standard) {
        guard let identity = try? GGUFModelFileIdentity.read(at: url.path) else { return }
        update(defaults) { $0[url.lastPathComponent] = GGUFVerifiedArtifact(sha256: sha256, identity: identity) }
    }

    static func remove(fileName: String, defaults: UserDefaults = .standard) {
        update(defaults) { $0[fileName] = nil }
    }

    private static func update(_ defaults: UserDefaults, _ body: (inout [String: GGUFVerifiedArtifact]) -> Void) {
        lock.withLock {
            var markers = load(defaults)
            body(&markers)
            if let data = try? JSONEncoder().encode(markers) { defaults.set(data, forKey: key) }
        }
    }

    private static func load(_ defaults: UserDefaults) -> [String: GGUFVerifiedArtifact] {
        guard let data = defaults.data(forKey: key),
              let markers = try? JSONDecoder().decode([String: GGUFVerifiedArtifact].self, from: data) else {
            return [:]
        }
        return markers
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

    /// A catalog file counts as installed only when a verified-artifact marker records the
    /// current catalog SHA-256 for exactly this file (same size, inode and modification
    /// time). A previous model version under the same name — even one of identical size —
    /// is therefore offered for download, which first verifies or reclaims it. The check
    /// reads metadata only; hashing happens at install, at model load, and on that download.
    nonisolated static func installedModelFileNames(
        in directory: URL,
        defaults: UserDefaults = .standard
    ) -> [String] {
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
                return isVerifiedInstall(of: option, at: url, defaults: defaults)
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    nonisolated static func isVerifiedInstall(
        of option: GGUFDownloadOption,
        at url: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let identity = try? GGUFModelFileIdentity.read(at: url.path),
              identity.size == option.expectedBytes,
              let marker = GGUFVerifiedArtifactStore.marker(fileName: option.fileName, defaults: defaults) else {
            return false
        }
        return marker.sha256 == option.sha256 && marker.describes(identity)
    }

    /// An installed file of the catalog size that carries no current marker: it may be the
    /// current artifact (installed before markers existed) or a same-size previous version.
    nonisolated static func needsInstalledVerification(
        for option: GGUFDownloadOption,
        in directory: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let url = directory.appendingPathComponent(option.fileName)
        guard let identity = try? GGUFModelFileIdentity.read(at: url.path),
              identity.size == option.expectedBytes else {
            return false
        }
        return !isVerifiedInstall(of: option, at: url, defaults: defaults)
    }

    /// Hashes an unmarked installed file once. A match records the marker and returns true;
    /// a mismatch (for example the previous same-size version) deletes it and returns false.
    nonisolated static func verifyOrReclaimInstalled(
        _ option: GGUFDownloadOption,
        in directory: URL,
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        let url = directory.appendingPathComponent(option.fileName)
        do {
            try GGUFDownloadManager.validateDownload(at: url, option: option)
        } catch let error as GGUFDownloadError {
            switch error {
            case .invalidFormat, .checksumMismatch, .incomplete:
                try FileManager.default.removeItem(at: url)
                GGUFVerifiedArtifactStore.remove(fileName: option.fileName, defaults: defaults)
                return false
            default:
                throw error
            }
        }
        GGUFVerifiedArtifactStore.record(sha256: option.sha256, at: url, defaults: defaults)
        return true
    }

    /// Resume data is keyed by the artifact SHA-256, so a paused download of a previous
    /// model version is never resumed into the current catalog entry.
    nonisolated static func resumeDataURL(for option: GGUFDownloadOption, in directory: URL) -> URL {
        directory.appendingPathComponent("\(option.fileName).\(option.sha256.prefix(16)).resume")
    }

    /// Removes what a previous version of `option` left under the same name: an installed
    /// file whose size no longer matches the catalog entry, or whose marker records another
    /// artifact's SHA-256 (neither can pass load-time validation), and resume data keyed to
    /// another artifact. Returns the bytes freed.
    @discardableResult
    nonisolated static func removeStaleArtifacts(
        for option: GGUFDownloadOption,
        in directory: URL,
        defaults: UserDefaults = .standard
    ) throws -> Int64 {
        let fileManager = FileManager.default
        var freedBytes: Int64 = 0
        let installedURL = directory.appendingPathComponent(option.fileName)
        if let identity = try? GGUFModelFileIdentity.read(at: installedURL.path) {
            let marker = GGUFVerifiedArtifactStore.marker(fileName: option.fileName, defaults: defaults)
            let markedAsOtherArtifact = marker.map { $0.describes(identity) && $0.sha256 != option.sha256 } ?? false
            if identity.size != option.expectedBytes || markedAsOtherArtifact {
                try fileManager.removeItem(at: installedURL)
                GGUFVerifiedArtifactStore.remove(fileName: option.fileName, defaults: defaults)
                freedBytes += identity.size
            }
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

    /// Removes what `option` left in `directory`: the installed file whatever its size or
    /// marker (a previous version is deletable too) together with its verified marker, then
    /// `<file>.download` staging, every `<file>.*.resume` blob and the legacy segment parts.
    /// Nothing else under a similar name is touched.
    nonisolated static func removeArtifacts(
        for option: GGUFDownloadOption,
        in directory: URL,
        defaults: UserDefaults = .standard
    ) throws {
        let fileManager = FileManager.default
        let installedURL = directory.appendingPathComponent(option.fileName)
        if isRegularFile(installedURL) {
            try fileManager.removeItem(at: installedURL)
        }
        GGUFVerifiedArtifactStore.remove(fileName: option.fileName, defaults: defaults)
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        where isDownloadArtifactName(url.lastPathComponent, of: option) && isRegularFile(url) {
            try fileManager.removeItem(at: url)
        }
    }

    /// A directory or anything else under a model's name is never counted or removed.
    nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Exactly the names the downloader writes for `option`: `<file>.download` staging,
    /// `<file>.resume` (pre-keyed) or `<file>.<16 hex>.resume` blobs, and the removed
    /// segmented downloader's `<id>.segment-<n>.part|.resume`.
    nonisolated static func isDownloadArtifactName(_ name: String, of option: GGUFDownloadOption) -> Bool {
        if name == "\(option.fileName).download" || name == "\(option.fileName).resume" { return true }
        let resumeHead = "\(option.fileName)."
        if name.hasPrefix(resumeHead), name.hasSuffix(".resume") {
            let key = name.dropFirst(resumeHead.count).dropLast(".resume".count)
            return key.count == 16 && key.allSatisfy(\.isHexDigit)
        }
        let segmentHead = "\(option.id).segment-"
        if name.hasPrefix(segmentHead) {
            for suffix in [".part", ".resume"] where name.hasSuffix(suffix) {
                let index = name.dropFirst(segmentHead.count).dropLast(suffix.count)
                return !index.isEmpty && index.allSatisfy(\.isNumber)
            }
        }
        return false
    }

    /// Reclaims stale artifacts first, then requires room for the rest of the download
    /// plus a reserve, so a device that only has room once the previous version is gone
    /// can upgrade and a paused download can resume into the space it already holds.
    nonisolated static func prepareSpace(
        for option: GGUFDownloadOption,
        in directory: URL,
        defaults: UserDefaults = .standard,
        availableCapacity: (URL) throws -> Int64?
    ) throws {
        try removeStaleArtifacts(for: option, in: directory, defaults: defaults)
        guard let available = try availableCapacity(directory) else { return }
        let required = option.expectedBytes - resumedBytes(for: option, in: directory) + downloadReserveBytes
        guard available >= required else {
            throw GGUFDownloadError.insufficientSpace(required: required, available: available)
        }
    }

    nonisolated static let downloadReserveBytes: Int64 = 512 * 1024 * 1024

    /// Bytes a saved resume blob lets URLSession skip; its partial file already
    /// occupies them on the volume. Zero when there is no readable blob.
    nonisolated static func resumedBytes(for option: GGUFDownloadOption, in directory: URL) -> Int64 {
        guard let data = try? Data(contentsOf: resumeDataURL(for: option, in: directory)) else { return 0 }
        return min(max(0, receivedBytes(inResumeData: data)), option.expectedBytes)
    }

    /// `NSURLSessionResumeBytesReceived` from URLSession resume data. Current systems write a
    /// keyed archive whose root dictionary sits under the literal key
    /// "NSKeyedArchiveRootObjectKey" (checked against a real blob on macOS 27); older ones wrote
    /// the dictionary as a plain property list. Anything else reads as 0.
    nonisolated static func receivedBytes(inResumeData data: Data) -> Int64 {
        var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        if info?["$archiver"] != nil, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            info = ["NSKeyedArchiveRootObjectKey", NSKeyedArchiveRootObjectKey].lazy
                .compactMap { unarchiver.decodeObject(forKey: $0) as? [String: Any] }
                .first
        }
        return (info?["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value ?? 0
    }
}

@MainActor
final class GGUFDownloadManager: NSObject, ObservableObject {
    static let shared = GGUFDownloadManager()
    nonisolated static let backgroundIdentifier = "ShaydeTree.Writers-Block.model-downloads"
    nonisolated private static let progressUpdateBytes: Int64 = 1024 * 1024

    @Published private(set) var installedModelFiles: Set<String> = []
    /// Bytes on disk under each catalog file name: a verified install or a same-name file
    /// that fails the size or marker check (a previous version), either of which Delete removes.
    @Published private(set) var catalogBytesOnDisk: [String: Int64] = [:]
    /// Set while `delete` runs; starts, choices and imports wait for it.
    @Published private(set) var deletingModelFileName: String?
    /// Entries deleted since their last download began, kept in the defaults so they
    /// survive a relaunch. A completion or error the system delivers for one of them after
    /// the delete (a background download that finished while the app was away) is
    /// discarded instead of republishing the model or its resume data; the next download
    /// of that entry beginning lifts it.
    nonisolated private let deletedFileNames: DeletedEntries
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
    /// Bumped by every explicit model or engine choice. A download selects itself on
    /// completion only while the revision it started under is still current (Android
    /// `modelChoiceRevision`); a completion with no live snapshot, such as one restored
    /// after a relaunch, installs the file without selecting it.
    private var modelChoiceRevision = 0
    private var choiceRevisionAtDownloadStart: Int?
    /// Tests give each manager its own models directory and defaults; nil means the
    /// app's `GGUFModelStorage.modelsDirectory`.
    private let modelsRoot: URL?
    nonisolated(unsafe) private let defaults: UserDefaults  // thread-safe per Foundation, not marked Sendable
    private let totalRAMBytes: UInt64
    private var progressSampleTime = Date()
    private var progressSampleBytes: Int64 = 0

    /// Tests pass an ephemeral configuration, a temporary models root and their own
    /// defaults; the app uses the background session, the real directory and `.standard`.
    init(
        configuration: URLSessionConfiguration = GGUFDownloadManager.downloadConfiguration(),
        modelsRoot: URL? = nil,
        defaults: UserDefaults = .standard,
        totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.modelsRoot = modelsRoot
        self.defaults = defaults
        self.totalRAMBytes = totalRAMBytes
        deletedFileNames = DeletedEntries(defaults: defaults)
        super.init()
        selectedModelFileName = GGUFModelSelection.currentFileName(defaults: defaults)
        engineChoice = GGUFEngineChoice.current(defaults: defaults)
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

    nonisolated private func modelsDirectory(create: Bool) throws -> URL {
        guard let modelsRoot else { return try GGUFModelStorage.modelsDirectory(create: create) }
        if create { try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true) }
        return modelsRoot
    }

    func refreshInstalledModels() {
        let directory = try? modelsDirectory(create: false)
        installedModelFiles = Set(directory.map { GGUFModelStorage.installedModelFileNames(in: $0, defaults: defaults) } ?? [])
        catalogBytesOnDisk = Dictionary(uniqueKeysWithValues: GGUFDownloadCatalog.options.compactMap { option in
            guard let url = directory?.appendingPathComponent(option.fileName),
                  GGUFModelStorage.isRegularFile(url),
                  let identity = try? GGUFModelFileIdentity.read(at: url.path) else {
                return nil
            }
            return (option.fileName, identity.size)
        })
        if let preferred = GGUFModelSelection.preferredFileName(
            in: Array(installedModelFiles),
            selectedFileName: GGUFModelSelection.currentFileName(defaults: defaults),
            defaults: defaults,
            totalRAMBytes: totalRAMBytes
        ) {
            selectedModelFileName = preferred
        } else {
            selectedModelFileName = nil
        }
    }

    func start(_ option: GGUFDownloadOption) {
        guard activeTask == nil, !isRestoringDownloads, !isPausing, !isVerifying, deletingModelFileName == nil else { return }
        refreshInstalledModels()
        if installedModelFiles.contains(option.fileName) {
            select(option)
            statusMessage = "\(option.title) is ready to use.\(memoryNote(for: option))"
            return
        }
        choiceRevisionAtDownloadStart = modelChoiceRevision

        do {
            let directory = try modelsDirectory(create: true)
            if GGUFModelStorage.needsInstalledVerification(for: option, in: directory) {
                verifyInstalled(option, in: directory)
                return
            }
            let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
            if let size = try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) == option.expectedBytes {
                beginDownload(option: option, receivedBytes: option.expectedBytes)
                setVerifying(optionID: option.id)
                Task {
                    do {
                        try await Self.installDownloadGated(from: stagingURL, in: directory, option: option, defaults: defaults)
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

    /// Verifies a same-size installed file that carries no current marker. The current
    /// artifact is selected without a download; anything else is reclaimed and downloaded.
    private func verifyInstalled(_ option: GGUFDownloadOption, in directory: URL) {
        beginDownload(option: option, receivedBytes: option.expectedBytes)
        setVerifying(optionID: option.id)
        Task {
            do {
                let verified = try await Task.detached {
                    try GGUFModelStorage.verifyOrReclaimInstalled(option, in: directory)
                }.value
                if verified {
                    let selected = finish(option: option)
                    statusMessage = "\(option.title) verified\(selected ? " and selected" : "").\(memoryNote(for: option))"
                } else {
                    isVerifying = false
                    activeDownloadID = nil
                    statusMessage = nil
                    start(option)
                }
            } catch {
                isVerifying = false
                activeDownloadID = nil
                statusMessage = nil
                errorMessage = "Could not verify \(option.title): \(error.localizedDescription)"
            }
        }
    }

    func pauseDownload() {
        guard !isPausing, !isVerifying, let task = activeTask,
              let option = GGUFDownloadCatalog.option(id: task.taskDescription),
              let directory = try? modelsDirectory(create: true) else {
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
                self.choiceRevisionAtDownloadStart = nil  // a resume takes a fresh snapshot
                self.activeTask = nil
                self.activeDownloadID = nil
                self.isPausing = false
                self.statusMessage = saved
                    ? "Download paused. Tap Download to resume."
                    : "Download stopped. Tap Download to restart."
            }
        }
    }

    /// Removes `option` from this device: its file (verified or a stale same-name version),
    /// staging, resume data and verified marker. Deleting the selected model — shown or
    /// persisted — clears the selection and no other model is taken up in its place. The
    /// removal runs on the runner's serial path, which first releases the model if it is
    /// resident, so a load, a generation or a download publishing the same name (also on
    /// that path) finishes before the file goes.
    func delete(_ option: GGUFDownloadOption) async {
        guard activeDownloadID != option.id, !isRestoringDownloads, !isVerifying, deletingModelFileName == nil else { return }
        deletingModelFileName = option.fileName
        defer { deletingModelFileName = nil }
        // Cleared before the file goes, so a request racing the delete cannot resolve to it.
        // The persisted name can differ from the shown one when a stale file lost its spot.
        let wasSelected = selectedModelFileName == option.fileName
            || GGUFModelSelection.currentFileName(defaults: defaults) == option.fileName
        if wasSelected {
            modelChoiceRevision += 1
            GGUFModelSelection.clearExplicitly(defaults: defaults)
            selectedModelFileName = nil
        }
        do {
            let directory = try modelsDirectory(create: false)
            let defaults = SendableDefaults(value: defaults)
            let deletedFileNames = self.deletedFileNames
            try await AIService.ggufRunner.withExclusiveAccess(toModelFile: option.fileName) {
                try GGUFModelStorage.removeArtifacts(for: option, in: directory, defaults: defaults.value)
                deletedFileNames.insert(option.fileName)
            }
            statusMessage = "\(option.title) deleted."
            errorMessage = nil
        } catch {
            if wasSelected, let directory = try? modelsDirectory(create: false),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(option.fileName).path) {
                GGUFModelSelection.save(fileName: option.fileName, defaults: defaults)
            }
            errorMessage = "Could not delete \(option.title): \(error.localizedDescription)"
        }
        refreshInstalledModels()
    }

    // MARK: - Choice made while a download runs
    //
    /// An explicit choice; completion's own selection goes through `selectInstalled`.
    func select(_ option: GGUFDownloadOption) {
        guard deletingModelFileName == nil else { return }
        modelChoiceRevision += 1
        selectInstalled(option)
    }

    private func selectInstalled(_ option: GGUFDownloadOption) {
        guard installedModelFiles.contains(option.fileName) else { return }
        GGUFModelSelection.save(fileName: option.fileName, defaults: defaults)
        GGUFEngineChoice.gemma.save(defaults: defaults)
        selectedModelFileName = option.fileName
        engineChoice = .gemma
        statusMessage = "\(option.title) selected.\(memoryNote(for: option))"
        errorMessage = nil
    }

    /// Android's warning, word for word; shown with any choice of a model the device is short on memory for.
    private func memoryNote(for option: GGUFDownloadOption) -> String {
        GGUFDownloadCatalog.needsMoreMemory(option, totalRAMBytes: totalRAMBytes)
            ? " \(GGUFDownloadCatalog.needsMoreMemoryMessage)." : ""
    }

    func selectCustom(_ model: GGUFCustomModel) -> Bool {
        guard activeDownloadID == nil, !isRestoringDownloads, !isVerifying, deletingModelFileName == nil else { return false }
        do {
            let url = try modelsDirectory(create: false).appendingPathComponent(model.fileName)
            try GGUFModelCatalog.validateCustomFile(at: url)
            modelChoiceRevision += 1
            GGUFModelSelection.save(fileName: model.fileName, defaults: defaults)
            GGUFEngineChoice.gemma.save(defaults: defaults)
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
        guard activeDownloadID == nil, !isRestoringDownloads, !isVerifying, deletingModelFileName == nil else { return false }
        isVerifying = true
        statusMessage = "Importing \(sourceURL.lastPathComponent)…"
        errorMessage = nil
        do {
            let task = Task.detached(priority: .userInitiated) {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                try GGUFModelCatalog.validateCustomFile(at: sourceURL)
                let directory = try self.modelsDirectory(create: true)
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
        modelChoiceRevision += 1
        choice.save(defaults: defaults)
        engineChoice = choice
        if choice == .appleIntelligence { Task { await AIService.unloadGGUFRunner() } }
    }

    /// The steps of `start` before its network task, and `finish`, for tests of the
    /// completion rule; nothing is downloaded or installed.
    func beginDownloadForTest(_ option: GGUFDownloadOption) {
        choiceRevisionAtDownloadStart = modelChoiceRevision
        beginDownload(option: option, receivedBytes: 0)
    }

    @discardableResult
    func finishForTest(_ option: GGUFDownloadOption) -> Bool {
        finish(option: option)
    }

    private func beginDownload(option: GGUFDownloadOption, receivedBytes: Int64) {
        deletedFileNames.remove(option.fileName)  // a download of this entry is a fresh intent
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

    /// Installs the finished download; returns whether it was also selected.
    @discardableResult
    private func finish(option: GGUFDownloadOption) -> Bool {
        activeTask = nil
        activeDownloadID = nil
        isVerifying = false
        progress = 1
        receivedBytes = option.expectedBytes
        let selects = choiceRevisionAtDownloadStart == modelChoiceRevision
        choiceRevisionAtDownloadStart = nil
        refreshInstalledModels()
        guard selects else {
            statusMessage = "\(option.title) downloaded.\(memoryNote(for: option))"
            return false
        }
        // A model the device is short on memory for is kept installed but never taken up on
        // its own; choosing it stays an explicit decision.
        if GGUFDownloadCatalog.needsMoreMemory(option, totalRAMBytes: totalRAMBytes) {
            statusMessage = "\(option.title) downloaded but not selected.\(memoryNote(for: option))"
            return false
        }
        selectInstalled(option)
        statusMessage = "\(option.title) downloaded and selected."
        return true
    }

    private func fail(taskIdentifier: Int, option: GGUFDownloadOption?, error: Error) {
        guard activeTask?.taskIdentifier == taskIdentifier, !isPausing else { return }
        choiceRevisionAtDownloadStart = nil
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
            let directory = try modelsDirectory(create: true)
            let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            guard try installCompletedDownload(from: stagingURL, in: directory, option: option) else { return }
            Task { @MainActor [weak self] in
                self?.finish(option: option)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.fail(taskIdentifier: downloadTask.taskIdentifier, option: option, error: error)
            }
        }
    }

    /// Validates a staged completion on the calling (delegate) queue, then publishes it on
    /// the runner's serial path; the call waits for the publish, so the background session's
    /// finish event follows it as it did for the whole install. Returns false, with the
    /// staged file discarded, when this entry was deleted in this process since.
    nonisolated func installCompletedDownload(from stagingURL: URL, in directory: URL, option: GGUFDownloadOption) throws -> Bool {
        try Self.validateStaging(at: stagingURL, in: directory, option: option)
        let done = DispatchSemaphore(value: 0)
        let outcome = PublishOutcome()
        let defaults = SendableDefaults(value: defaults)
        let deletedFileNames = self.deletedFileNames
        Task {
            do {
                try await AIService.ggufRunner.withExclusiveAccess(toModelFile: option.fileName) {
                    if deletedFileNames.contains(option.fileName) {
                        try? FileManager.default.removeItem(at: stagingURL)
                        outcome.published = false
                        return
                    }
                    try Self.publishDownload(from: stagingURL, in: directory, option: option, defaults: defaults.value)
                }
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
        return outcome.published
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let option = GGUFDownloadCatalog.option(id: task.taskDescription)
        if let option, !deletedFileNames.contains(option.fileName),
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let directory = try? modelsDirectory(create: true) {
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

    /// Validation off the main actor, then the publish on the runner's serial path, so a
    /// delete or load of the same file cannot overlap the rename.
    nonisolated static func installDownloadGated(
        from stagingURL: URL,
        in directory: URL,
        option: GGUFDownloadOption,
        defaults: UserDefaults = .standard
    ) async throws {
        try await Task.detached {
            try validateStaging(at: stagingURL, in: directory, option: option)
        }.value
        let defaults = SendableDefaults(value: defaults)
        try await AIService.ggufRunner.withExclusiveAccess(toModelFile: option.fileName) {
            try publishDownload(from: stagingURL, in: directory, option: option, defaults: defaults.value)
        }
    }

    nonisolated static func installDownload(
        from stagingURL: URL,
        in directory: URL,
        option: GGUFDownloadOption,
        defaults: UserDefaults = .standard
    ) throws {
        try validateStaging(at: stagingURL, in: directory, option: option)
        try publishDownload(from: stagingURL, in: directory, option: option, defaults: defaults)
    }

    /// Hashes the staged file; invalid bytes are discarded with their resume data.
    nonisolated static func validateStaging(at stagingURL: URL, in directory: URL, option: GGUFDownloadOption) throws {
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
    }

    /// Publishes a validated staged file under the catalog name and records its marker.
    nonisolated static func publishDownload(
        from stagingURL: URL,
        in directory: URL,
        option: GGUFDownloadOption,
        defaults: UserDefaults = .standard
    ) throws {
        let resumeURL = GGUFModelStorage.resumeDataURL(for: option, in: directory)
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
        GGUFVerifiedArtifactStore.record(sha256: option.sha256, at: destinationURL, defaults: defaults)
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
        guard try GGUFModelCatalog.fileSHA256(at: url) == option.sha256 else {
            throw GGUFDownloadError.checksumMismatch
        }
    }
}

/// UserDefaults is thread-safe but not marked Sendable; the gate closures carry it in this.
nonisolated private struct SendableDefaults: @unchecked Sendable {
    let value: UserDefaults
}

/// Written once by the publish task and read after the semaphore it signals.
nonisolated private final class PublishOutcome: @unchecked Sendable {
    var published = true
    var error: Error?
}

/// File names of entries deleted since their last download began, under
/// `deletedGGUFModelFileNames` in the manager's defaults.
nonisolated private final class DeletedEntries: @unchecked Sendable {
    private static let key = "deletedGGUFModelFileNames"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func insert(_ name: String) { update { $0.insert(name) } }
    func remove(_ name: String) { update { $0.remove(name) } }
    func contains(_ name: String) -> Bool { lock.withLock { load().contains(name) } }

    private func load() -> Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    private func update(_ body: (inout Set<String>) -> Void) {
        lock.withLock {
            var names = load()
            body(&names)
            defaults.set(names.sorted(), forKey: Self.key)
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
