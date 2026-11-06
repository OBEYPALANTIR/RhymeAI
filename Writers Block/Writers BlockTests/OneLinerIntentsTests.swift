import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// Serialized: the Type intent's container is a static the tests swap.
@MainActor
@Suite(.serialized)
struct OneLinerIntentsTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self,
            Recording.self, OneLiner.self, TrashedOneLiner.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Points the Type intent's snapshot at a temporary file for one test.
    private static func useTemporarySnapshot() -> (url: URL, restore: () -> Void) {
        let original = TypeOneLinerIntent.snapshotURL
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intent-snapshot-\(UUID().uuidString).json")
        TypeOneLinerIntent.snapshotURL = { url }
        return (url, {
            TypeOneLinerIntent.snapshotURL = original
            try? FileManager.default.removeItem(at: url)
        })
    }

    @Test
    func typeIntentSavesTheLineWithoutTheApp() async throws {
        // Given
        let container = try Self.makeContainer()
        let original = TypeOneLinerIntent.container
        TypeOneLinerIntent.container = { container }
        defer { TypeOneLinerIntent.container = original }
        let snapshot = Self.useTemporarySnapshot()
        defer { snapshot.restore() }

        // When
        _ = try await TypeOneLinerIntent(text: "  Found the Lord in a gas station bathroom \n").perform()

        // Then: saved, so another context reads it, with its prosody
        let lines = try ModelContext(container).fetch(FetchDescriptor<OneLiner>())
        #expect(lines.map(\.text) == ["Found the Lord in a gas station bathroom"])
        #expect(lines.first?.syllableCount == 10)
        #expect(lines.first?.audioFileName == nil)
        #expect(OneLinersSnapshot.read(from: snapshot.url)?.lines.first?.text == "Found the Lord in a gas station bathroom")
    }

    @Test
    func typeIntentSavesNothingWhenTheLibraryIsUnavailable() async throws {
        let original = TypeOneLinerIntent.container
        TypeOneLinerIntent.container = { nil }
        defer { TypeOneLinerIntent.container = original }

        await #expect(throws: OneLinerIntentError.self) {
            _ = try await TypeOneLinerIntent(text: "Half a heart still beats on time").perform()
        }
    }

    @Test
    func typeIntentAsksAgainForABlankLine() async throws {
        // Given
        let container = try Self.makeContainer()
        let original = TypeOneLinerIntent.container
        TypeOneLinerIntent.container = { container }
        defer { TypeOneLinerIntent.container = original }
        let snapshot = Self.useTemporarySnapshot()
        defer { snapshot.restore() }

        // When
        await #expect(throws: (any Error).self) {
            _ = try await TypeOneLinerIntent(text: "   ").perform()
        }

        // Then
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<OneLiner>()) == 0)
    }

    @Test
    func intentsHandTheAppTheMatchingAction() async throws {
        // Given
        let router = OneLinerRouter.shared
        _ = router.take(Set(OneLinerPendingAction.allCases))

        // When / Then
        _ = try await RecordOneLinerIntent().perform()
        #expect(router.take([.record]) == .record)
        _ = try await OpenCaptureIntent(mode: .type).perform()
        #expect(router.take([.type]) == .type)
        _ = try await OpenCaptureIntent(mode: .record).perform()
        #expect(router.take([.record]) == .record)
        _ = try await OpenOneLinersIntent().perform()
        #expect(router.take([.open]) == .open)

        let owner = UUID()
        router.beginRecording(owner)
        defer { router.endRecording(owner) }
        _ = try await StopOneLinerRecordingIntent().perform()
        #expect(router.take([.stopRecording]) == .stopRecording)
    }

    @Test
    func routerHandsEachActionOnlyToTheViewThatTakesIt() {
        let router = OneLinerRouter()
        router.request(.stopRecording)

        // The screen does not take a Stop; the capture sheet does, once.
        #expect(router.take([.record, .type, .open]) == nil)
        #expect(router.pending == .stopRecording)
        #expect(router.take([.stopRecording]) == .stopRecording)
        #expect(router.take([.stopRecording]) == nil)

        // A newer request replaces one nobody took yet.
        router.request(.open)
        router.request(.record)
        #expect(router.take([.record, .type, .open]) == .record)
        #expect(router.pending == nil)
    }

    @Test
    func aSecondRequestWhileACaptureIsOpenNeverReplacesIt() {
        // Nothing up: the root presents the screen; once it is up, the screen opens the capture.
        #expect(OneLinerRouter.handler(for: .record, screenPresented: false, captureOpen: false) == .root)
        #expect(OneLinerRouter.handler(for: .record, screenPresented: true, captureOpen: false) == .screen)
        #expect(OneLinerRouter.handler(for: .open, screenPresented: true, captureOpen: false) == .screen)
        // A capture open anywhere takes every request, so neither the root nor the screen replaces it.
        for action in [OneLinerPendingAction.record, .type, .open, .stopRecording] {
            #expect(OneLinerRouter.handler(for: action, screenPresented: true, captureOpen: true) == .capture)
            #expect(OneLinerRouter.handler(for: action, screenPresented: false, captureOpen: true) == .capture)
        }
        // A Stop with no capture open waits for none.
        #expect(OneLinerRouter.handler(for: .stopRecording, screenPresented: false, captureOpen: false) == nil)

        let router = OneLinerRouter()
        let capture = UUID()
        router.captureAppeared(capture)
        router.request(.record)
        #expect(router.handler(screenPresented: true) == .capture)
        #expect(ContentView.oneLinersCoverStep(
            handler: router.handler(screenPresented: true), restoreOfferShown: false, sheetShown: false
        ) == .none)
        router.captureDisappeared(capture)
        #expect(router.handler(screenPresented: true) == .screen)
    }

    @Test
    func theRootPresentsOnlyWhenNothingBlocksIt() {
        #expect(ContentView.oneLinersCoverStep(handler: .root, restoreOfferShown: false, sheetShown: false) == .present)
        #expect(ContentView.oneLinersCoverStep(handler: .root, restoreOfferShown: false, sheetShown: true) == .closeSheetsFirst)
        #expect(ContentView.oneLinersCoverStep(handler: .root, restoreOfferShown: true, sheetShown: true) == .wait)
        #expect(ContentView.oneLinersCoverStep(handler: .screen, restoreOfferShown: false, sheetShown: false) == .none)
        #expect(ContentView.oneLinersCoverStep(handler: nil, restoreOfferShown: false, sheetShown: false) == .none)

        // The root does not take the request, so it is still there for the screen once it appears.
        let router = OneLinerRouter()
        router.request(.type)
        #expect(router.handler(screenPresented: false) == .root)
        #expect(router.pending == .type)
        #expect(router.take([.record, .type, .open]) == .type)
    }

    @Test
    func onlyTheRecordingOwnerEndsItsRecording() {
        let router = OneLinerRouter()
        let recording = UUID()
        router.beginRecording(recording)
        router.request(.stopRecording)

        // Another recorder's teardown (a Type sheet closing) changes nothing.
        router.endRecording(UUID())
        #expect(router.isRecording)
        #expect(router.recordingOwner == recording)
        #expect(router.pending == .stopRecording)

        // The owner's end clears it, and the Stop that was waiting for that take.
        router.endRecording(recording)
        #expect(!router.isRecording)
        #expect(router.pending == nil)
    }

    @Test
    func aLongTranscriptStaysWellUnderTheActivityLimit() throws {
        let transcript = String(repeating: "Found the Lord in a gas station bathroom ", count: 125).prefix(5_000)
        #expect(transcript.count == 5_000)
        let levels = (0..<OneLinerRecorder.levelCount).map { Float($0) / 7 }
        let state = OneLinerLiveActivity.contentState(phase: .recording, transcript: String(transcript), levels: levels)

        #expect(try JSONEncoder().encode(state).count < 1_024)
        #expect(state.transcript.hasSuffix(transcript.suffix(200)), "The newest words are kept")
        #expect(state.transcript.hasPrefix("…"))

        // Wide characters are bounded by bytes, not characters.
        let wide = OneLinerLiveActivity.contentState(phase: .recording, transcript: String(repeating: "🎤", count: 5_000), levels: [])
        #expect(try JSONEncoder().encode(wide).count < 1_024)

        let short = OneLinerLiveActivity.contentState(phase: .saved, transcript: "Half a heart", levels: [0.123_456])
        #expect(short.transcript == "Half a heart")
        #expect(short.levels == [0.12])
    }

    @Test
    func theLibraryStaysInApplicationSupport() {
        let schema = Schema([OneLiner.self, TrashedOneLiner.self])
        for configuration in [
            ModelContainerBootstrap.cloudKitConfiguration(schema: schema),
            ModelContainerBootstrap.localConfiguration(schema: schema),
        ] {
            let path = configuration.url.path
            #expect(path.contains("/Library/Application Support/"), "\(path)")
            #expect(!path.contains("/Shared/AppGroup/"), "\(path)")
        }
    }

    @Test
    func linksParseToTheThreeRoutes() throws {
        func action(_ link: String) -> OneLinerPendingAction? {
            URL(string: link).flatMap(OneLinerPendingAction.init(url:))
        }
        #expect(action("writersblock://one-liners/record") == .record)
        #expect(action("writersblock://one-liners/type") == .type)
        #expect(action("writersblock://one-liners/open") == .open)
        #expect(action("writersblock://one-liners") == .open)
        #expect(action("WritersBlock://One-Liners/Record") == .record)
        #expect(action("writersblock://one-liners/stopRecording") == nil)
        #expect(action("writersblock://one-liners/delete") == nil)
        #expect(action("writersblock://songs/record") == nil)
        #expect(action("https://one-liners/record") == nil)
        for route in [OneLinerPendingAction.record, .type, .open] {
            #expect(try action(#require(route.url).absoluteString) == route)
        }
        #expect(OneLinerPendingAction.stopRecording.url == nil)
    }

    @Test
    func liveActivityUpdatesGoAtMostEveryQuarterSecond() {
        let start = ContinuousClock.now
        #expect(OneLinerLiveActivity.delay(since: nil, now: start) == .zero)
        #expect(OneLinerLiveActivity.delay(since: start, now: start) == .milliseconds(250))
        #expect(OneLinerLiveActivity.delay(since: start, now: start + .milliseconds(100)) == .milliseconds(150))
        #expect(OneLinerLiveActivity.delay(since: start, now: start + .milliseconds(250)) == .zero)
        #expect(OneLinerLiveActivity.delay(since: start, now: start + .seconds(2)) == .zero)
    }

    @Test
    func launchArgumentNamesTheAction() {
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "record"]) == .record)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "open"]) == .open)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction"]) == nil)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "sing"]) == nil)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app"]) == nil)
    }
}
