# Getting Started

Authenticate, list collections, and list index jobs before starting scoped work.

```swift
let keys = try MutableAPIKeyProvider("token")
let project = try VModal.configure(projectID: "demo", apiKeyProvider: keys)
let collections = try await project.listCollections()
let scope = try project.scope(collectionName: collections[0], streamName: "camera-a")
let jobs = try await scope.listIndexJobs()
```

Upload a replayable local file and then search the same immutable scope:

```swift
let upload = scope.upload(try UploadSource(fileURL: fileURL))
let result = try await upload.result
let matches = try await scope.search("delivery van")
```

Use ``CancellationToken`` for request-local cancellation, rotate keys on
``MutableAPIKeyProvider``, and call ``VModalProject/close()`` from the owner.
The StarterIOS example shows scene ownership and flexible layouts under Xcode 26.6.

<!-- FUTURE_IPHONE_DUO_XCODE_27_1
The same ownership model is intended for future iPhone Duo layout transitions.
-->
