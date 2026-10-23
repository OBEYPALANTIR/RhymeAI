import Foundation
@testable import Writers_Block

/// Thrown by a boundary hook to stop an operation where a crash would.
struct SimulatedCrash: Error {}

/// A value a `@Sendable` hook can change; tests read it after the operation.
final class HookBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Runs `body` with `hook` registered at every move and unlink of recording bytes,
/// limited to paths inside `scope`, a folder with a unique name (the test's own);
/// removed afterwards.
@discardableResult
func withBoundaryHook<T>(scope: URL, _ hook: @escaping @Sendable (RecordingFiles.BoundaryHooks.Point, URL, URL?) throws -> Void,
                         _ body: () async throws -> T) async rethrows -> T {
    let marker = "/\(scope.lastPathComponent)/"
    let id = RecordingFiles.BoundaryHooks.install { point, source, target in
        guard source.path.contains(marker) else { return }
        try hook(point, source, target)
    }
    defer { RecordingFiles.BoundaryHooks.remove(id) }
    return try await body()
}
