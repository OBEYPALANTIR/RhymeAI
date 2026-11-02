#if DEBUG
import CoreData
import Testing
@testable import Writers_Block

/// Pins the entities and attributes `--initialize-cloudkit-schema` will create
/// in the CloudKit Development schema (as `CD_<entity>` record types).
struct CloudKitSchemaInitializerTests {

    @Test func managedObjectModelHasTheSyncedEntitiesAndTheirAttributes() throws {
        let model = try #require(CloudKitSchemaInitializer.makeManagedObjectModel())

        let expected: [String: Set<String>] = [
            "SongProject": ["precedenceRepaired"],
            "TrashedSongProject": ["precedenceRepaired", "trashedAtRepaired"],
            "SyncDeletionRecord": ["projectId", "fileName", "deletedAt"],
            "SyncRecordingDeletion": ["recordingId"],
            "Recording": [
                "displayName", "displayNameChanged", "precedenceRepaired",
                "trashedAtRepaired", "fileName", "claimedName",
            ],
            "OneLiner": ["text", "createdAt", "audioFileName", "usedInProjectId", "syllableCount", "rhymeKeys", "stressPattern"],
            "TrashedOneLiner": ["text", "deletedAt", "deleteAfter", "audioFileName"],
        ]
        #expect(Set(model.entities.compactMap(\.name)) == Set(expected.keys))

        for (entity, attributes) in expected {
            let present = Set(model.entitiesByName[entity]?.attributesByName.keys.map { $0 } ?? [])
            #expect(attributes.isSubset(of: present), "\(entity) is missing \(attributes.subtracting(present))")
        }
    }
}
#endif
