import Foundation

// MARK: - Protocol

/// Minimal interface both the llama.cpp-backed implementation and the
/// compile-time stub must satisfy.
protocol LocalGGUFRunner: AnyObject {
    /// Load a GGUF file at the given absolute path.
    func loadModel(filePath: String) async throws

    /// Generate a response for the given prompt. Cancellation-safe.
    func generate(prompt: String) async throws -> String
}

// MARK: - Factory

/// Returns the best available runner: llama.cpp when the framework is linked,
/// otherwise a stub that throws localModelUnavailable immediately.
func makeLocalGGUFRunner() -> LocalGGUFRunner {
#if canImport(llama)
    return GGUFLlamaService()
#else
    return GGUFModelStub()
#endif
}

// MARK: - Stub (always compiled, used when llama.cpp is unavailable)

final class GGUFModelStub: LocalGGUFRunner {
    var isLoaded: Bool { false }

    func loadModel(filePath: String) async throws {
        throw AIServiceError.localModelUnavailable(
            reason: "Gemma on-device engine is not compiled into this build."
        )
    }

    func generate(prompt: String) async throws -> String {
        throw AIServiceError.localModelUnavailable(
            reason: "Gemma on-device engine is not compiled into this build."
        )
    }

    func unload() {}
}

// MARK: - Gemma helpers (always compiled — no llama dependency)

/// Pure text utilities for Gemma chat format. These are factored out so that
/// unit tests can exercise prompt template and marker-stripping logic without
/// requiring the llama.cpp SPM package to be resolved.
enum GGUFModelService {
    /// True only when the llama.cpp engine is linked into this target.
    nonisolated static var isEngineAvailable: Bool {
#if canImport(llama)
        true
#else
        false
#endif
    }

    /// Wraps a user prompt in the Gemma instruction chat template.
    /// Mirrors Android's AIService.gemmaInstructionPrompt().
    nonisolated static func gemmaPrompt(_ userPrompt: String) -> String {
        "<start_of_turn>user\n\(userPrompt)\n<end_of_turn>\n<start_of_turn>model\n"
    }

