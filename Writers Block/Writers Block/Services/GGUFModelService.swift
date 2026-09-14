import CryptoKit
import Foundation

struct GGUFModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let size: String
    let fileName: String
    let expectedBytes: Int64
    let sha256: String
    let minimumPhysicalMemoryBytes: UInt64
    let url: URL
}

struct GGUFCustomModel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
}

nonisolated enum GGUFCustomModelRegistry {
    private static let key = "customGGUFModels"

    static func models(defaults: UserDefaults = .standard) -> [GGUFCustomModel] {
        guard let data = defaults.data(forKey: key),
              let models = try? JSONDecoder().decode([GGUFCustomModel].self, from: data) else {
            return []
        }
        return models
    }

    static func save(
        _ models: [GGUFCustomModel],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: key)
    }

    static func register(
        _ model: GGUFCustomModel,
        defaults: UserDefaults = .standard
    ) {
        let updated = (models(defaults: defaults).filter { $0.id != model.id } + [model])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save(updated, defaults: defaults)
    }

    static func contains(
        fileName: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        models(defaults: defaults).contains { $0.fileName == fileName }
    }
}

struct GGUFDownloadSegment: Equatable {
    let index: Int
    let start: Int64
    let endInclusive: Int64

    var size: Int64 { endInclusive - start + 1 }
}

/// Splits a model download into concurrent byte ranges. Hugging Face shapes each
/// connection, so one stream lands far below the link capacity; measured
/// 2026-07-29 against the pinned revision, eight ranged connections moved
/// 10.7 MB/s versus 3.2 MB/s on one. Kept byte-identical to Android's
/// `planDownloadSegments` so both platforms fetch the same spans.
nonisolated enum GGUFDownloadPlan {
    static let segmentCount = 8
    static let minimumSegmentBytes: Int64 = 8 * 1024 * 1024

    static func segments(totalBytes: Int64, maxSegments: Int = segmentCount) -> [GGUFDownloadSegment] {
        precondition(totalBytes > 0, "totalBytes must be positive")
        precondition(maxSegments > 0, "maxSegments must be positive")
        let bySize = max(totalBytes / minimumSegmentBytes, 1)
        let count = Int(min(Int64(maxSegments), bySize))
        let base = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)

        var start: Int64 = 0
        return (0..<count).map { index in
            let size = base + (Int64(index) < remainder ? 1 : 0)
            let segment = GGUFDownloadSegment(index: index, start: start, endInclusive: start + size - 1)
            start += size
            return segment
        }
    }
}

