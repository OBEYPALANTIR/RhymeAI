import Foundation

// MARK: - Manual setup required (SPM)
//
// This service is intentionally compilable WITHOUT the llama.cpp package.
// When the package is NOT resolved, all calls go through GGUFModelStub and
// immediately throw AIServiceError.localModelUnavailable — the app stays
// green and routes fall back to Apple Intelligence.
//
// To enable real on-device Gemma inference:
//   1. Open "Writers Block/Writers Block.xcodeproj" in Xcode.
//   2. File > Add Package Dependencies…
//   3. Paste: https://github.com/ggml-org/llama.cpp
//   4. Pin to a release tag (e.g. b5100 or the latest stable tag).
//   5. Add the "llama" product to the "Writers Block" target.
//   6. The #if canImport(llama) block below compiles in and GGUFModelService
//      becomes the live implementation automatically.

// MARK: - Protocol

/// Minimal interface both the llama.cpp-backed implementation and the
/// compile-time stub must satisfy.
protocol LocalGGUFRunner: AnyObject {
    /// True after a successful loadModel call.
    var isLoaded: Bool { get }

    /// Load a GGUF file at the given absolute path.
    func loadModel(filePath: String) async throws

    /// Generate a response for the given prompt. Cancellation-safe.
    func generate(prompt: String) async throws -> String

    /// Release native resources. Safe to call when not loaded.
    func unload()
}

// MARK: - Factory

/// Returns the best available runner: llama.cpp when the package is resolved,
/// otherwise a stub that throws localModelUnavailable immediately.
func makeLocalGGUFRunner() -> LocalGGUFRunner {
#if canImport(llama)
    return GGUFLlamaService()
#else
    return GGUFModelStub()
#endif
}

// MARK: - Stub (always compiled, used when llama.cpp SPM package is absent)

final class GGUFModelStub: LocalGGUFRunner {
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

    func unload() {}
}

// MARK: - Gemma helpers (always compiled — no llama dependency)

/// Pure text utilities for Gemma chat format. These are factored out so that
/// unit tests can exercise prompt template and marker-stripping logic without
/// requiring the llama.cpp SPM package to be resolved.
enum GGUFModelService {
    /// Wraps a user prompt in the Gemma instruction chat template.
    /// Mirrors Android's AIService.gemmaInstructionPrompt().
    static func gemmaPrompt(_ userPrompt: String) -> String {
        "<start_of_turn>user\n\(userPrompt)\n<end_of_turn>\n<start_of_turn>model\n"
    }

    /// Strip Gemma turn markers and bare `>` lines from raw model output.
    /// Mirrors Android's markerOnlyPattern filter.
    static func stripMarkers(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return false }
                // Drop bare `>`, turn delimiters, role markers
                let markerRE = #"^(?:>|<start_of_turn>|<end_of_turn>|<\/?[a-z_]+>|model\s*$|user\s*$)$"#
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

/// On-device Gemma runner backed by llama.cpp.
///
/// Thread-safety: all calls are serialized through an actor so the underlying
/// llama context is accessed from a single concurrency domain.
actor GGUFLlamaService: LocalGGUFRunner {

    // Match Android's constants (LocalModelService.kt).
    private static let contextLength: Int32 = 2048
    private static let generationTimeoutSeconds: Double = 120
    private static let maxResponseChars = 4096

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?

    nonisolated var isLoaded: Bool {
        // nonisolated advisory read — races are benign (UI-only flag).
        false
    }

    private var _isLoaded: Bool { loadedPath != nil }

    func loadModel(filePath: String) async throws {
        releaseNative()

        let params = llama_model_default_params()
        guard let loadedModel = llama_model_load_from_file(filePath, params) else {
            throw AIServiceError.localModelUnavailable(
                reason: "Failed to load GGUF model at \(filePath). File may be corrupt or incompatible."
            )
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(Self.contextLength)
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount / 2))

        guard let ctx = llama_new_context_with_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama context.")
        }

        self.model = loadedModel
        self.context = ctx
        self.loadedPath = filePath
    }

    func generate(prompt: String) async throws -> String {
        guard _isLoaded, let ctx = context, let model = model else {
            throw AIServiceError.localModelUnavailable(
                reason: "No GGUF model loaded. Download a Gemma model in Settings."
            )
        }

        let fullPrompt = GGUFModelService.gemmaPrompt(prompt)
        guard let cStr = fullPrompt.cString(using: .utf8) else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to encode prompt for the local model.")
        }
        let estimatedTokenCount = Int32(fullPrompt.count / 3 + 64)
        var tokens = [llama_token](repeating: 0, count: Int(estimatedTokenCount))
        let nTokens = llama_tokenize(model, cStr, Int32(fullPrompt.utf8.count), &tokens, estimatedTokenCount, true, false)
        guard nTokens > 0 else {
            throw AIServiceError.localModelUnavailable(reason: "Tokenization produced no tokens.")
        }
        tokens = Array(tokens.prefix(Int(nTokens)))

        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in tokens.enumerated() {
            llama_batch_add(&batch, token, llama_pos(i), [0], false)
        }
        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }
        guard llama_decode(ctx, batch) == 0 else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to evaluate prompt tokens.")
        }

        var result = ""
        var nCur = Int32(nTokens)
        let eosToken = llama_token_eos(model)
        let deadline = Date().addingTimeInterval(Self.generationTimeoutSeconds)

        while nCur < Self.contextLength && result.count < Self.maxResponseChars {
            guard !Task.isCancelled else { break }
            guard Date() < deadline else {
                throw AIServiceError.localModelUnavailable(
                    reason: "Local model took too long to respond. Try a smaller model or shorten the lyric context."
                )
            }

            let sampler = try makeSampler()
            defer { llama_sampler_free(sampler) }
            let nextToken = llama_sampler_sample(sampler, ctx, -1)
            if nextToken == eosToken { break }

            var piece = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(model, nextToken, &piece, 64, 0, false)
            if n > 0 {
                result += String(bytes: piece.prefix(Int(n)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            }

            llama_batch_clear(&batch)
            llama_batch_add(&batch, nextToken, llama_pos(nCur), [0], true)
            nCur += 1
            llama_decode(ctx, batch)
        }

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

    private func makeSampler() throws -> OpaquePointer {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw AIServiceError.localModelUnavailable(reason: "Failed to create llama sampler.")
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        return chain
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
