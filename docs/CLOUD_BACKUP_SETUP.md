# Cloud backup setup

Writers Block backs up to Google Drive's private `appDataFolder` on both Android and iOS, with the `drive.appdata` scope only. Backups are plain JSON and raw audio protected by the Google account and Drive's encryption at rest; there is no passphrase. API keys are never included.

## Google Cloud project

1. Open the Google Cloud project that owns RhymeAI.
2. Enable **Google Drive API**.
3. Configure the OAuth consent screen:
   - Add the scope `https://www.googleapis.com/auth/drive.appdata`.
   - Publish it to **Production**. While it stays in **Testing**, Google expires
     refresh tokens after 7 days, so the iOS app (which stores a refresh token)
     silently loses Drive access a week after connecting. Android is not affected
     because Play Services issues its tokens, but use one consent screen for both.
   - For personal testing before publishing, add Tyler as a test user and expect
     to reconnect iOS weekly.

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

## Backup contract (v4)

Drive holds `rhymeai-manifest.json` (plain UTF-8 JSON, `version` 4) and one raw
file per recording named `rec_<projectId>_<fileName>`, uploaded with Drive
`appProperties` `projectId`, `fileName`, `sha256` and `bytes`. The manifest's
`manifestSha256` covers its canonical form; a manifest whose hash does not match
is refused ("Backup file is damaged; it was not merged.") and never overwritten,
and so is one with a `version` above 4. The full field list, canonical rules and
merge rules are in `PARITY.md` (Cloud backup parity checks) and are pinned by
`shared/fixtures/sync-manifest-v4.json`.

- **Connect Google Drive** asks for Drive access and, if Drive already holds
  songs, offers "Restore your songs?" with Restore and Not now. The same offer
  appears at launch when Drive is connected and the library is empty.
- **Back up now** and the automatic backup (30 seconds after the last change,
  and when leaving the app) merge this device into Drive and never change local
  data. Failures retry after 1, 2, 4, 8 … minutes, capped at an hour.
- **Restore from backup** merges both ways, uploads local-only items, then
  downloads recordings this device lacks. A local recording is never replaced;
  a download whose SHA-256 does not match the manifest is discarded and counted.
  Recordings over 16 MiB are skipped with a visible count.
- **Disconnect** revokes the grant at `https://oauth2.googleapis.com/revoke`
  (Android with the current access token, iOS with the refresh token), then
  clears local state. If Google cannot be reached it still disconnects and says
  so; the grant can then be removed from the Google Account's third-party access.
- **Export all songs…** writes `WritersBlock-backup-<date>.zip` (`manifest.json`,
  `songs/<title or id>.txt`, `songs/<id>.json`, `recordings/<projectId>/<fileName>`)
  through the system save sheet, for any storage provider. **Import from file…**
  takes that zip or a bare v4 `manifest.json` and merges it.

Tombstones work as before: Delete Forever and expiry purge write a project
tombstone in the same DataStore transaction that removes the song, tombstones
are never pruned, and a tombstoned song and its recordings stay deleted even if
an older copy was edited later. Android does not erase recording bytes already
in Drive when a song is deleted; iOS does, so the platforms differ there.

## Older encrypted backups

Builds before v4 wrote a passphrase-encrypted `rhymeai-projects.json` (RAI3, or
RAI2/RAI1 from older builds) and RAI1-encrypted `rec_*.enc` recordings. The app
now only reads them, to migrate:

| Old backup in Drive | Passphrase stored on the device | What happens |
| --- | --- | --- |
| yes | yes | On the next backup: decrypt, merge into this device, write v4, download v4 again and check its hash and songs, delete the old manifest and the old recordings that reached v4, clear the passphrase. Status: "Your older encrypted backup was moved to the new format." |
| yes | no | The old files are left untouched; v4 starts from local data. Settings shows "Migrate older encrypted backup…", which asks for the passphrase once (it is not stored); cancelling keeps the row. |
| no | yes | The stored passphrase is removed. |
| no | no | Nothing to do. |

Old recordings that could not move (over 16 MiB, or failing their hash) stay in
Drive rather than being deleted.

## Manual verification

After both OAuth clients exist:

1. Android: in Settings → Backup tap **Connect Google Drive**, complete Google consent, tap **Back up now**, and confirm the status reads "Last backed up just now · Google Drive".
2. Android restore: clear app data or install on a second device, connect the same Google account, accept "Restore your songs?", and confirm projects, trash, and voice recordings reappear.
3. iOS: run the same connect, backup and restore flow from Settings.
4. Cross-platform: back up on one platform and restore on the other. Confirm at least one project and one `.m4a` voice recording round-trip.
5. Migration: on a device that still has an older encrypted backup, confirm the old `rhymeai-projects.json` disappears from `appDataFolder` only after `rhymeai-manifest.json` exists.

If any OAuth client is missing, the code can still build and unit-test, but the live end-to-end backup gate is not complete.