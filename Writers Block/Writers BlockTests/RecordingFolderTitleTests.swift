// The iOS recordings drawer's folder titles; ProjectsDrawerView is not in the Mac app.
#if !os(macOS)
import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// The drawer's Recordings tab names each song folder from the songs list. Song
/// IDs are not unique once CloudKit has synced two copies, so the title lookup
/// must not trap and must pick the same title for the same data every time.
struct RecordingFolderTitleTests {
    @MainActor
    private static func insert(_ projects: [SongProject]) throws -> ModelContainer {
        let schema = Schema([SongProject.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        projects.forEach { container.mainContext.insert($0) }
        try container.mainContext.save()
        return container
    }

    @MainActor
    @Test func duplicateSongIDsGiveOneFolderNamedByTheNewestRow() throws {
        let older = SongProject(id: "song-1", title: "Harbour Lights", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = SongProject(id: "song-1", title: "Harbour Lights (Phone)", updatedAt: Date(timeIntervalSince1970: 2_000))
        let container = try Self.insert([older, newer])

        #expect(ProjectsDrawerView.recordingFolderTitles(for: [older, newer]) == ["song-1": "Harbour Lights (Phone)"])
        #expect(ProjectsDrawerView.recordingFolderTitles(for: [newer, older]) == ["song-1": "Harbour Lights (Phone)"])
        _ = container
    }

    @MainActor
    @Test func duplicateSongIDsWithTheSameTimeBreakTheTieByTitle() throws {
        let when = Date(timeIntervalSince1970: 1_000)
        let first = SongProject(id: "song-1", title: "Beta", updatedAt: when)
        let second = SongProject(id: "song-1", title: "Alpha", updatedAt: when)
        let container = try Self.insert([first, second])

        #expect(ProjectsDrawerView.recordingFolderTitles(for: [first, second]) == ["song-1": "Alpha"])
        #expect(ProjectsDrawerView.recordingFolderTitles(for: [second, first]) == ["song-1": "Alpha"])
        _ = container
    }

    @MainActor
    @Test func uniqueSongIDsMapToTheirOwnTitlesAndEmptyTitlesAreUntitled() throws {
        let named = SongProject(id: "song-1", title: "Harbour Lights")
        let unnamed = SongProject(id: "song-2", title: "")
        let container = try Self.insert([named, unnamed])

        #expect(ProjectsDrawerView.recordingFolderTitles(for: [named, unnamed]) == ["song-1": "Harbour Lights", "song-2": "Untitled Song"])
        _ = container
    }
}
#endif