nonisolated enum GGUFModelCatalog {
    private static let sourceRevision = "babc525587cfe15066b1190d32d962139bdc4923"
    private static let baseURL = "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/\(sourceRevision)"

    static let models: [GGUFModelDescriptor] = [
        GGUFModelDescriptor(
            id: "rhymeai-gemma-4-e2b",
            title: "RhymeAI Gemma E2B",
            subtitle: "Tuned for RhymeAI — best default, faster",
            size: "3.43 GB",
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 3_427_878_784,
            sha256: "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626",
            minimumPhysicalMemoryBytes: 6_000_000_000,
            url: URL(string: "\(baseURL)/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true")!
        ),
        GGUFModelDescriptor(
            id: "rhymeai-gemma-4-e4b",
            title: "RhymeAI Gemma E4B",
            subtitle: "Tuned for RhymeAI — higher quality, slower",
            size: "5.34 GB",
            fileName: "gemma-4-E4B-it-rhymeai-Q4_K_M.gguf",
            expectedBytes: 5_335_290_784,
            sha256: "e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3",
            minimumPhysicalMemoryBytes: 8_000_000_000,
            url: URL(string: "\(baseURL)/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true")!
        )
    ]

    static func descriptor(fileName: String) -> GGUFModelDescriptor? {
        models.first { $0.fileName == fileName }
    }

    static func modelsDirectory(create: Bool) throws -> URL {
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

    static func validateFile(
        at url: URL,
        against model: GGUFModelDescriptor,
        cancellationCheck: () throws -> Void = {}
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileBytes == model.expectedBytes else {
            throw AIServiceError.localModelUnavailable(reason: "The downloaded model has an unexpected file size.")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try cancellationCheck()
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else {
            throw AIServiceError.localModelUnavailable(reason: "The downloaded model failed its integrity check.")
        }
    }

    static func validateCustomFile(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 24), header.count == 24 else {
            throw AIServiceError.localModelUnavailable(reason: "The selected GGUF model is incomplete.")
        }
        let version = UInt32(header[4])
            | UInt32(header[5]) << 8
            | UInt32(header[6]) << 16
            | UInt32(header[7]) << 24
        guard header.prefix(4) == Data("GGUF".utf8), (2...3).contains(version) else {
            throw AIServiceError.localModelUnavailable(reason: "The selected file is not a GGUF model.")
        }
    }
}

nonisolated enum GGUFModelSelection {
    private static let key = "selectedGGUFModelFileName"

    static var currentFileName: String? {
        currentFileName(defaults: .standard)
    }

    static func currentFileName(defaults: UserDefaults) -> String? {
        guard let fileName = defaults.string(forKey: key),
              GGUFModelCatalog.descriptor(fileName: fileName) != nil
                || GGUFCustomModelRegistry.contains(fileName: fileName, defaults: defaults) else {
            return nil
        }
        return fileName
    }

    static func save(fileName: String, defaults: UserDefaults = .standard) {
        guard GGUFModelCatalog.descriptor(fileName: fileName) != nil
                || GGUFCustomModelRegistry.contains(fileName: fileName, defaults: defaults) else { return }
        defaults.set(fileName, forKey: key)
        SynonymLocalRevision.advance(defaults: defaults)
    }

    static func resolvedModelURL(
        defaults: UserDefaults = .standard,
        modelsDirectory: URL? = nil
    ) -> URL? {
        guard let directory = modelsDirectory
                ?? (try? GGUFModelCatalog.modelsDirectory(create: false)) else { return nil }
        let fileManager = FileManager.default
        if let selected = currentFileName(defaults: defaults) {
            let selectedURL = directory.appendingPathComponent(selected)
            if fileManager.fileExists(atPath: selectedURL.path) { return selectedURL }
        }

        if let fallback = GGUFModelCatalog.models.first(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
        }) {
            save(fileName: fallback.fileName, defaults: defaults)
            return directory.appendingPathComponent(fallback.fileName)
        }

        guard let fallback = GGUFCustomModelRegistry.models(defaults: defaults).first(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
        }) else { return nil }
        save(fileName: fallback.fileName, defaults: defaults)
        return directory.appendingPathComponent(fallback.fileName)
    }
}

// MARK: - Engine wiring
//
// This service is intentionally compilable WITHOUT the llama.cpp framework.
// When the "llama" product is NOT linked, all calls go through GGUFModelStub
// and immediately throw AIServiceError.localModelUnavailable — the app stays
// green and routes fall back to Apple Intelligence.
//
// The real engine ships as a prebuilt llama.xcframework (llama.cpp removed
// source-level SPM support in PR #11996). It is wired via the local package
// "Writers Block/LlamaFramework" (a binaryTarget pinned to release b9949),
// which the app target links as the "llama" product. When that package is
// resolved, the #if canImport(llama) block below compiles in and
// GGUFLlamaService becomes the live implementation automatically.

// MARK: - Protocol

