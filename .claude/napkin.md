# Napkin

## Corrections
| Date | Source | What Went Wrong | What To Do Instead |
|------|--------|----------------|-------------------|
| 2026-08-25 | self/user | Reported SRTKit as unavailable after only checking the stale manifest path | Search the local Developer workspace for moved sibling packages before proposing a workaround; SRTKit lives at `../SRTKit`. |
| 2026-08-25 | self | Named an upload `URLRequest` local `request`, shadowing the probe helper and causing a compile error | Use an explicit helper name such as `performRequest` when a same-domain local value is likely. |
| 2026-08-25 | self | Derived request throughput from `Date` duration, which can be exactly zero for immediate operations and omitted expected metrics | Use `ContinuousClock` for elapsed performance timing; keep wall-clock `Date` only for trace timestamps. |
| 2026-08-25 | self | Tried to pass an `@main` Swift smoke test to `swiftc` through stdin; it linked without a `_main` symbol | Use an explicit temporary `.swift` file for `@main` smoke executables. |
| 2026-08-25 | self | Described a smaller utility-priority speed probe as necessarily “less bursty,” which can imply a guaranteed lower peak CPU | Say that smaller transfers reduce total work and burst duration; task priority is scheduling guidance, not a CPU throttle, so measure peak CPU separately. |
| 2026-08-25 | self | Tried to launch the example simulator app with a guessed bundle identifier after already having the built product available | Read `PRODUCT_BUNDLE_IDENTIFIER` from the project before invoking `simctl launch`; the example uses `com.vast.crew.ExampleApp`. |
| 2026-08-25 | self | Selected a booted iOS 26.2 simulator for UI tests whose generated target requires iOS 26.4 | Check both the test target deployment floor and simulator runtime before starting `xcodebuild test`; use the installed iOS 26.5 runtime here. |

## User Preferences
- Wants TelemetryHub to expose a rich, practical set of real network and performance statistics, with a demo backed by real network/data sources rather than weak synthetic-only activity.

## Patterns That Work
- Keep active bandwidth probes manual by default and make data sizes explicit; users should not incur recurring network usage merely by registering a source.
- Keep full-throughput probes user-initiated. Continuous monitoring should use a separately tagged lightweight profile so it reduces CPU/data cost without contaminating full-test rolling averages.
- Keep full charts on drill-down screens; instantiating Swift Charts in every live metric row amplifies telemetry updates and can make the dashboard materially affect its own CPU readings.
- For Apple-only gRPC demo traffic, depend directly on the NIO Transport Services product instead of the HTTP/2 umbrella product so the app does not build/link the unused POSIX/NIOSSL backend.
- Verify gRPC tracing through an in-process interceptor lifecycle test and an opt-in live UI probe; a recorder-only unit test does not prove interceptor stream termination behavior.
- Pair raw transport/HTTP metrics with rolling summaries and a compact network overview so the richer data remains usable.
- Verify telemetry collectors at three levels: direct Swift 6 type-check, package tests, and a live endpoint smoke run that asserts emitted metric names; also build the example scheme to catch app isolation/project-reference issues.

## Patterns That Don't Work
- A local package path can become stale after sibling repos move; verify nearby checkouts before assuming the dependency is absent.
- Do not detect package-relative artifacts with a working-directory-relative `FileManager` path in a SwiftPM manifest; dependent Xcode builds can evaluate the manifest from another directory and choose the wrong fallback.

## Domain Notes
- Swift package with core `TelemetryHub`, UI, and optional SRT/Sentry/gRPC/LiveKit/NIO integration targets plus an iOS example app.
- Package tools/language mode is Swift 6.3/Swift 6. The example app target opts into main-actor default isolation, while library targets do not declare default isolation.
- Local SRTKit checkout is `/Users/alexchase/Developer/SRTKit`; TelemetryHub should reference it as `../SRTKit`.
- SRTKit includes macOS, iOS-device, and iOS-simulator libsrt slices. Its manifest must resolve the bundled artifact existence check from `#filePath`, or TelemetryHub's Xcode project falls back to Homebrew's macOS-only dylib.
