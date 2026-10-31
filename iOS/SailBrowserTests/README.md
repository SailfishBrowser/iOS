# SailBrowserTests

Swift Testing suites, hosted in the app process: `Bundle.main` is the app, with its rule lists and manifest. Saved
files in earlier formats are described in `Fixtures/README.md`.

## What is tested

Only logic and persistence whose loss would go unnoticed in use: the stores and their saved files (`BrowserStore`,
`HistoryStore`, `SessionStore`, `SnapshotStore`, `FaviconStore`, `DownloadStore`, `DebouncedWriter`, and the earlier
saved-state formats), private tabs never reaching disk, the archive policy and grouping, URL handling (`InputResolver`,
`TrackingParams`, `SearchEngine`, `ExternalLinks`, tab export and import), the suggestion ranker, model and service,
load-error classification, the reader document's escaping, the bundled blocking lists and PageShield data, and the
connectivity and energy policies.

Views, gestures, animations, materials, layout, haptics and anything that drives a live web view are left to the
running app. A new test belongs here only if it guards such a contract and depends on none of those.

## Rule: no real host

A test never reaches a host outside the process. URL sessions are stubbed with a `URLProtocol` (`StubSuggestProtocol`,
`StubIconProtocol`), and `LocalPageServer` is a loopback server for the one test that must see bytes on the wire.
Waits are `waitUntil` on a condition, never a sleep that waits out a product constant.

## Shared helpers

- `TestSupport.swift`: `waitUntil`.
- `TestDirectories.swift`: `AppDirectories.temporary()`, a fresh root under the temporary directory per call.
- `BrowserStoreTests.swift`: `TestClock`.
- `SavedStateFixtureTests.swift`: `fixtureData(_:)` and `FixtureBundle`.
- `SuggestionServiceTests.swift`: `StubSuggestProtocol`, `HeldSleep`, `stubService(language:sleep:)`.
- `LocalPageServer.swift`: a loopback HTTP server answering each path from its route.
