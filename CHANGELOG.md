# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut by pushing a `vX.Y.Z` tag (see `.github/workflows/release.yml`);
each release's notes also appear on GitHub Releases. New work lands under
`## [Unreleased]` and is moved under a version heading when the tag is cut.

## [Unreleased]

### Added

- Live TV: in-player channel zapping — Page Up/Down for the next/previous channel,
  a previous-channel key, and typed channel numbers — on every player surface.
- Live TV: a quick list (`GUIDE`, `G`, or Left with the controls hidden) to browse
  categories, channels and today's schedule, operable by remote, mouse wheel and click.
- Live TV: resume on the last watched channel at launch, with its preview.
- Live TV: an auto-switch countdown and random zapping, with a per-source dwell time.
- Windows: a system tray icon with hide-to-tray, a boss key (F12), and global playback
  settings (close-to-tray, always-on-top in fullscreen, random zapping).
- VOD/series: Windows playback of movies, catch-up and preview-less live on the native
  player surface.
- VOD/series: a "Continue watching" rail, saved resume positions, and watched-progress
  indicators on cards.
- VOD/series: release-date grid ordering (newest first by default, with name and
  provider-order alternatives).
- VOD/series: a configurable "VOD seek step" (5/10/15/30/60 s) with a selectable
  scrubber on the Windows player.
- VOD/series: a synopsis in the player chrome, falling back to the provider's own
  details when metadata is missing.
- VOD/series: hide watched movies and jump to the first unwatched one from the
  toolbar; the toolbar also fits narrow windows without overflowing.
- Auto-play the next film or episode, with a resume/skip/start-over policy.
- Sources: several XMLTV guides per source (merged per channel), an optional Xtream
  direct live URL, and automatic M3U→Xtream upgrade.
- Sources: a per-source catalogue refresh interval (startup / 6 / 12 / 24 / 48 h).
- Zapping modes skip a dead channel automatically when its HLS manifest carries
  `serve_not_available`, instead of retrying it forever.
- Windows: a centred "Loading…" indicator while a stream is opening or buffering
  (the native video surface previously showed a plain black screen with no progress).

### Changed

- Player chrome: the clock, VOD time readout and channel name are device-wide
  preferences; the name persists as a top-left HUD pill while the controls are hidden.
- Playback volume and mute are a device-wide session, preserved across every player
  surface and reconnect.
- Dates throughout the app follow the OS's short-date format.

### Fixed

- Leaving the sources screen no longer re-ingests the whole catalogue.
- A source-identity collision can no longer stop the app from starting.
- One XMLTV guide entry now covers every channel sharing its id or normalised name.
- Channel/category logos are letterboxed instead of cropped.
- Windows: fixed the green bottom band and a renderer crash on resize/teardown.
- FFmpeg's own diagnostics are filtered out of mpv's log.
- Preview playback keeps running and starts promptly on Windows, restarts correctly
  after a quick-list zap, and recovers from a frozen return.
- Windows: the first live preview or channel open now renders video immediately;
  previously it stayed blank until another channel was selected.
- Live: a clean EOF on a non-HLS stream is absorbed by ffmpeg instead of forcing
  a full reopen; HLS keeps the existing reconnect path.
- Opening a VOD card no longer re-sorts it out from under the cursor; the HUD name
  pill leads with the channel number.
- Hiding the window to the tray now stops a live stream and reopens it at the live
  edge on restore (instead of pausing it) — no background retries against a dead
  channel, and no stale-buffer glitch when the picture comes back.
- Switching a live channel no longer flashes the previous channel's picture after
  the black screen: the embedded texture's stale frame is masked until the new
  stream's first frames arrive.
- Watched-progress bars no longer vanish when the last in-progress title finishes
  (e.g. an auto-advance whose next-title fetch fails): the empty Continue-watching
  read cleared the `watched_media` bars until another title was played.
- Windows: a failed VOD open now shows a native "Playback error" panel with Retry
  (and OK/Enter/Space) instead of a black screen — the Flutter error overlay was
  behind the native video surface.
- Windows: saved window placement restores the window to its monitor, including a
  maximized window and a window hidden to the tray across a display sleep/wake.
- Windows: Back/Escape can close playback while "Reconnecting..." is shown.

[Unreleased]: https://github.com/SNBogdanov/iptvs/commits/local