/// Minimal interface both the llama.cpp-backed implementation and the
/// compile-time stub must satisfy.
nonisolated protocol LocalGGUFRunner: AnyObject, Sendable {
    /// True after a successful loadModel call.
    var isLoaded: Bool { get }

    /// Load a GGUF file at the given absolute path.
    func loadModel(filePath: String) async throws

    /// Generate a response for the given prompt. Cancellation-safe.
    func generate(prompt: String) async throws -> String

    func generate(prompt: String, loading filePath: String) async throws -> String

    func generate(
        prompt: String,
        loading filePath: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String

    /// Release native resources. Safe to call when not loaded.
    func unload() async
}

// MARK: - Factory

/// Returns the best available runner: llama.cpp when the package is resolved,
/// otherwise a stub that throws localModelUnavailable immediately.
nonisolated func makeLocalGGUFRunner() -> LocalGGUFRunner {
#if canImport(llama)
    return GGUFLlamaService()
#else
    return GGUFModelStub()
#endif
}

// MARK: - Stub (always compiled, used when llama.cpp SPM package is absent)

nonisolated final class GGUFModelStub: LocalGGUFRunner, @unchecked Sendable {
    var isLoaded: Bool { false }

    func loadModel(filePath: String) async throws {
        throw AIServiceError.localModelUnavailable(
            reason: "Gemma on-device engine is not compiled in. See GGUFModelService.swift for setup instructions."
        )
    }

    func generate(prompt: String) async throws -> String {
        throw AIServiceError.localModelUnavailable(
            reason: "Gemma on-device engine is not compiled in. See GGUFModelService.swift for setup instructions."
        )
    }

    func generate(prompt: String, loading filePath: String) async throws -> String {
        try await loadModel(filePath: filePath)
        return try await generate(prompt: prompt)
    }

    func generate(
        prompt: String,
        loading filePath: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await loadModel(filePath: filePath)
        return try await generate(prompt: prompt)
    }

    func unload() {}
}

// MARK: - Gemma helpers (always compiled — no llama dependency)

nonisolated enum GGUFPromptFormat: Equatable, Sendable {
    case gemmaLegacy
    case gemma4

    static func resolve(architecture: String, chatTemplate: String) -> GGUFPromptFormat? {
        let hasLegacyTurns = chatTemplate.contains("<start_of_turn>") && chatTemplate.contains("<end_of_turn>")
        let hasGemma4Turns = chatTemplate.contains("<|turn>") && chatTemplate.contains("<turn|>")
        switch architecture {
        case "gemma4" where hasGemma4Turns && !hasLegacyTurns:
            return .gemma4
        case "gemma", "gemma2", "gemma3", "gemma3n":
            return hasLegacyTurns && !hasGemma4Turns ? .gemmaLegacy : nil
        default:
            return nil
        }
    }
}

nonisolated enum GGUFModelService {
    struct GenerationTrace {
        let seed: UInt32
        let tokenizerArchitecture: String
        let tokenizerEnvelope: String
        let tokenizerChatTemplateSHA256: String
        let terminationReason: String
        let userPromptSHA256: String
        let renderedPromptSHA256: String
        let promptTokenCount: Int
        let modelLoadSeconds: Double
    }

    private final class TraceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tokenizerArchitecture = ""
        private var tokenizerEnvelope = ""
        private var tokenizerChatTemplateSHA256 = ""
        private var seed: UInt32?
        private var terminationReason = "notRun"
        private var userPromptSHA256 = ""
        private var renderedPromptSHA256 = ""
        private var promptTokenCount = 0
        private var modelLoadSeconds = 0.0

        func setTokenizer(architecture: String, envelope: String, chatTemplate: String) {
            lock.lock()
            tokenizerArchitecture = architecture
            tokenizerEnvelope = envelope
            tokenizerChatTemplateSHA256 = SHA256.hash(data: Data(chatTemplate.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            lock.unlock()
        }

        func begin(seed: UInt32, userPrompt: String, renderedPrompt: String, tokens: Int, modelLoadSeconds: Double) {
            lock.lock()
            self.seed = seed
            self.userPromptSHA256 = SHA256.hash(data: Data(userPrompt.utf8)).map { String(format: "%02x", $0) }.joined()
            self.renderedPromptSHA256 = SHA256.hash(data: Data(renderedPrompt.utf8)).map { String(format: "%02x", $0) }.joined()
            self.promptTokenCount = tokens
            self.modelLoadSeconds = modelLoadSeconds
            terminationReason = "running"
            lock.unlock()
        }

        func finish(reason: String) {
            lock.lock()
            terminationReason = reason
            lock.unlock()
        }

        func value() -> GenerationTrace? {
            lock.lock()
            defer { lock.unlock() }
            guard let seed,
                  !tokenizerArchitecture.isEmpty,
                  !tokenizerEnvelope.isEmpty,
                  !tokenizerChatTemplateSHA256.isEmpty else { return nil }
            return GenerationTrace(
                seed: seed,
                tokenizerArchitecture: tokenizerArchitecture,
                tokenizerEnvelope: tokenizerEnvelope,
                tokenizerChatTemplateSHA256: tokenizerChatTemplateSHA256,
                terminationReason: terminationReason,
                userPromptSHA256: userPromptSHA256,
                renderedPromptSHA256: renderedPromptSHA256,
                promptTokenCount: promptTokenCount,
                modelLoadSeconds: modelLoadSeconds
            )
        }
    }

    private static let traceStore = TraceStore()
    static let engineVersion = "b9949"
    static let contextLength: UInt32 = 2_048
    static let generationTimeoutSeconds: Double = 120
    static let maxResponseCharacters = 4_096
    static let samplerTopK: Int32 = 40
    static let samplerTopP: Float = 0.95
    static let samplerTemperature: Float = 0.8
    static let addSpecialTokens = true
    static let parseSpecialTokens = true
    static let cachePolicy = "clear_kv_per_request_keep_model_resident"

    static var lastGenerationTrace: GenerationTrace? { traceStore.value() }

    static func recordTokenizerMetadata(
        architecture: String,
        format: GGUFPromptFormat,
        chatTemplate: String
    ) {
        traceStore.setTokenizer(
            architecture: architecture,
            envelope: format == .gemma4 ? "gemma4" : "gemmaLegacy",
            chatTemplate: chatTemplate
        )
    }

    static func recordGenerationStarted(seed: UInt32, userPrompt: String, renderedPrompt: String, tokens: Int, modelLoadSeconds: Double) {
        traceStore.begin(seed: seed, userPrompt: userPrompt, renderedPrompt: renderedPrompt, tokens: tokens, modelLoadSeconds: modelLoadSeconds)
    }

    static func recordGenerationFinished(reason: String) {
        traceStore.finish(reason: reason)
    }

    /// True only when the llama.cpp engine is linked into this target.
    static var isEngineAvailable: Bool {
#if canImport(llama)
        true
#else
        false
#endif
    }

    static func gemmaPrompt(_ userPrompt: String, format: GGUFPromptFormat) -> String {
        let userMarker: String
        let modelMarker: String
        switch format {
        case .gemmaLegacy:
            userMarker = "<start_of_turn>user\n"
            modelMarker = "\n<end_of_turn>\n<start_of_turn>model"
        case .gemma4:
            userMarker = "<|turn>user\n"
            modelMarker = "<turn|>\n<|turn>model"
        }
        var content = userPrompt

        while content.hasPrefix(userMarker) {
            let normalized = content.hasSuffix("\(modelMarker)\n")
                ? String(content.dropLast())
                : content
            guard normalized.hasSuffix(modelMarker) else { break }
            content = String(normalized.dropFirst(userMarker.count).dropLast(modelMarker.count))
        }

        return "\(userMarker)\(content)\(modelMarker)" + (format == .gemma4 ? "\n" : "")
    }

    /// Strip tagged Gemma turn markers and bare `>` lines from raw model output.
    /// Mirrors Android's markerOnlyPattern filter.
    static func stripMarkers(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return false }
                // Drop bare `>` and tagged turn delimiters.
                let markerRE = #"^(?:>|<?/?(?:start|end)_?(?:of_?)?turn>?|<\/?[a-z_]+>)$"#
                if t.range(of: markerRE, options: [.regularExpression, .caseInsensitive]) != nil { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Live implementation (compiled only when llama.cpp is resolved)

#if canImport(llama)
import llama

/// On-device Gemma runner backed by llama.cpp (prebuilt xcframework, b9949).
///
/// Thread-safety: all llama calls are serialized through this actor. The
/// `isLoaded` flag is a lock-protected snapshot so AIService can read it
/// synchronously from any thread.
actor GGUFLlamaService: LocalGGUFRunner {

    /// Process-wide backend init, executed once on first model load.
    private static let backendReady: Void = llama_backend_init()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var promptFormat: GGUFPromptFormat?
    private var transactionIsActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }
    private nonisolated let loadedFlag = LockedBool()

    nonisolated var isLoaded: Bool { loadedFlag.get() }

    func loadModel(filePath: String) async throws {
        await acquireTransaction()
        defer { releaseTransaction() }
        let cancelled = LockedBool()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try loadModelNative(filePath: filePath, cancelled: cancelled)
        } onCancel: {
            cancelled.set(true)
        }
    }

    private func loadModelNative(filePath: String, cancelled: LockedBool) throws {
        // Idempotent: reloading the same file is a no-op so callers can call
        // this unconditionally before each request.
        if loadedPath == filePath, model != nil { return }
        releaseNative()
        _ = Self.backendReady

        let fileURL = URL(fileURLWithPath: filePath)
        if let descriptor = GGUFModelCatalog.descriptor(fileName: fileURL.lastPathComponent) {
            try GGUFModelCatalog.validateFile(
                at: fileURL,
                against: descriptor,
                cancellationCheck: { try Task.checkCancellation() }
            )
        } else if GGUFCustomModelRegistry.contains(fileName: fileURL.lastPathComponent) {
            try GGUFModelCatalog.validateCustomFile(at: fileURL)
        } else {
            throw AIServiceError.localModelUnavailable(reason: "This GGUF model is not registered with RhymeAI.")
        }

        try Task.checkCancellation()
        var modelParams = llama_model_default_params()
        modelParams.progress_callback_user_data = Unmanaged.passUnretained(cancelled).toOpaque()
        modelParams.progress_callback = { _, data in
            guard let data else { return false }
            return !Unmanaged<LockedBool>.fromOpaque(data).takeUnretainedValue().get()
        }
#if targetEnvironment(simulator)
        // The simulator Metal device corrupts Gemma4 output; its CPU backend is verified.
        modelParams.n_gpu_layers = 0
#endif
        guard let loadedModel = llama_model_load_from_file(filePath, modelParams) else {
            try Task.checkCancellation()
            throw AIServiceError.localModelUnavailable(
                reason: "Failed to load GGUF model at \(filePath). File may be corrupt or incompatible."
            )
        }

        if cancelled.get() {
            llama_model_free(loadedModel)
            throw CancellationError()
        }
        let architectureLength = llama_model_meta_val_str(loadedModel, "general.architecture", nil, 0)
        guard architectureLength > 0,
              let template = llama_model_chat_template(loadedModel, nil) else {
            llama_model_free(loadedModel)
            throw AIServiceError.localModelUnavailable(reason: "The selected GGUF does not declare a supported chat format.")
        }
        var architecture = [CChar](repeating: 0, count: Int(architectureLength) + 1)
        llama_model_meta_val_str(loadedModel, "general.architecture", &architecture, architecture.count)
        let architectureName = String(cString: architecture)
        let chatTemplate = String(cString: template)
        guard let format = GGUFPromptFormat.resolve(
            architecture: architectureName,
            chatTemplate: chatTemplate
        ) else {
            llama_model_free(loadedModel)
            throw AIServiceError.localModelUnavailable(reason: "The selected GGUF chat format is not supported. Choose a Gemma model with its original chat template.")
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = GGUFModelService.contextLength
        ctxParams.n_batch = GGUFModelService.contextLength
        let threads = Int32(max(1, ProcessInfo.processInfo.processorCount / 2))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama context.")
        }

        self.model = loadedModel
        self.context = ctx
        self.loadedPath = filePath
        self.promptFormat = format
        GGUFModelService.recordTokenizerMetadata(
            architecture: architectureName,
            format: format,
            chatTemplate: chatTemplate
        )
        loadedFlag.set(true)
    }

    func generate(prompt: String) async throws -> String {
        await acquireTransaction()
        defer { releaseTransaction() }
        let cancelled = LockedBool()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await generateText(prompt: prompt, onChunk: nil, cancelled: cancelled, modelLoadSeconds: 0)
        } onCancel: {
            cancelled.set(true)
        }
    }

    private func generateText(
        prompt: String,
        onChunk: (@Sendable (String) -> Void)?,
        cancelled: LockedBool,
        modelLoadSeconds: Double
    ) async throws -> String {
        guard let ctx = context, let model = model, let promptFormat else {
            throw AIServiceError.localModelUnavailable(
                reason: "No GGUF model loaded. Download a Gemma model in Settings."
            )
        }
        llama_set_abort_callback(ctx, { data in
            guard let data else { return true }
            return Unmanaged<LockedBool>.fromOpaque(data).takeUnretainedValue().get()
        }, Unmanaged.passUnretained(cancelled).toOpaque())
        defer { llama_set_abort_callback(ctx, nil, nil) }
        let vocab = llama_model_get_vocab(model)

        // Each request is a fresh single-turn conversation: drop KV state.
        llama_memory_clear(llama_get_memory(ctx), true)

        let fullPrompt = GGUFModelService.gemmaPrompt(prompt, format: promptFormat)
        let utf8Length = Int32(fullPrompt.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Length) + 64)
        // parse_special: the Gemma turn markers must map to their special tokens.
        let nTokens = fullPrompt.withCString { cStr in
            llama_tokenize(vocab, cStr, utf8Length, &tokens, Int32(tokens.count), true, true)
        }
        guard nTokens > 0 else {
            throw AIServiceError.localModelUnavailable(reason: "Tokenization produced no tokens.")
        }
        guard nTokens < Int32(GGUFModelService.contextLength) else {
            throw AIServiceError.localModelUnavailable(
                reason: "Prompt is too long for the local model. Shorten the lyric context."
            )
        }
        tokens.removeSubrange(Int(nTokens)...)

        // One sampler chain per request — the dist sampler carries RNG state.
        let seed = UInt32.random(in: 0..<UInt32.max)
        GGUFModelService.recordGenerationStarted(seed: seed, userPrompt: prompt, renderedPrompt: fullPrompt, tokens: Int(nTokens), modelLoadSeconds: modelLoadSeconds)
        var terminationReason = "error"
        defer {
            GGUFModelService.recordGenerationFinished(
                reason: Task.isCancelled ? "cancelled" : terminationReason
            )
        }
        let sampler = try makeSampler(seed: seed)
        defer { llama_sampler_free(sampler) }

        var resultBytes: [UInt8] = []
        var chunkBytes: [UInt8] = []
        var pending = tokens // next batch to decode; positions auto-tracked (pos == NULL)
        var nPast = nTokens
        let deadline = Date().addingTimeInterval(GGUFModelService.generationTimeoutSeconds)

        generationLoop: while nPast < Int32(GGUFModelService.contextLength),
              resultBytes.count < GGUFModelService.maxResponseCharacters {
            try Task.checkCancellation()
            guard Date() < deadline else {
                terminationReason = "deadline"
                throw AIServiceError.localModelUnavailable(
                    reason: "Local model took too long to respond. Try a smaller model or shorten the lyric context."
                )
            }

            let status = pending.withUnsafeMutableBufferPointer { buffer in
                llama_decode(ctx, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            try Task.checkCancellation()
            guard status == 0 else {
                throw AIServiceError.localModelUnavailable(reason: "Failed to evaluate tokens.")
            }

            let nextToken = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, nextToken) {
                terminationReason = "eog"
                break
            }

            var piece = [CChar](repeating: 0, count: 128)
            var pieceLength = llama_token_to_piece(vocab, nextToken, &piece, Int32(piece.count), 0, false)
            if pieceLength < 0 {
                piece = [CChar](repeating: 0, count: Int(-pieceLength))
                pieceLength = llama_token_to_piece(vocab, nextToken, &piece, Int32(piece.count), 0, false)
            }
            if pieceLength > 0 {
                let bytes = piece.prefix(Int(pieceLength)).map { UInt8(bitPattern: $0) }
                guard resultBytes.count + bytes.count <= GGUFModelService.maxResponseCharacters else {
                    terminationReason = "maximumResponseLength"
                    break generationLoop
                }
                resultBytes.append(contentsOf: bytes)
                chunkBytes.append(contentsOf: bytes)
                if let chunk = String(bytes: chunkBytes, encoding: .utf8) {
                    onChunk?(chunk)
                    chunkBytes.removeAll(keepingCapacity: true)
                }
            }

            pending = [nextToken]
            nPast += 1
            await Task.yield()
        }

        if terminationReason == "error" {
            terminationReason = resultBytes.count >= GGUFModelService.maxResponseCharacters
                ? "maximumResponseLength"
                : "contextExhausted"
        }

        try Task.checkCancellation()
        guard terminationReason == "eog", let response = String(bytes: resultBytes, encoding: .utf8) else {
            throw AIServiceError.decodingError
        }
        return response
    }

    func generate(prompt: String, loading filePath: String) async throws -> String {
        try await generate(prompt: prompt, loading: filePath, onChunk: { _ in })
    }

    func generate(
        prompt: String,
        loading filePath: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        await acquireTransaction()
        defer { releaseTransaction() }
        let cancelled = LockedBool()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let loadStarted = Date()
            try loadModelNative(filePath: filePath, cancelled: cancelled)
            let modelLoadSeconds = Date().timeIntervalSince(loadStarted)
            try Task.checkCancellation()
            return try await generateText(prompt: prompt, onChunk: onChunk, cancelled: cancelled, modelLoadSeconds: modelLoadSeconds)
        } onCancel: {
            cancelled.set(true)
        }
    }

    func unload() async {
        await acquireTransaction()
        defer { releaseTransaction() }
        releaseNative()
    }

    private func releaseNative() {
        if let ctx = context { llama_free(ctx) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
        loadedPath = nil
        promptFormat = nil
        loadedFlag.set(false)
    }

    private func acquireTransaction() async {
        if !transactionIsActive {
            transactionIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transactionWaiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionIsActive = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }

    private func makeSampler(seed: UInt32) throws -> UnsafeMutablePointer<llama_sampler> {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama sampler.")
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(GGUFModelService.samplerTopK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(GGUFModelService.samplerTopP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(GGUFModelService.samplerTemperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        return chain
    }
}

#endif // canImport(llama)

// MARK: - Engine choice

nonisolated enum SynonymLocalRevision {
    private static let key = "synonymLocalRevision"

    static func current(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key)
    }

    static func advance(defaults: UserDefaults = .standard) {
        defaults.set(current(defaults: defaults) &+ 1, forKey: key)
    }
}

/// Persisted engine selection for the local provider.
/// Stored in UserDefaults under key "ggufEngineChoice".
enum GGUFEngineChoice: String, CaseIterable {
    case appleIntelligence = "apple"
    case gemma = "gemma"

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .gemma: return "Gemma (downloaded)"
        }
    }

    static var current: GGUFEngineChoice {
        let raw = UserDefaults.standard.string(forKey: "ggufEngineChoice") ?? ""
        return GGUFEngineChoice(rawValue: raw) ?? .appleIntelligence
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "ggufEngineChoice")
        SynonymLocalRevision.advance()
    }
}
