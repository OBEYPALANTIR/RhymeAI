# Writers Block

Writers Block is the native RhymeAI songwriting assistant for writing lyrics, managing songs, analyzing rhyme context, counting syllables, previewing stress/IPA, and generating AI rewrite suggestions.

The active targets are:

- Android: `android/`
- iOS: `Writers Block/`
- Desktop: planned

The old React/Vite web variant has been removed. Shared pronunciation/prosody data stays in `shared/`, with generation tooling in `scripts/`, because Android and iOS both consume those assets.

## Android

Run from `/Users/tylermanring/Documents/RhymeAI/android`:

```sh
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
```

## iOS

Use Xcode with:

```sh
Writers Block/Writers Block.xcodeproj
```

Or inspect schemes and destinations from the repo root:

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices
```

Then build or test with the confirmed scheme and simulator destination.
