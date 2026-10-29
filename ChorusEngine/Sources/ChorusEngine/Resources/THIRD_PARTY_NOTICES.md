# Third-party notices

ChorusEngine ships two filter lists, converted into WebKit content rules. Their authors own them and they keep their own licenses, whose full texts are in the `licenses` folder next to this file. The sections below come word for word from the Chorus repository's `THIRD_PARTY_NOTICES.md`.

## Blocklists

Chorus converts two filter lists into WebKit content rules and ships the result as JSON in `Chorus/Resources`. It reads the files as data; nothing is linked into the app. Each JSON file keeps the license of the list it came from.

`vendor/blocklists` holds the exact source text of each list at the version we converted, and `manifest.json` records where each came from, its version, the rule count, and SHA-256 hashes of the input and output. `scripts/convert_blocklist.sh` turns the source text into JSON. The source code is at <https://github.com/nicojan/Chorus>. For the exact lists in a given release, check out that release's tag, such as `v1.5.21`. Every release keeps its tag.

### HaGeZi Light

- Project: [HaGeZi DNS Blocklists](https://github.com/hagezi/dns-blocklists)
- Authors: HaGeZi and contributors
- License: [GPL-3.0](licenses/GPL-3.0.txt)
- Source: `adblock/light.txt`, at the commit named in `vendor/blocklists/manifest.json`
- In the app: `hagezi-light.json`, the ad and tracker blocker

### Fanboy's Annoyance List

- Project: [EasyList](https://easylist.to/)
- Authors: Fanboy and the EasyList authors
- License: [CC BY 3.0](licenses/CC-BY-3.0.txt), as the list's own header states
- Source: `https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt`. That address always serves the newest list, so `vendor/blocklists` keeps the version we converted.
- In the app: `fanboy-annoyance.json`, the optional annoyance blocker

### SafariConverterLib

- Project: [SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib), by AdGuard
- License: GPL-3.0
- Use: build tool only. `convert_blocklist.sh` runs it to make the JSON. Chorus does not link it and does not ship it.
