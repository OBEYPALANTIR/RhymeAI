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
/// limited to paths under `scope`, a folder only this test uses; removed afterwards.
/// Every test's hook is called for every move in the process (tests run at once),
/// so the scope is matched by its whole path, not by a folder name that other tests
/// may share (such as `recording-import`).
@discardableResult
func withBoundaryHook<T>(scope: URL, _ hook: @escaping @Sendable (RecordingFiles.BoundaryHooks.Point, URL, URL?) throws -> Void,
                         _ body: () async throws -> T) async rethrows -> T {
    let prefix = boundaryPath(scope) + "/"
    let id = RecordingFiles.BoundaryHooks.install { point, source, target in
        guard boundaryPath(source).hasPrefix(prefix) else { return }
        try hook(point, source, target)
    }
    defer { RecordingFiles.BoundaryHooks.remove(id) }
    return try await body()
}

/// A path compared without the `/private` alias (`/var` and `/private/var` are one
/// folder), whether or not the file still exists.
private func boundaryPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path
    return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}
