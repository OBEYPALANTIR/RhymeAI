# Final Sign-Off Status

Last updated: 2026-06-27.

## Current Local Evidence

Commands were run from `/Users/tylermanring/Developer/RhymeAI` unless a subdirectory is noted.

Passed:

- Android debug compile/lint/unit gate from `android/`:
  `./gradlew :app:compileDebugKotlin :app:lintDebug :app:testDebugUnitTest`.
- Android targeted sync gate from `android/`:
  `./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.data.sync.*'`.
- Android release build/signing gate from `android/`:
  `./gradlew :app:assembleRelease`, producing a signed
  `android/app/build/outputs/apk/release/app-release.apk`.
- Android release identity check:
  `aapt dump badging android/app/build/outputs/apk/release/app-release.apk`
  reported `versionName='1.0'`, `versionCode='3'`, and application label
  `Writers Block`.
- Android release APK signature check:
  `apksigner verify --print-certs android/app/build/outputs/apk/release/app-release.apk`
  reported signer certificate `CN=RhymeAI Local Release Smoke`.
- Android release smoke:
  `./scripts/android-release-smoke.sh`.
- Android release walkthrough:
  `./scripts/android-release-walkthrough.sh` passed on `emulator-5554`
  through create, save, no-key suggestion, export surface, force-stop, reopen,
  and persisted lyrics.
- iOS release simulator build/key scan with live launch/archive skipped:
  `IOS_DESTINATION='generic/platform=iOS Simulator' SKIP_SIM_LAUNCH=1 SKIP_ARCHIVE=1 ./scripts/ios-release-smoke.sh`.
- iOS simulator compile gate:
  `xcodebuild build -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'generic/platform=iOS Simulator'`
  returned `** BUILD SUCCEEDED **`.
- iOS test build gate:
  `xcodebuild build-for-testing -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'generic/platform=iOS Simulator' -parallel-testing-enabled NO`
  returned `** TEST BUILD SUCCEEDED **`.

Blocked locally:

- Concrete iOS simulator tests and launch-dependent iOS smoke scripts remain
  owner-blocked by the local Xcode/CoreSimulator component mismatch after the
  approved first-launch remediation attempt. Fresh 2026-06-27 evidence:
  `/Library/Developer/PrivateFrameworks/CoreSimulator.framework` still reports
  `CFBundleShortVersionString=1051.54` / `CFBundleVersion=1051.54`;
  `xcodebuild -checkFirstLaunchStatus` prints `xcodebuild: ok` but exits `69`;
  `xcrun simctl list devices` still emits
  `Install Failed: Authorization is required to install the packages.`
- The owner-authorized installer remains required. Agent attempts cannot satisfy
  the auth prompt: `osascript ... with administrator privileges` returned
  `The administrator user name or password was incorrect. (-60007)`, and
  `sudo -n xcodebuild -runFirstLaunch` returned `sudo: a password is required`.
  Owner must run `sudo xcodebuild -runFirstLaunch` interactively, or accept
  Xcode's GUI "install additional components" prompt, before simulator tests can
  be re-run.
- Full iOS archive/release-smoke archive path is also blocked locally by
  signing access: `CodeSign failed with a nonzero exit code` /
  `errSecInternalComponent`; unlock/update the login keychain partition list
  before running the archive branch.

## Remaining Owner-Run Gates

Final production sign-off still needs current live/console evidence for:

- G1 — Google Drive OAuth clients: create Android and iOS OAuth clients, enable
  Drive API with `drive.appdata`, populate `Writers Block/Secrets.xcconfig`,
  then run the manual backup/restore and cross-platform round trip in
  `docs/CLOUD_BACKUP_SETUP.md`.
- G2 — BYO-key provider smoke:
  `export OPENAI_TEST_KEY=... CLAUDE_TEST_KEY=...; ./scripts/provider-live-smoke.sh`.
- G3 — iCloud two-device sync matrix:
  complete `docs/CLOUDKIT_SYNC_CHECKLIST.md` on two iCloud-signed-in devices or
  simulators after fixing the local CoreSimulator mismatch.
- G4 — Apple Developer/App Store Connect:
  confirm App ID `ShaydeTree.Writers-Block` has iCloud/CloudKit container
  `iCloud.ShaydeTree.Writers-Block` on a distribution profile, then create the
  listing, screenshots, and privacy policy.
- G5 — Rotate the live debug Gemini key if any `artifacts/*debug*.apk` was
  shared externally.
- G6 — Submit signed artifacts:
  Android release AAB and iOS Archive to the stores.

Do not mark production sign-off complete until the blocked simulator gates and
all owner-run live/console gates above have current passing evidence.