    /// Strip Gemma turn markers and bare `>` lines from raw model output.
    /// Mirrors Android's markerOnlyPattern filter.
    nonisolated static func stripMarkers(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return false }
                // Drop bare `>`, turn delimiters, role markers
                let markerRE = #"^(?:>|<?/?(?:start|end)_?(?:of_?)?turn>?|<\/?[a-z_]+>|model\s*$|user\s*$)$"#
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

nonisolated private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

nonisolated private func llamaBatchAdd(
    _ batch: inout llama_batch,
    token: llama_token,
    position: llama_pos,
    logits: Bool
) {
    let index = Int(batch.n_tokens)
    batch.token[index] = token
    batch.pos[index] = position
    batch.n_seq_id[index] = 1
    batch.seq_id[index]?[0] = 0
    batch.logits[index] = logits ? 1 : 0
    batch.n_tokens += 1
}

/// On-device Gemma runner backed by llama.cpp.
///
/// Thread-safety: all calls are serialized through an actor so the underlying
/// llama context is accessed from a single concurrency domain.
actor GGUFLlamaService: LocalGGUFRunner {

    // Match Android's constants (LocalModelService.kt).
    nonisolated private static let contextLength: Int32 = 2048
    nonisolated private static let generationTimeoutSeconds: Double = 120
    nonisolated private static let maxResponseBytes = 4096
    nonisolated private static let backendInitialization: Void = {
        llama_backend_init()
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?

    func loadModel(filePath: String) async throws {
        if loadedPath == filePath, model != nil, context != nil {
            return
        }

        releaseNative()
        _ = Self.backendInitialization

        var modelParams = llama_model_default_params()
#if targetEnvironment(simulator)
        // The official llama.cpp Swift example disables GPU offload in the
        // simulator because Simulator Metal does not mirror an iPhone GPU.
        modelParams.n_gpu_layers = 0
#else
        modelParams.n_gpu_layers = -1
#endif
        guard let loadedModel = llama_model_load_from_file(filePath, modelParams) else {
            throw AIServiceError.localModelUnavailable(
                reason: "Failed to load GGUF model at \(filePath). File may be corrupt or incompatible."
            )
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(Self.contextLength)
        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads = threadCount
        ctxParams.n_threads_batch = threadCount

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama context.")
        }

        self.model = loadedModel
        self.context = ctx
        self.loadedPath = filePath
    }

    func generate(prompt: String) async throws -> String {
        guard let ctx = context, let model = model else {
            throw AIServiceError.localModelUnavailable(
                reason: "No GGUF model loaded. Download a Gemma model in Settings."
            )
        }
        guard let vocab = llama_model_get_vocab(model) else {
            throw AIServiceError.localModelUnavailable(reason: "The downloaded model has no compatible vocabulary.")
        }

        let fullPrompt = GGUFModelService.gemmaPrompt(prompt)
        guard let cStr = fullPrompt.cString(using: .utf8) else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to encode prompt for the local model.")
        }
        let estimatedTokenCount = Int32(max(64, fullPrompt.utf8.count / 3 + 64))
        var tokens = [llama_token](repeating: 0, count: Int(estimatedTokenCount))
        var nTokens = llama_tokenize(
            vocab,
            cStr,
            Int32(fullPrompt.utf8.count),
            &tokens,
            Int32(tokens.count),
            true,
            false
        )
        if nTokens < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-nTokens))
            nTokens = llama_tokenize(
                vocab,
                cStr,
                Int32(fullPrompt.utf8.count),
                &tokens,
                Int32(tokens.count),
                true,
                false
            )
        }
        guard nTokens > 0 else {
            throw AIServiceError.localModelUnavailable(reason: "Tokenization produced no tokens.")
        }
        guard nTokens < Self.contextLength else {
            throw AIServiceError.localModelUnavailable(
                reason: "The lyric context is too long for the downloaded model. Shorten the context and try again."
            )
        }
        tokens = Array(tokens.prefix(Int(nTokens)))

        llama_memory_clear(llama_get_memory(ctx), true)

        var batch = llama_batch_init(Self.contextLength, 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in tokens.enumerated() {
            llamaBatchAdd(&batch, token: token, position: llama_pos(i), logits: false)
        }
        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }
        guard llama_decode(ctx, batch) == 0 else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to evaluate prompt tokens.")
        }

        let sampler = try makeSampler()
        defer { llama_sampler_free(sampler) }

        var outputBytes: [UInt8] = []
        var nCur = Int32(nTokens)
        let deadline = Date().addingTimeInterval(Self.generationTimeoutSeconds)

        while nCur < Self.contextLength && outputBytes.count < Self.maxResponseBytes {
            guard !Task.isCancelled else { break }
            guard Date() < deadline else {
                throw AIServiceError.localModelUnavailable(
                    reason: "Local model took too long to respond. Try a smaller model or shorten the lyric context."
                )
            }

            let nextToken = llama_sampler_sample(sampler, ctx, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, nextToken) { break }
            outputBytes.append(contentsOf: tokenPiece(nextToken, vocab: vocab).map { UInt8(bitPattern: $0) })

            llamaBatchClear(&batch)
            llamaBatchAdd(&batch, token: nextToken, position: llama_pos(nCur), logits: true)
            nCur += 1
            guard llama_decode(ctx, batch) == 0 else {
                throw AIServiceError.localModelUnavailable(reason: "Failed while generating the local response.")
            }
        }

        let result = String(decoding: outputBytes, as: UTF8.self)
        return GGUFModelService.stripMarkers(result)
    }

    func unload() {
        releaseNative()
    }

    private func releaseNative() {
        if let ctx = context { llama_free(ctx) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
        loadedPath = nil
    }

    private func makeSampler() throws -> UnsafeMutablePointer<llama_sampler> {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama sampler.")
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        return chain
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer) -> [CChar] {
        var piece = [CChar](repeating: 0, count: 16)
        var count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
        if count < 0 {
            piece = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
        }
        guard count > 0 else { return [] }
        return Array(piece.prefix(Int(count)))
    }
}

#endif // canImport(llama)

// MARK: - Engine choice

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
    }
}
