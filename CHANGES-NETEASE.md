# CHANGES-NETEASE — files touched for NetEase / System Now Playing

Upstream base: RidhaAF/lirik `main` @ `1d46abe` (v1.3.1).

## Design

- **Primary runtime:** Homebrew [`media-control`](https://github.com/ungive/media-control) (`stream` / `get`).
- **Optional bundle:** `mediaremote-adapter.pl` + locally built arm64 `MediaRemoteAdapter.framework` (TouchBarLyrics-style `/usr/bin/perl` launch).
- **Not used:** NetEase AppleScript (none usable).
- Lyrics path unchanged: LRCLIB + existing `LRCSyncEngine`.

## New files

| Path | Purpose |
|------|---------|
| `lirik/Sources/NowPlaying/MediaControlBackend.swift` | Stream/parse system Now Playing JSON → `NowPlayingTrack` |
| `lirik/Resources/mediaremote-adapter.pl` | Vendored adapter CLI script |
| `lirik/Resources/README-ADAPTER.txt` | Where to place built framework |
| `vendor/mediaremote-adapter/bin/mediaremote-adapter.pl` | Same script (vendor copy) |
| `vendor/mediaremote-adapter/LICENSE` | BSD 3-Clause |
| `scripts/build-mediaremote-adapter.sh` | macOS-only framework build helper |
| `BUILD-NETEASE.md` | EN/中文 build & test guide |
| `CHANGES-NETEASE.md` | This file |
| `NOTICE-NETEASE.md` | Third-party notices |

## Modified files

| Path | Change |
|------|--------|
| `lirik/Sources/NowPlaying/NowPlayingTrack.swift` | Sources: `netease`, `system` |
| `lirik/Sources/NowPlaying/NowPlayingWatcher.swift` | Prefer MediaControl; honor player preference; restart on pref change |
| `lirik/Sources/NowPlaying/AppleScriptBackend.swift` | Honor spotify/music preference when polling |
| `lirik/Sources/NowPlaying/MediaRemoteBackend.swift` | Comment pointing to MediaControl on 15.4+ |
| `lirik/Sources/Widget/LirikPreferenceViewController.swift` | Add **System Now Playing** option + notification |
| `lirik/Info.plist` | Automation usage string clarifies System path |
| `lirik.xcodeproj/project.pbxproj` | Copy-framework script phase |
| `README.md` | NetEase / System Now Playing section |

## Unchanged (intentionally)

- `LRCParser`, `LRCLIBClient`, `LyricsCache`, `LRCSyncEngine`, widget rendering — once metadata exists, sync works as before.
- No invented NetEase AppleScript.

## Remaining risks

1. Full **Xcode** (not only CLT) needed for PockKit / `.pock` build.  
2. NetEase must publish Now Playing to macOS; otherwise no detection.  
3. Prebuilt frameworks that are **x86_64-only** will not load under arm64 `/usr/bin/perl`.  
4. Pock may not inherit interactive shell `PATH`; code checks `/opt/homebrew/bin` and `/usr/local/bin` explicitly.  
5. No `.pock` binary was produced on the Linux workspace.

