# Third-party notices

Sail is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). It includes the software and data below, each
under its own license. The app shows these notices in Settings, under Acknowledgements, from
`iOS/SailBrowser/Resources/PageShield/NOTICE.txt`.

## Filter lists

Sail blocks ads, trackers and cookie banners with rules converted from these lists by
`iOS/scripts/update-blocklists.sh` and `iOS/scripts/update-page-shield.sh`. The converted files are in
`iOS/SailBrowser/Resources/Blocklists` and `iOS/SailBrowser/Resources/PageShield`; `Blocklists/manifest.json` records
the lists and their version.

- EasyList, by the EasyList authors, https://easylist.to. Dual licensed under GNU General Public License v3.0 or
  Creative Commons Attribution-ShareAlike 3.0 (https://easylist.to/pages/licence.html); used under CC BY-SA 3.0,
  https://creativecommons.org/licenses/by-sa/3.0/. Changes: converted to WebKit content rules and per-domain page
  rules.
- EasyPrivacy, by the EasyList authors, https://easylist.to. Licensed as EasyList; used under CC BY-SA 3.0. Changes:
  converted to WebKit content rules and per-domain page rules.
- EasyList Cookie List, by the EasyList authors, https://secure.fanboy.co.nz/fanboy-cookiemonster.txt. Creative
  Commons Attribution 3.0, https://creativecommons.org/licenses/by/3.0/. Changes: converted to WebKit content rules
  and per-domain page rules.
- Fanboy's Annoyance List, by Fanboy and the EasyList authors, https://secure.fanboy.co.nz/fanboy-annoyance.txt.
  Creative Commons Attribution 3.0. Changes: the lines it shares with the EasyList Cookie List are removed, and the
  rest is converted to WebKit content rules and per-domain page rules.

The files derived from EasyList or EasyPrivacy are licensed under CC BY-SA 3.0: `Blocklists/easylist.json`,
`Blocklists/easyprivacy.json`, `Blocklists/tracker-domains.txt`, `PageShield/ads.json` and `PageShield/trackers.json`.
That license covers the rule data only, not the app's code.

The conversion uses AdGuard SafariConverterLib, https://github.com/AdguardTeam/SafariConverterLib, GNU General Public
License v3.0. `update-blocklists.sh` downloads and builds it as a tool; it is not part of the app or this repository.

## Readability

`iOS/SailBrowser/Resources/Reader` contains Readability 0.6.0 by Mozilla, https://github.com/mozilla/readability,
based on Arc90's readability. Copyright (c) 2010 Arc90 Inc. Apache License 2.0 (`Readability-0.6.0-LICENSE.md`
beside it). The test fixtures in `iOS/SailBrowserTests/Fixtures/Reader` include a page from its test suite.
