<p align="center">
  <img src="docs/assets/vmodal-swift-iphone-duo.png" alt="VModal video search and editing SDK" width="100%">
</p>

<h1 align="center">VModalSDK for Apple platforms</h1>

<p align="center">
  The Swift-native video workflow for apps that need to upload, index, and find the exact moment.<br>
  Built for iOS, macOS, and SwiftUI with Swift concurrency and Xcode 26.6.
</p>

<p align="center">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
  <img alt="iOS 16 or newer" src="https://img.shields.io/badge/iOS-16%2B-111111?logo=apple">
  <img alt="macOS 13 or newer" src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple">
  <img alt="Version 1.2.3" src="https://img.shields.io/badge/release-1.2.3-0A84FF">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-34C759">
</p>

VModalSDK 1.2.3 gives Apple apps a polished, strongly typed path from camera
roll to searchable moments. Build fluid SwiftUI experiences with `async/await`,
live upload progress, cancellation, key rotation, and immutable collection
scopes that keep every request aimed at the right video stream.

Whether you are building a camera companion, editorial tool, field workflow,
or a video-first consumer app, VModalSDK keeps the networking layer small,
predictable, and unmistakably Swift.

# Install with one prompt

On a Mac with Xcode 26.6 or newer and an available iPhone simulator, paste this
into Terminal. It clones the public package, resolves its dependencies, builds
`Examples/StarterIOS`, boots an available iPhone simulator, installs the app,
and launches the demo.

```bash
git clone --depth 1 https://github.com/v-modal/vmodal_sdk_swift_iphoneduo.git && cd vmodal_sdk_swift_iphoneduo && bash install.sh check && bash run.sh example --device "$(bash install.sh device_id)"
```

`install.sh` validates your selected Xcode toolchain; it deliberately does not
download or switch Xcode. To launch StarterIOS again from the cloned public
repository, run:

```bash
cd vmodal_sdk_swift_iphoneduo
bash run.sh example --device "$(bash install.sh device_id)"
```

## Quick start

### 1. Authenticate

In Xcode, choose **File → Add Package Dependencies…**, paste
`https://github.com/v-modal/vmodal_sdk_swift_iphoneduo`, and attach the
`VModalSDK` product to your app target. That is all your app needs to begin.

Gateway mode is the standard application configuration. The provider is read
before every request, so a rotated credential takes effect immediately without
rebuilding the client.

```swift
import VModalSDK

let keys = try MutableAPIKeyProvider("your-bearer-token")
let project = try VModal.configure(
    projectID: "demo",
    apiKeyProvider: keys
)
```

Environment bootstrap accepts `VMODAL_API_KEY`, derives the gateway URL from
`VMODAL_ENV`, and resolves identity through `auth/me` when necessary:

```swift
let client = try await VModalClient.fromEnvironment(
    ProcessInfo.processInfo.environment
)
```

Never log configuration values, providers, authorization headers, signed URLs,
or server error bodies. Direct mode is deliberately named `unsafeDirect` and
requires an explicit backend identity.

### 2. List collections

```swift
let names = try await project.listCollections()
```

Create one immutable scope and reuse it. Upload, search, and indexing will then
share exactly the same backend collection and stream mapping.

```swift
let videos = try project.scope(
    collectionName: "field-notes",
    streamName: "camera-a"
)
```

### 3. List index jobs

```swift
let jobs = try await videos.listIndexJobs()
```

## Upload. Index. Find the moment.

Uploads start immediately and expose a coalesced `AsyncStream` of progress—an
easy fit for a SwiftUI `ProgressView`. File content is replayable when a retry
is safe, while gateway credentials never travel to the signed upload
destination.

```swift
let source = try UploadSource(fileURL: movieURL)
let upload = videos.upload(source)

Task {
    for await update in upload.progress {
        print("uploaded \(update.percent)%")
    }
}

let uploaded = try await upload.result
let matches = try await videos.search("red delivery van")
```

| Capability | SDK behavior |
|---|---|
| Authentication | Bearer-token gateway mode with runtime rotation |
| Collections | Project-level discovery and immutable scoped operations |
| Uploads | Replayable file sources, progress streams, and signed destinations |
| Search | Async scoped video and frame search |
| Indexing | Create, inspect, list, and cancel jobs |
| Reliability | Typed failures, retry policy, cancellation, and idempotent close |

Cancel one operation without poisoning unrelated requests:

```swift
let cancellation = CancellationToken()
let work = Task {
    try await videos.search("loading dock", cancellation: cancellation)
}

await cancellation.cancel()
_ = try? await work.value
```

Rotate or revoke credentials explicitly:

```swift
try await keys.rotate("replacement-token")
await keys.clear()
```

The project owns its client. Close it once when the owning scene or session
ends. `close()` is idempotent and closes control and signed-upload transports.

```swift
await project.close()
```

## Designed for SwiftUI

The included [`Examples/StarterIOS`](Examples/StarterIOS) project is not a
throwaway sample. It keeps one `@MainActor` session owner, places work in
cancelable tasks, and uses an adaptive `NavigationSplitView`. Upload ownership
is separate from view geometry, so ordinary scene resizing does not recreate
an operation. Open
[`Examples/StarterIOS/StarterIOS.xcodeproj`](Examples/StarterIOS/StarterIOS.xcodeproj)
to explore a compact production-style integration.

```swift
@main
struct StarterIOSApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
```

The iPhone Duo/Xcode 27.1 acceptance work is preserved as commented future code.
See the [feature and restoration guide](docs/iphone_duo.md) and the
[deferred acceptance matrix](docs/iphone_duo_acceptance.md).

<!-- FUTURE_IPHONE_DUO_XCODE_27_1
Restore explicit folded/unfolded, Split View, multi-scene, cancellation, and
upload-continuity claims after the exact iPhone Duo simulator gate is restored.
-->

## Reference and package layout

- [Complete operation parity reference](Sources/VModalSDK/VModalSDK.docc/APIReference.md)
- [Public Swift package repository](https://github.com/v-modal/vmodal_sdk_swift_iphoneduo)
- [`Sources/VModalSDK`](Sources/VModalSDK) — client, resources, models, uploads, and transport
- [`Examples/StarterIOS`](Examples/StarterIOS) — adaptive SwiftUI starter application
- [`Tools`](Tools) — route sync, release manifest, simulations, and live checks

## Verify locally

```bash
bash install.sh check
bash cli.sh routes_check
bash build.sh analyze
bash test.sh test
bash test.sh sim
bash test.sh ios
bash security_check.sh all
```

Live calls are opt-in. Source the repository test environment and run
`bash test.sh live` or `bash test.sh cctv_live`. Offline tests never require a
credential. `env.sh` derives `VMODAL_LIVE_FILE` and `VMODAL_CCTV_FILE` from the
checked-in Flutter video fixture in this monorepo; public-package users set
those paths explicitly.

Multipart upload remains experimental and opt-in. Disabled endpoints throw
`FeatureDisabledError` locally before making a network request.

## License

VModalSDK is available under the [MIT License](LICENSE).
