# Third-party notices

Chorus is MIT-licensed (see [LICENSE](LICENSE)), but it ships some work by other people under their own licenses. The MIT license does not cover that work. This file lists each part, its license, and where its source lives. The app carries a copy of this file, `LICENSE`, and the `licenses` folder in `Contents/Resources`.

## Blocklists

Chorus converts two filter lists into WebKit content rules and ships the result as JSON in `ChorusEngine/Sources/ChorusEngine/Resources`, the resources of the ChorusEngine package the app is built on. It reads the files as data; nothing is linked into the app. Each JSON file keeps the license of the list it came from.

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

## Dark Reader

- Project: [Dark Reader](https://github.com/darkreader/darkreader)
- License: [MIT](licenses/DarkReader-MIT.txt)
- In the app: `darkreader.js`, which gives a service a dark theme when you turn that on for it

## Sparkle

- Project: [Sparkle](https://github.com/sparkle-project/Sparkle)
- License: [MIT, with the notices for the parts it includes](licenses/Sparkle.txt)
- Use: checks for and installs signed updates

## Service icons

The icons in the rail come from [The SVG](https://github.com/GLINCKER/thesvg), whose tools are MIT-licensed. The logos and names belong to their owners, who keep their trademark rights. Chorus shows them only to tell you which service is which. It is not endorsed by or affiliated with any of these companies.

## Paguro

[Paguro](https://github.com/anguria-studio/Paguro), a fork of Chorus, found several of the bugs Chorus has since fixed. Chorus wrote most of those fixes its own way. Two small helpers in `WebViewCoordinator.swift`, `keepsCurrentPage(afterProvisionalFailure:)` and `reload(_:fallbackURL:)`, follow Paguro's code closely, and Chorus uses them under Paguro's MIT license:

> Copyright (c) 2026 Nico Jan  
> Copyright (c) 2026 Tommaso Laterza
