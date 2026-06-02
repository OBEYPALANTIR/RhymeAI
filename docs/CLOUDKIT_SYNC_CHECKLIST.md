# CloudKit Sync Verification Checklist

This is the live Day 5 sync gate for Writers Block. It requires two iOS simulators
or one simulator plus one device signed into the same iCloud account for the
private CloudKit container `iCloud.ShaydeTree.Writers-Block`.

## Static Readiness

Run this first from `/Users/tylermanring/Documents/RhymeAI`:

```sh
./scripts/ios-cloudkit-readiness.sh
```

The script verifies:

- `Writers_BlockApp.swift` uses `cloudKitDatabase: .private("iCloud.ShaydeTree.Writers-Block")`.
- `Writers Block.entitlements` includes the expected iCloud container and `CloudKit` service.
- `Writers-Block-Info.plist` and the built app include `UIBackgroundModes = remote-notification`.
- CloudKit-backed SwiftData models do not use `@Attribute(.unique)`.
- `TrashLifecycleTests` pass for duplicate active/trash rows and purge behavior.

## Live Matrix

Use stable test titles with timestamps so synced rows are easy to distinguish.
Record the simulator/device names, OS versions, Apple ID state, and approximate
sync latency for each check.

1. Create propagation
   - On device A, create `CloudKit Create <timestamp>` with two lyric lines.
   - Wait for device B to show the song without restarting the app.
   - Pass: title, lyrics, theme, and updated timestamp converge with no duplicate row.

2. Edit propagation
   - On device B, edit the title and append one lyric line.
   - Wait for device A to show the edit.
   - Pass: both devices show the same final title and lyric body.

3. Concurrent edit convergence
   - Open the same song on both devices.
   - On A, edit the title. On B, edit the lyrics before A's change appears.
   - Let both devices reconnect/idle until CloudKit settles.
   - Pass: one logical song remains on both devices; no duplicate active rows appear.
   - Note: SwiftData/CloudKit is last-writer-style at the record field level. If one
     side's field loses the race, log it as expected conflict behavior, not data loss,
     only if no duplicate or crash occurs.

4. Offline edit reconnect
   - Disable network on device B.
   - Edit an existing song on B, then re-enable network.
   - Pass: B's edit reaches A, both devices converge, and the app does not spinner-loop
     or crash while offline.

5. Delete propagation
   - On A, move a synced song to Trash.
   - Pass: B removes it from active projects and shows one matching trash row.

6. Trash restore propagation
   - On B, restore the trashed song.
   - Pass: A shows one active restored song and no stale trash duplicate.

7. Permanent delete propagation
   - On A, permanently delete a trash row.
   - Pass: B eventually removes the same trash row and no active project reappears.

8. Expiry/purge sanity
   - Run `TrashLifecycleTests` through the readiness script after live checks.
   - Pass: local purge behavior still removes only expired trash entries.

## Current Status

As of 2026-06-02, `./scripts/ios-cloudkit-readiness.sh` passes and verifies the
static CloudKit container, entitlements, background mode, build, and trash
conflict tests. `./scripts/remaining-live-gates-preflight.sh` can check the live
matrix prerequisites without printing account values. The latest preflight booted
two iOS 26.5 simulators, but neither had a `MobileMeAccounts` account record and
both failed `simctl icloud_sync` with `BRCloudDocsErrorDomain` code `153`, so the
live two-device matrix still needs an iCloud-signed-in simulator/device pair. Do
not mark CloudKit complete until every live matrix item above has current
evidence.
