# Changelog

All notable changes to Veltrio for macOS. Versions follow
`MARKETING_VERSION` in `project.yml`; the core release each version is
built against is in `core.version`.

## 0.2.0

### New
- **Collection**: browse your Jellyfin, Emby and Plex libraries. Titles the
  server identified open on their IMDB page; others play directly, and
  series without an IMDB id list their episodes.
- **Live TV, TV-app layout**: numbered channel list with logos, what's on
  and its progress; the selected channel large with its programme, time
  left, description and what's next. Arrow keys and Return to zap.
- **TV guide (XMLTV)** from the Xtream provider or the M3U header: what's
  on in every channel tile, a three-hour guide grid, and now/next in the
  player for M3U channels.
- **Search** adds a row of the IPTV provider's own films and series,
  with their language, after the IMDB results.
- **TorBox and Premiumize** debrid, with API keys.
- **Accounts**: import your Stremio library and install its addons;
  import Trakt watchlist and history; SIMKL sign-in, scrobbling and list
  import (needs a SIMKL client id at build time).
- **Chromecast**: cast from the player to any Chromecast on the network.
  Streams played from this Mac's torrent engine can't be cast.

### Changed
- Live TV loads at launch and remembers the last playlist.
- Buttons react to clicks anywhere in their frame, not only on their text.
- Version 0.2.0 shown in Settings → About.

### Removed
- Unused media-server search paths and Plex's broken item stream URL.

## 0.1.0

First version in its own repository (split from the monorepo).
- Universal app (Apple silicon + Intel) with libmpv from MPVKit; Rust core
  as an embedded dylib, fetched from veltrio-core releases.
- IMDB-only search with Movies and Series rows; detail page streams from
  addons, Jellyfin, Emby, Plex and IPTV (with language), filterable by
  source, in a list that scrolls on its own.
- Xtream series pages; films and episodes play with a timeline and resume.
- Settings restyled; English and French UI.
- Sparkle updates, MetricKit crash reports, credentials masked in logs.
