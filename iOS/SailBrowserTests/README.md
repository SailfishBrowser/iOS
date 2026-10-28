# SailBrowserTests

Swift Testing suites, hosted in the app process: `Bundle.main` is the app, with its rule lists and manifest. Saved
files in earlier formats are described in `Fixtures/README.md`.

## Rule: no real host

A test never reaches a host outside the process, so a loaded simulator or a dead network cannot fail it. Pages come
from the scheme handlers (`fail://`, `hang://`, `stall://` and their controller builders in
`WebTabControllerTests.swift`), from `LocalPageServer` when the bytes must go over a socket, or from a `data:` URL
(`page(_:)`). URL sessions are stubbed with a `URLProtocol` (`StubSuggestProtocol`, `StubIconProtocol`). Waits are
`waitUntil` on a condition or a held clock, never a sleep that waits out a product constant.

## Shared helpers

- `AppEnvironmentTests.swift`: `makeEnvironment()`, `recordingHaptics()`, `page(_:)`, `RecordingPressure`,
  `ProbeHapticSink`.
- `TestDirectories.swift`: `AppDirectories.temporary()`, a fresh root under the temporary directory per call.
- `TestSupport.swift`: `expectCookieless(_:requestTimeout:resourceTimeout:)` for the app's cookieless sessions.
  Its `.timingSensitive` trait skips a test on CI (`TEST_RUNNER_SAIL_CI=1`) that checks a real-time window.
- `WebTabControllerTests.swift`: `waitUntil`, `loadAndFinish`, `finishLoading`, `finishing`, `showInWindow`,
  `settledHangingController`, `pullAndRelease`, `failingError`, the scheme handlers (`FailingSchemeHandler`,
  `HangingSchemeHandler`, `StalledSchemeHandler`, `HeldReloadSchemeHandler`, `FailingReloadSchemeHandler`) and
  `failingController`, `hangingController`, `stalledController`.
- `LocalPageServer.swift`: a loopback HTTP server with per-path routes and held connections.
- `HeldClock.swift`: holds a layer tree's animation time and steps it, for drawn values at exact times.
- `Writes.swift`: counts the writes an observation sees.
- `ContentBlockerTests.swift`: `temporaryRuleStore()`, `ruleBundle(_:)`, `adRuleBundle()`, `blockRule(_:)`.
- `ReaderExtractorTests.swift`: `ReaderFixtures`, `loadedFixture(_:)`.
