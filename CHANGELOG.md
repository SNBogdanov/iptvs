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
- HTTP proxy support (Settings → Proxy): **System** (the Android Wi-Fi proxy with its
  bypass list, the Windows Internet-options proxy, or the `https_proxy` family),
  **Custom** (host and port), or **Off**. LAN addresses — dotless names, `.local`,
  `localhost` and the private ranges — always go direct, so a provider panel on the
  local network keeps working while only internet traffic uses the proxy.
- Poster artwork **and XMLTV guides** are fetched **direct first and through the proxy only if that
  fails**, with a short connect timeout and a per-host memory shared between the two, so a LAN image
  or guide server is never sent to the proxy and a blocked CDN still loads. Provider API traffic keeps
  following the proxy setting outright.
- Settings → **Player controls**: ten optional buttons — previous/next, ±seek, mute,
  the volume bar, channel list, favorite, subtitles, aspect, picture-in-picture and
  stream info — each can be hidden; play/pause always stays.
- **Double tap on the picture** (touch): the left half goes back/previous, the right
  half forward/next. The action is a setting — Previous/Next (default) or Seek by the
  configured VOD step; live channels always step, because they cannot be seeked.
- Android: a player **orientation button** — follow the device, or pin landscape with the
  sensor deciding which side is up, so the picture and text stay upright when the phone is
  turned over. Hidden on devices without an accelerometer (TVs). The choice is remembered
  across launches and applies only while a player is on screen.
- Live TV: the last browsed **category is remembered per source**, and a service that renamed
  or dropped it falls back to "All channels" instead of opening on an empty list. The
  last-channel resume now runs **after** that restore, and switching category keeps the
  selected channel when the new view lists it too.
- Android player: a tap **outside** the channel list closes it, a **long press** on the
  channel-list button opens the list on its categories (current one selected), and a long
  press on the zapping button opens the **auto-switch pace** menu with the current value
  checked — the chosen pace is stored per source.
- Windows: the picture-in-picture window's restore button shows where it returns to
  (fullscreen or a normal window), with the same icon pair the full bar uses.
- Cloud sync: VOD/series **watch progress and watched marks** now follow the paired
  profile. Progress is sent per title on a 30-second ticket (moved one second later for
  each further update while playback continues) and flushed when the player closes,
  steps to a sibling, finishes a title, or the app is backgrounded; a pull applies the
  other devices' state, and the upgrade queues the existing local history so it cannot
  be erased by the first sync. Each row carries the title, year and artwork (poster +
  backdrop) the device knows, so the panel's new **History** tab shows a real list with
  landscape (16:9) thumbnails — Continue watching with a progress bar, then Watched —
  without needing the (unsynchronised) catalogue.
- Settings → **Ask for a profile at startup**: off boots straight into the last used
  profile (a profile with a PIN still asks for it); on shows the picker whenever there
  is a real choice. Replaces the cycle row that lived at the top of the Sources screen.

### Changed

- Player chrome: the clock, VOD time readout and channel name are device-wide
  preferences; the name persists as a top-left HUD pill while the controls are hidden.
- Playback volume and mute are a device-wide session, preserved across every player
  surface and reconnect.
- Dates throughout the app follow the OS's short-date format.
- **Portrait player chrome fills two rows instead of three** where it can: mute rides
  the transport row, and the volume slider shares a wrapping row with the contextual
  buttons. Hiding the slider no longer leaves mute alone on a strip of its own.
- The ±seek buttons and the seek double tap use the same **VOD seek step**, instead of
  a hard-coded ten seconds.
- The VOD card-shape preference also applies to the list thumbnail a phone shows
  instead of the poster grid, in width only (its height sets the paging row count).
- The media status line only prints `pages N/M` where pages are actually paged; a
  touch surface infinite-scrolls, so the readout is omitted there.
- On a phone the EPG/sort action sits beside the category picker on the same row
  instead of alone on its own.
- The in-player channel list scrolls through the whole range on touch (a 40-row
  window used to stop at its edge) and gained a close button.
- Player chrome: picture-in-picture draws Material's `picture_in_picture_alt` instead of
  a "PiP" text chip (Android, the shared overlay and the drawn Windows GDI button), and
  Android's live overflow menu became two toggle buttons — **Shuffle** for random zapping
  and a **bolt** for auto-switch — tinted with the accent while on. The channel-list
  opener keeps its list glyph on every surface.
- The player keeps a clock, a VOD position readout and the channel/title name in the corners
  while the chrome is hidden, on Android as well as in the shared overlay — each gated by its own
  Settings preference (the Android name pill and top-bar title follow "Channel name in the player").

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
- VOD/series: with the Continue watching rail on screen, the first **Next page**
  control no longer lands a row below the fold - page one (and only page one) is
  measured against the space the rail leaves above the grid.
- Android: a touch layout no longer shortens page one by the rail (that window fits
  the viewport on a phone, which left nothing to scroll and made the catalogue
  unreachable); when a window is shorter than the viewport the next one is now
  revealed from the window report, not only from a scroll event.
- Android: Page Up/Down page the open quick list by a windowful again instead of
  stepping one row.
- Windows: a failed VOD open now shows a native "Playback error" panel with Retry
  (and OK/Enter/Space) instead of a black screen — the Flutter error overlay was
  behind the native video surface.
- Android: the live player no longer mixes modes — a VOD session's title, synopsis and
  scrubber could be repainted over a live channel when the previous overlay's state
  outlived its route.
- Android: a channel change used to reset the aspect ratio the viewer had just picked;
  the player's own choice now outranks the launch value carried by a zap.
- Android: the auto-switch countdown no longer reopened the channel banner every
  second (the name blinked), and the Random zapping checkmark is correct at launch.
- Android: a double tap on live did nothing when "Seek" was selected; live always
  steps a channel now.
- Android: stepping to the next film or episode saves the outgoing title's position,
  so "Continue watching" resumes the one that was left behind.
- Android: a provider panel on the local network was unreachable whenever a proxy was
  configured (the proxy closed the LAN request); local addresses bypass it now.
- Windows: returning from the picture-in-picture window could restore a PiP-sized
  window, and the fullscreen button could show the wrong state after a PiP or VOD
  session — the window's real style is read at paint time now.
- Windows: the fullscreen and PiP buttons no longer take their glyph from Segoe MDL2,
  where `E740` is a single two-headed arrow and `E73F` is two arrows pointing at each
  other — both states are drawn as the same four corner brackets the Flutter overlay
  uses (outward to enter, inward to leave), in the full bar and the PiP mini bar.
- Windows: saved window placement restores the window to its monitor, including a
  maximized window and a window hidden to the tray across a display sleep/wake.
- Windows: Back/Escape can close playback while "Reconnecting..." is shown.

[Unreleased]: https://github.com/SNBogdanov/iptvs/commits/main
