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

    @Test
    func typeIntentSavesTheLineWithoutTheApp() async throws {
        // Given
        let container = try Self.makeContainer()
        let original = TypeOneLinerIntent.container
        TypeOneLinerIntent.container = { container }
        defer { TypeOneLinerIntent.container = original }

        // When
        _ = try await TypeOneLinerIntent(text: "  Found the Lord in a gas station bathroom \n").perform()

        // Then: saved, so another context reads it, with its prosody
        let lines = try ModelContext(container).fetch(FetchDescriptor<OneLiner>())
        #expect(lines.map(\.text) == ["Found the Lord in a gas station bathroom"])
        #expect(lines.first?.syllableCount == 10)
        #expect(lines.first?.audioFileName == nil)
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

        router.isRecording = true
        defer { router.isRecording = false }
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
    func pendingActionsOpenTheRightCapture() {
        #expect(OneLinersRoute(action: .record)?.capture?.id == "record")
        #expect(OneLinersRoute(action: .type)?.capture?.id == "type")
        let open = OneLinersRoute(action: .open)
        #expect(open != nil)
        #expect(open?.capture == nil)
        #expect(OneLinersRoute(action: .stopRecording) == nil)
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
    func launchArgumentNamesTheAction() {
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "record"]) == .record)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "open"]) == .open)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction"]) == nil)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app", "-oneLinerPendingAction", "sing"]) == nil)
        #expect(OneLinerPendingAction.fromLaunchArguments(["app"]) == nil)
    }
}
