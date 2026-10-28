<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/sailfish-logo-outline.svg">
    <source media="(prefers-color-scheme: light)" srcset="brand/sailfish-logo.svg">
    <img src="brand/sailfish-logo.svg" alt="Sail" width="140">
  </picture>
</p>

<h1 align="center">Sail</h1>

<p align="center"><b>The Open-Source Alternative to Arc.</b></p>

<p align="center">
  Sail is Sailfish for iPhone: the same calm, fast browser, in your pocket. Swipe along the bottom bar to move
  between tabs, or zoom out to see them all side by side.
</p>

<p align="center">
  <a href="https://github.com/SailfishBrowser/iOS/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/SailfishBrowser/iOS/test.yml?branch=main&label=tests&style=flat" alt="Tests"></a>
  <a href="https://github.com/SailfishBrowser/iOS/releases/latest"><img src="https://img.shields.io/github/v/release/SailfishBrowser/iOS?label=release&style=flat" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/SailfishBrowser/iOS?style=flat" alt="License"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/iOS-26%2B-blue?style=flat" alt="iOS 26+"></a>
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/R7BcHnst">TestFlight</a> ·
  <a href="https://sail.fish">Website</a> ·
  <a href="https://sail.fish/guide#iphone">Guide</a> ·
  <a href="https://github.com/SailfishBrowser/iOS/releases">Changelog</a> ·
  <a href="#contributing">Contributing</a>
</p>

## Features

- Swipe along the bottom bar to go from tab to tab, flick the tab stack up for the previous one, and pinch in on a
  page at its smallest zoom to see every tab side by side
- Pinned tabs, private tabs, and tabs that archive themselves after anywhere from 12 hours to 30 days
- Search with Google, DuckDuckGo, Bing, Ecosia, Kagi or Perplexity, with suggestions as you type
- Reader mode, page translation, find on page, page zoom, desktop sites and downloads
- Ads, trackers and cookie banners blocked from the start, each with its own switch, and per-site settings
- Export your open tabs as a list of links and import them again, including the list Arc's Export Open Tabs makes

## Requirements

- An iPhone
- iOS 26 or later

## Download

Sail is in testing on TestFlight: [join the beta](https://testflight.apple.com/join/R7BcHnst) on your iPhone, and TestFlight installs it and keeps it up to
date. Every release and its notes are on [Releases](https://github.com/SailfishBrowser/iOS/releases).

## Building

You need Xcode 26.5 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd iOS
xcodegen generate
open SailBrowser.xcodeproj
```

Run the `SailBrowser` scheme on an iPhone simulator. To run on a device, choose your team under Signing & Capabilities.
To run the tests from the command line, on an iPhone 17 Pro simulator the script creates:

```sh
scripts/test.sh
```

`scripts/build.sh` builds with warnings treated as errors. `scripts/update-blocklists.sh` and
`scripts/update-page-shield.sh` rebuild the content blocking rules in `SailBrowser/Resources` from the filter lists.

## Layout

```
.
├── iOS/
│   ├── project.yml            XcodeGen project (generates SailBrowser.xcodeproj)
│   ├── SailBrowser/           the app, in Swift and SwiftUI
│   │   ├── App/               launch, scenes and app-wide setup
│   │   ├── UI/                screens: browser, tab switcher, search, menu, settings, archive, downloads
│   │   ├── Web/               WebKit tabs, content blocking and the page shield
│   │   ├── Logic/             gestures, layout and archiving rules
│   │   ├── Models/            tabs, history, settings and saved state
│   │   ├── Stores/            browser, history, download and site-settings state
│   │   ├── Persistence/       saving sessions, snapshots and favicons to disk
│   │   ├── Search/            search suggestions
│   │   ├── Haptics/           haptic feedback
│   │   └── Resources/         assets, blocklists, page shield rules, Reader and Translate scripts
│   ├── SailBrowserTests/      tests, in Swift Testing, with saved-state fixtures
│   └── scripts/               build, test, release and blocklist scripts
├── brand/                     logo artwork
└── .github/workflows/         Test and Release workflows
```

## Releases

Releases are built by the [Release workflow](.github/workflows/release.yml), started by hand with a version and
optional notes. It archives the app, signs it through an App Store Connect API key, uploads it to TestFlight, and
publishes release `v<version>` here with the notes and a changelog since the previous release. The build number is
one more than the highest App Store Connect has. iPhone builds install from TestFlight, so a release has no files.

`iOS/scripts/archive.sh` does the same upload from a Mac, with the team and API key in its environment.

## Contributing

Issues and pull requests are welcome. Build the app as in [Building](#building) and run the tests before you open a
pull request; the [Test workflow](.github/workflows/test.yml) runs them on every pull request too.

## License

Sail is licensed under the [Apache License 2.0](LICENSE). It includes third-party software and data under their own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<p align="center">Created by <a href="https://harunkhan.org">Harun</a> and <a href="https://tso.dev">Joseph</a></p>
