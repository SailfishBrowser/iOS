Saved files from earlier versions of the app, kept to prove that each still loads whole. The state fixtures all hold the
same content: three tabs, the first pinned, one archived tab, one history entry and settings changed from their
defaults.

- `format1a-state.json`, `format1a-history.json` and `format1b-state.json`, `format1b-history.json`: the first
  saved-state format, written by the app's own `BrowserStore` and `HistoryStore` and flushed to disk unedited. The two
  differ only in their random ids. The archive lives inside `state.json`, and blocking is the single
  `adBlockingEnabled` switch. `SavedStateFixtureTests` checks that both load whole and that the archive moves to its
  own file.
- `format2-state.json`, `format2-archive.json`, `format2-history.json`: the second format, with the archive in its own
  `archive.json` and `state.json` carrying every settings key of that version, written by hand to match that version's
  encoder output. `SavedStateFixtureTests` checks that it loads whole, also with keys from a future version added.
- `saved-site-settings.json`: `SiteSettingsStore`'s file with three hosts with overrides, from before the camera and
  microphone settings. `SavedStateFixtureTests` checks that every host loads with both at Ask.
- `saved-downloads.json`: `DownloadRecord`s written through the `DebouncedWriter` that `DownloadStore` saves with,
  since the store makes records only from live WebKit downloads. One running, one failed and one finished record.
- `State/state-before-private-tabs.json`: a `state.json` from before private tabs. `PrivateTabsTests` checks that all
  of its tabs load as normal tabs.

The first format had no `site-settings.json`. Session files are the web view's own bytes and are
not decoded by the app, so none are kept here.
