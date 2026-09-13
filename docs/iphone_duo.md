# iPhone Duo feature guide

## Current status

iPhone Duo support is a deferred compatibility target. The active SDK release
uses Xcode 26.6 and its iOS 26.5 SDK. Duo-specific Xcode 27.1 simulator checks,
commands, and CI jobs remain in the repository as comments marked
`FUTURE_IPHONE_DUO_XCODE_27_1`; they are not part of the current release gate.

The core SDK and StarterIOS example already use the device-independent design
needed by the future target. This document separates those implemented
foundations from behavior that still requires the exact iPhone Duo simulator.

## Feature goals

### Adaptive folded and unfolded layouts

The StarterIOS interface must remain usable in each Duo presentation:

- closed portrait and closed landscape;
- open vertical and open horizontal;
- partially folded transitions;
- narrow and wide Split View allocations.

Layout decisions use the horizontal size class and the space offered by the
current container. They must not use device names, orientation checks, fixed
screen dimensions, or hinge angle. `NavigationSplitView`, `GeometryReader`,
`ScrollView`, and flexible maximum widths provide the current adaptive base.

### Safe areas and reserved regions

Interactive content must remain within every safe-area edge. Code must not
assume that left and right, or top and bottom, have symmetric insets. Background
artwork may extend beyond safe areas, but controls, labels, progress state, and
navigation must remain visible and reachable.

If Xcode 27.1 exposes Duo-only reserved-region or arrangement APIs, the example
may use them behind `if #available` checks. Standard SwiftUI containers remain
the first choice so the SDK keeps its current iOS deployment floor.

### Upload continuity

Folding, unfolding, resizing, rotating, changing Split View allocation, or
rebuilding a transient view must not start a second upload. `AppSession` owns
the active `UploadTask`, and `guard upload == nil` prevents duplicate starts.
Upload progress is observed from the same task and remains available to the UI
after a layout transition.

Cancellation applies only to the active upload. After cancellation or normal
completion, the stored task is cleared so a later upload can start. Acceptance
testing must verify that a fold or resize causes no second control request and
no second signed PUT.

### Search and request continuity

The current search owns an explicit `CancellationToken`. A geometry or scene
transition must not change the collection/stream scope, clear the query, or
cancel the request. User cancellation affects only that request, and a later
search must still succeed.

### Scene and client ownership

The core `VModalSDK` package is headless and does not import SwiftUI or UIKit.
It has no dependency on a screen, pose, safe area, window, or view lifecycle.
Long-running operations are owned explicitly by tasks rather than by a view.

StarterIOS creates `AppSession` with `@StateObject` above `WindowGroup` and
injects it into the content hierarchy. Opening or closing one view must not
implicitly close the project client used by another scene. Client shutdown is
an explicit owner action through `AppSession.close()`.

### Accessibility and state preservation

Every Duo layout must retain readable labels, accessible names for actionable
controls, and usable Dynamic Type sizing. The selected collection, stream,
search text, result count, upload progress, and status message must survive
layout and scene-phase changes.

## Implemented foundation versus deferred validation

| Capability | Current Xcode 26.6 implementation | Duo validation status |
|---|---|---|
| UI-independent networking package | Core target contains no SwiftUI/UIKit geometry logic | Implemented |
| Flexible starter layout | `NavigationSplitView`, container geometry, scrolling, and bounded flexible width | Generic iPhone simulator tested |
| No global screen assumption | Starter tests reject `UIScreen.main.bounds` | Implemented |
| Stable app session | `@StateObject` owns project, credentials, request token, and upload task | Generic simulator tested |
| Duplicate-upload protection | A second upload is rejected while one `UploadTask` is active | Implemented; Duo transition assertion deferred |
| Progress and cancellation | Progress is streamed from the owned task; upload/search cancel separately | Implemented; pose-transition validation deferred |
| Folded/unfolded geometry | Design does not depend on pose or orientation | Exact Duo simulator test deferred |
| Split View and asymmetric safe areas | Flexible layout is present | Full divider/safe-area matrix deferred |
| Two-window lifecycle | Ownership model supports explicit shared-client lifetime | Exact multi-scene test deferred |
| Background upload survival | Not claimed by the SDK | Requires a background transport and restoration design |
| Duo-specific reserved-region APIs | Not used | Reassess when the Xcode 27.1 SDK is available |

## Acceptance scenarios

The detailed result matrix is maintained in
[`iphone_duo_acceptance.md`](iphone_duo_acceptance.md). The restored gate must
cover all of the following:

1. Closed portrait: navigation and the current detail remain reachable.
2. Closed landscape: no controls clip or overflow.
3. Open vertical: columns use the available width and respect safe areas.
4. Open horizontal: content avoids reserved interactive regions.
5. Partial fold during upload: the same task and request sequence continue.
6. Split View at every divider position: compact navigation remains usable.
7. Background then foreground: visible state and progress rendering return.
8. Two windows: closing one view does not close the intended shared client.
9. Search or upload cancellation: only the selected operation is canceled.
10. Dynamic Type and VoiceOver: content remains readable and actionable.

For upload continuity, use an injected transport to count control requests and
signed PUTs. Simulator UI testing alone is insufficient to prove that work was
not duplicated.

## Preserved restoration points

The Duo-specific implementation is intentionally commented in these files:

- `install.sh`: require the iOS 27.1 runtime and detect an available iPhone Duo.
- `build.sh`: restore `sdk_duo_example` for the exact simulator UDID.
- `run.sh`: restore deterministic Duo device selection and launch.
- `test.sh`: restore the dedicated StarterIOS and package test destinations.
- `ga_release.sh`: restore `ga_duo_test` as a release gate.
- `.github/workflows/sdk_swift_apple_test_release.yml`: restore the dedicated
  `duo_compatibility` job and add it to release dependencies.
- `Tests/VModalSDKTests/DuoCompatibilityTests.swift`: restore assertions for
  the complete Duo acceptance vocabulary and test suite.

Search for `FUTURE_IPHONE_DUO_XCODE_27_1` to find the exact retained blocks.

## Restoration checklist

Restore the feature only when the CI image provides Xcode 27.1, its iOS 27.1
runtime, and an iPhone Duo simulator:

1. Update `.xcode-version` and the Xcode project metadata together.
2. Restore the toolchain/runtime checks in `install.sh`.
3. Resolve the simulator with `xcrun simctl list devices available` and use its
   UDID. Fail if no candidate exists; if multiple candidates exist, require an
   explicit `--device` value.
4. Restore `duo_example`, `run.sh duo`, `test.sh duo`, and `ga_duo_test`.
5. Restore the workflow job on an image that actually contains the required
   Xcode/runtime; do not silently substitute a generic iPhone destination.
6. Add the Duo job to `release_gate.needs` so publishing cannot bypass it.
7. Run the full acceptance matrix, including request-count assertions during
   upload transitions and explicit multi-window lifecycle checks.
8. Keep the secret-detection, offline, source-export, live, and release gates
   unchanged.

Expected restored commands:

```bash
bash install.sh device_list
bash build.sh duo_example
bash run.sh duo
bash test.sh duo
```

## Non-goals and constraints

- Do not add UI, pose, orientation, or screen dependencies to the core SDK.
- Do not calculate layout from hinge angle.
- Do not raise the package deployment floor solely for Duo UI features.
- Do not restart work because SwiftUI recreated a view.
- Do not treat a generic simulator pass as proof of Duo compatibility.
- Do not claim background upload survival until background session restoration,
  delegate callbacks, file-backed uploads, and checkpoint recovery are tested.
