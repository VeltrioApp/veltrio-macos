# Veltrio for macOS

Every source, one native player. Films, series and live TV from
Stremio-compatible addons, your own media server and your IPTV provider.
SwiftUI app on top of [veltrio-core](https://github.com/VeltrioApp/veltrio-core).

## Status

- [x] Rust core (`core/veltrio-core`) with the Stremio addon protocol
      (manifest / catalog / meta / stream)
- [x] UniFFI Swift bindings — `StremioClient` exposed natively to Swift
- [x] macOS SwiftUI app: editorial top nav, addon install, home with a
      full-bleed hero + numbered catalog rows, detail view with meta +
      fan-out stream fetch across all installed addons, watch progress
- [x] Search: IMDB titles only, Movies and Series rows, results stream in
      as each addon answers
- [x] Detail page: one stream list per title across addons, Jellyfin /
      Emby / Plex (matched by IMDB id) and IPTV (matched by title + year,
      language read from the provider's category), filterable by source
- [x] libmpv player (MPVKit): HDR detection + tone mapping, DTS/AC3 passthrough,
      audio/subtitle track selection, external subtitles from addons,
      chapters with skip-intro, playback profiles, media-info panel
- [x] IPTV: M3U parser (tolerant), live playlist loader, channel browser
      with groups + search. Tested against iptv-org (11k+ channels).
- [x] IPTV: Xtream Codes API — live / VOD / series, catchup EPG,
      short EPG (now/next) and timeshift URL construction
- [x] Torrent engine: librqbit embedded, local HTTP server with Range
      support, magnet synthesis with fallback trackers, Swift wiring.
      `infoHash` streams are playable end-to-end.
- [x] AllDebrid: PIN auth (no API-key paste), Keychain-stored credentials,
      batched availability prefetch with cache badges on streams, episode-aware
      file selection, auto-cleanup of probe magnets. Torrent streams are
      routed through AD → direct HTTPS when cached, fall back to the local
      engine otherwise.
- [x] Real-Debrid: device-code auth, availability prefetch, cache badges
- [x] Trakt: device-code auth + playback scrobbling
- [x] Jellyfin / Emby / Plex: connect, and their copies of a title play
      from its detail page with resume and watched state
- [x] AirPlay casting, Picture-in-Picture, offline downloads
- [ ] TorBox / Premiumize (same shape as AllDebrid and Real-Debrid)
- [x] Distribution: universal (Apple silicon + Intel) self-contained app,
      Developer ID signing + notarization script, Sparkle updates, MetricKit
      crash reports, English + French UI
- [ ] Jellyfin / Emby / Plex: browse a library in the Collection tab
- [ ] IPTV: XMLTV EPG parser and a now/next overlay over playback
- [ ] Stremio account sync (watchlist / collection / history)
- [ ] SIMKL sync
- [ ] Skip intro: crowdsourced markers and chromaprint matching
      (chapter-based detection works today)
- [ ] Transcoding
- [ ] iOS / tvOS / Android (phone + TV) / Windows / Linux

## Build & run

Prerequisites: Xcode 16+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and [`gh`](https://cli.github.com) signed in. libmpv comes from
[MPVKit](https://github.com/mpvkit/MPVKit) through Swift Package Manager.

```bash
./scripts/fetch-core.sh      # core release pinned in core.version → Generated/
xcodegen generate
open Veltrio.xcodeproj       # or xcodebuild -scheme Veltrio build
```

Working on the core at the same time? Clone it next to this repository
and build from it instead of the release:

```bash
VELTRIO_CORE_DIR=../veltrio-core VELTRIO_ARCHS=arm64 ./scripts/fetch-core.sh
```

To move to a new core release, change `core.version` and re-run
`fetch-core.sh`.

### Checks

`scripts/check.sh` runs the Swift unit tests (fetching the core first if
needed).

### Translations

English and French. Strings live in `Veltrio/Localizable.xcstrings`,
generated from `scripts/localizations.py` — edit the tables there and
re-run it. Text a component receives as a `String` is looked up with
`.localized`; text built with values goes through `String(localized:)`.

## CI/CD

| Workflow | Runs on | Does |
| --- | --- | --- |
| `ci.yml` | pushes to main, pull requests, manual | fetch core, build, unit tests |
| `release.yml` | tag `vX.Y.Z`, manual | universal build, signing, notarization, DMG (+ appcast) on the release |

The repositories are public: Actions minutes (macOS included) are free,
and organisation secrets reach every repository.

Secrets and variables are set once on the **VeltrioApp organisation**:

| Name | Kind | What |
| --- | --- | --- |
| `CORE_RELEASES_TOKEN` | secret | optional — the workflow token can read the public core releases |
| `MACOS_CERTIFICATE_P12` | secret | Developer ID Application certificate + key, `.p12`, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | secret | its password |
| `MACOS_SIGN_IDENTITY` | variable | `Developer ID Application: Name (TEAMID)` |
| `APPLE_TEAM_ID` | variable | team id |
| `NOTARY_KEY_P8` | secret | App Store Connect API key `.p8`, base64 |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | variables | that key's ids |
| `SPARKLE_PRIVATE_KEY` | secret | `generate_keys -x` export |
| `SPARKLE_PUBLIC_KEY`, `APPCAST_URL` | variables | update feed key and URL |

Without the Apple secrets a release run still produces an ad-hoc signed
DMG. Releases are public, so they can host the DMG and the Sparkle feed:
set `APPCAST_URL` to
`https://github.com/VeltrioApp/veltrio-macos/releases/latest/download/appcast.xml`.

Locally, `scripts/release-macos.sh` does the same with the variables
documented at its top.

## Licensing

MPVKit's LGPL build is statically linked. The LGPL requires that people
who receive the app can relink it against a modified libmpv/FFmpeg; this
repository being public, with build instructions, provides that.
