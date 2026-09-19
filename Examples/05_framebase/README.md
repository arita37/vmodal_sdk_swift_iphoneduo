# Framebase for iPhone and iPad

Framebase is a native SwiftUI port of the Flutter street-footage example. It
ships three local recordings, imports one MP4 at a time, prepares the fixed
`framebase_streets` / `street_study` scope, searches indexed frames, and plays
only app-private local media.

The app requires iOS 16, Swift 6, Xcode 26.6, and the local `VModalSDK` package.
No credential is bundled or persisted. Enter an API key at runtime through
**Search settings**; replacing or disconnecting a key closes the prior SDK
client and clears the in-memory provider.

```bash
bash build.sh framebase_ios
bash test.sh framebase_ios
bash run.sh framebase --device "$(bash install.sh device_id)"
```

The archive persists only clips, the pending index job identifier, the account
identifier, and at most 40 history events under Application Support/Framebase.
Imported picker URLs are copied while security-scoped access is valid. Search
rows, signed frame locators, frame bytes, SDK objects, cancellation handles,
player state, and credentials stay in memory.

The app uses `VModalClient` directly so the existing raw collection name is not
project-prefixed. Uploads are sequential and cancelable; a submitted index job
can be stopped locally and resumed after relaunch. Bulk image responses are
joined through validated `input_index` values without changing ranked search
order, and a missing image leaves its match visible.

Media and font licenses are documented in [MEDIA_SOURCES.md](MEDIA_SOURCES.md).
The files are exact copies of the Flutter example assets.
