# Cloud backup setup

RhymeAI uses Google Drive `appDataFolder` for user-facing backup on both Android and iOS. Backups are encrypted client-side with the user's sync passphrase before upload.

## Google Cloud project

1. Open the Google Cloud project that owns RhymeAI.
2. Enable **Google Drive API**.
3. Configure the OAuth consent screen:
   - Publishing status can remain **Testing** for personal use.
   - Add Tyler as a test user.
   - Add the scope `https://www.googleapis.com/auth/drive.appdata`.

## Android OAuth client

Create one OAuth client per signing certificate:

1. APIs & Services → Credentials → Create Credentials → OAuth client ID.
2. Application type: **Android**.
3. Package name: `com.rhymeai.app`.
4. SHA-1 fingerprint: run from the repo root:

   ```bash
   cd android
   ./gradlew signingReport
   ```

5. Register the debug SHA-1 and the release SHA-1 for `rhymeai-local-release.jks`.
6. No Android client-id constant is required in app code for the installed-app flow. If a web client is later needed for server-side validation, set `driveOauthClientId=<web_client_id>` in `android/local.properties`.

## iOS OAuth client

1. APIs & Services → Credentials → Create Credentials → OAuth client ID.
2. Application type: **iOS**.
3. Bundle ID: `ShaydeTree.Writers-Block`.
4. Copy the generated client id and reversed-client-id.
5. Add the reversed-client-id as a URL scheme in `Writers Block/Writers-Block-Info.plist`.
6. Configure the iOS app with the client id where `DriveOAuthService` reads it.

## Android project/recording sync contract

The encrypted Drive `rhymeai-projects.json` snapshot uses SyncBlob version 2
in an RAI2 envelope, matching the iOS v2/RAI2 manifest shape; native
two-platform exchange has not yet been verified. Version 1 remains readable
under RAI1 only when its JSON has no `deletions` key; version 2 requires that
key, including `[]` when there are no deletions. The decoded version must
match the authenticated envelope magic. Missing, null, mismatched, or
unsupported shapes are rejected rather than replacing a backup. Recording
payloads remain RAI1.

Android's backed-up Preferences DataStore stores permanent-deletion tombstones
separately from projects, trash, and pending local recording cleanup. Delete
Forever and expiry purge write a project tombstone in the same DataStore
transaction that removes each trashed song. These tombstones are never pruned:
merging retains the newest deletion timestamp per identity, and a project
tombstone subsumes its recording-specific tombstones. On Android v2 sync, a
tombstoned song is hidden and its recordings are no longer uploaded or
advertised by the receiving device, regardless of a later content edit
timestamp. A stale offline edit cannot revive the song in the synced list.
Android reads current local tombstones again when applying a sync result, so
a deletion committed during the network window is not lost to the older
snapshot.

Android does not yet create recording-specific tombstones when deleting an
individual recording, nor does it erase previously uploaded recording bytes
from Drive; iOS peers do erase remote bytes, so this is not symmetric.
Receiving-device local audio files and notebook data remain on disk after a
remote tombstone, pending a separate cleanup decision. Incomplete cleanup
following a local Delete Forever is tracked and retried separately.

## Manual verification

After both OAuth clients exist:

1. Android: set a sync passphrase in Settings, tap **Back Up Now**, complete Google consent, and confirm the app reports sync completion.
2. Android restore: clear app data or install on a second device, enter the same passphrase, tap **Restore**, and confirm projects, trash, and voice recordings reappear.
3. iOS: run the same backup and restore flow from Settings.
4. Cross-platform: back up on one platform and restore on the other with the same passphrase. Confirm at least one project and one `.m4a` voice recording round-trip.

If any OAuth client is missing, the code can still build and unit-test, but the live end-to-end backup gate is not complete.