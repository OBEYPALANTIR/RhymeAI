import ActivityKit
import AppIntents
import Foundation
import Observation

// Built into the app and the widget extension: widgets, controls and the Live
// Activity name these intents, and the app runs them.

/// What a shortcut, widget, control, Live Activity or link asks the app to do next.
enum OneLinerPendingAction: String, CaseIterable {
    case record
    case type
    case open
    /// Stop the take being recorded and save it (the Live Activity's Done).
    case stopRecording

    static let urlScheme = "writersblock"
    static let urlHost = "one-liners"
    /// UI tests launch with `-oneLinerPendingAction record` in place of opening a link.
    static let launchArgument = "-oneLinerPendingAction"

    /// `writersblock://one-liners/record`, `/type` or `/open`; a bare `writersblock://one-liners` opens the screen.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme, url.host?.lowercased() == Self.urlHost else { return nil }
        let route = url.pathComponents.dropFirst().first?.lowercased() ?? Self.open.rawValue
        guard let action = Self(rawValue: route), action.url != nil else { return nil }
        self = action
    }

    /// Nil for `stopRecording`, which only the Live Activity asks for.
    var url: URL? {
        self == .stopRecording ? nil : URL(string: "\(Self.urlScheme)://\(Self.urlHost)/\(rawValue)")
    }

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: arguments[index + 1])
    }
}

/// The app-wide hand-off from intents and links to the views. An action stays
/// pending until the view that handles it takes it, so a request that cannot be
/// shown yet is not lost, and nothing replaces a capture that is still open.
@Observable
final class OneLinerRouter {
    static let shared = OneLinerRouter()

    /// Who acts on a pending action, given what is on screen.
    enum Handler: Equatable {
        /// Presents the One Liners screen; the screen then takes the action.
        case root
        /// The One Liners screen opened from outside: opens the capture asked for.
        case screen
        /// A capture sheet already open: keeps its words and take, and says so.
        case capture
    }

    private(set) var pending: OneLinerPendingAction?
    /// The recorder whose take is being recorded, so a Stop from the Live Activity
    /// reaches that take and no other recorder's teardown clears it.
    private(set) var recordingOwner: UUID?
    /// Capture sheets on screen (one per scene at most).
    private(set) var openCaptures: Set<UUID> = []

    var isRecording: Bool { recordingOwner != nil }

    func request(_ action: OneLinerPendingAction) {
        pending = action
    }

    /// Returns and clears the pending action when it is one of `actions`.
    func take(_ actions: Set<OneLinerPendingAction>) -> OneLinerPendingAction? {
        guard let pending, actions.contains(pending) else { return nil }
        self.pending = nil
        return pending
    }

    func beginRecording(_ owner: UUID) {
        recordingOwner = owner
    }

    /// Only the owner ends its recording; a Stop still waiting for that take goes with it.
    func endRecording(_ owner: UUID) {
        guard recordingOwner == owner else { return }
        recordingOwner = nil
        if pending == .stopRecording { pending = nil }
    }

    func captureAppeared(_ id: UUID) {
        openCaptures.insert(id)
    }

    func captureDisappeared(_ id: UUID) {
        openCaptures.remove(id)
    }

    /// Nil leaves the action pending (a Stop with no capture open waits for none).
    static func handler(for action: OneLinerPendingAction, screenPresented: Bool, captureOpen: Bool) -> Handler? {
        if captureOpen { return .capture }
        if action == .stopRecording { return nil }
        return screenPresented ? .screen : .root
    }

    func handler(screenPresented: Bool) -> Handler? {
        pending.flatMap { Self.handler(for: $0, screenPresented: screenPresented, captureOpen: !openCaptures.isEmpty) }
    }
}

/// Opens Writers Block already recording. The microphone needs the app in front.
struct RecordOneLinerIntent: AppIntent {
    static let title: LocalizedStringResource = "Record One Liner"
    static let description = IntentDescription("Opens Writers Block already recording a one liner.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneLinerRouter.shared.request(.record)
        return .result()
    }
}

enum OneLinerCaptureKind: String, AppEnum {
    case record
    case type

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture"
    static let caseDisplayRepresentations: [OneLinerCaptureKind: DisplayRepresentation] = [
        .record: "Record",
        .type: "Type",
    ]
}

/// Opens the capture sheet. A widget or control cannot take the words itself,
/// so its Type opens the sheet with the keyboard up.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open One Liner Capture"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Mode", default: .type)
    var mode: OneLinerCaptureKind

    init() {}

    init(mode: OneLinerCaptureKind) {
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        OneLinerRouter.shared.request(mode == .record ? .record : .type)
        return .result()
    }
}

struct OpenOneLinersIntent: AppIntent {
    static let title: LocalizedStringResource = "Open One Liners"
    static let description = IntentDescription("Opens your one liners in Writers Block.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneLinerRouter.shared.request(.open)
        return .result()
    }
}

/// The Live Activity's Done. Runs in the app: a take being recorded is stopped
/// and saved; with nothing recording (the app was not running) the activity just ends.
struct StopOneLinerRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop One Liner Recording"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if OneLinerRouter.shared.isRecording {
            OneLinerRouter.shared.request(.stopRecording)
        } else {
            await OneLinerActivityAttributes.endAll()
        }
        return .result()
    }
}
