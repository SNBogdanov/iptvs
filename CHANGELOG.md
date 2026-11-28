# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut by pushing a `vX.Y.Z` tag (see `.github/workflows/release.yml`);
each release's notes also appear on GitHub Releases. New work lands under
`## [Unreleased]` and is moved under a version heading when the tag is cut.

## [Unreleased]

### Added

- **Windows: the auto-switch pace can be changed while watching, from the control bar.** A 500 ms
  press on the bolt opens the pace menu ("Auto-switch every 5 s … 60 s") above the button, with the
  checkmark on the current period; a click still toggles the mode. A held OK on the focused bolt
  opens the same menu on release, and Up/Down in an open pace menu step the value and apply it live
  (`zap:dwell:<seconds>`), so a remote alone can reach the setting. The ladder is still Dart's
  `ChannelDwell`, pushed on `setZapModes`; the chosen pace persists on the channel's own source,
  exactly as before.

### Fixed

- **"Return to release" no longer claims the release is a separate app when it is the same one.**
  The developer-build confirmation said the published APK always installs beside the running app as
  a second `.direct` package. That is true only for a `.dev` build: the `githubDirect` iteration
  build — the one the button exists for — carries the same application id and is replaced in place.
  The dialog now reads the running build's package id and states the outcome it will actually get
  (in place, or beside, or nothing when the id is unknown).

## [1.0.4] - 2026-11-28

### Added

- **The app's preferences are backed up per physical device.** Every `app_*` setting plus the
  profile-picker choice syncs to `device_settings`, keyed by a SHA-256 of Android `ANDROID_ID` / a
  Windows file id, so reinstalling the app and pairing again restores player settings, seek step,
  clock, auto-play, volume, proxy, window placement and the rest. The raw hardware id never leaves
  the device; `cloud_server_*` (the connection itself) and local-profile data are excluded.
- **The cloud schema is versioned, and the app says when it is behind.** `app_schema.version` is
  raised by every migration and read through the public `get_schema_version()` RPC; the app compares
  it with `CloudSchema.currentVersion`, disables features that need a newer server (device settings
  today), and shows the server version/mismatch on the Cloud sync screen. Migrations are applied by
  `db-migrate.yml` with the `SUPABASE_DB_URL` secret — a release tag does not apply them.
- **The cloud server is now a per-device setting.** A build no longer has to be compiled against
  one Supabase project: the Cloud sync screen offers a "Connect a cloud server" form (domain with
  a `.well-known/iptvs-cloud.json` lookup, or URL and publishable key by hand), and the chosen
  server is stored in the OS keychain, so installing the next GitHub release over the app keeps it.
  With no server configured the app starts no Supabase client and creates no anonymous user; a
  build that still carries `SUPABASE_*` defines seeds the keychain with them once. Changing or
  forgetting the server clears only the cloud session and its caches — local sources, favorites and
  watch progress stay. The panel build now also publishes `/.well-known/iptvs-cloud.json` from the
  same values, so entering just the panel's domain discovers the server and its key. Release and CI
  artifacts are built **without** the endpoint or a panel default: a downloaded build shows the
  connect form, the pairing QR is generated only from the server you connected, and the repository
  variables are used only by the panel deploy.
- **A right-to-left swipe on the picture goes back to the previous channel** (Android, live).
  The phone's control row has no previous-channel button — its previous/next pair steps through
  the list, which is a different move — so the gesture every touch screen teaches for "back" now
  returns to the channel that was playing before the current one, the touch equivalent of a
  remote's Last channel key. It fires **on release** and only after 56 dp of travel, so a shaky
  swipe or a short flick changes nothing; a gesture that is clearly vertical still changes the
  volume or brightness instead, and the opposite direction is deliberately left to Android's own
  edge-Back gesture.

### Fixed

- **"Only All categories" no longer appears in the category picker, and the live list no longer
  goes blank.** An empty category id had been saved as "All channels" and then filtered the list
  down to nothing on every launch. An empty id is now read as All when restoring, is never
  remembered as a single category, and is dropped when a selection is applied, so the list starts
  with channels visible again.
- **Holding OK on the auto-switch (bolt) button opens the pace menu from a remote.** The menu was
  touch-only, and on a television a hold just re-fired the button on every key repeat. It now opens
  on the key's **release**, and a selection within 400 ms of opening is ignored, so the release
  that opened the menu cannot also choose a row and close it.
- **A tap outside an open list menu now closes it.** The pace menu (the auto-switch times) and the
  track/speed/aspect menus close when the picture outside the panel is tapped; the pace menu keeps
  the same 400 ms guard, so the hold that opened it cannot immediately dismiss it.
- **The control bar's focus comes back after an in-player panel closes.** Opening and closing the
  quick list could leave the chrome visible with no control focused, sending the next OK to the
  first button; a visible bar with nothing focused now restores play/pause after one frame.
- **MSI upgrades no longer risk deleting the files they just installed.** Each file's component
  GUID is derived from its install path instead of being generated per build: with the old
  "remove the previous product after installing the new one" order, a random GUID let that removal
  delete the new executables — the failure where the Start Menu shortcut survived but
  `C:\Program Files\IPTVS` had no `iptvs.exe`. A build produced before this change should be
  uninstalled rather than upgraded over once.
- **The MSI now creates the Flutter asset directory tree correctly.** The directory emitter sorted
  by depth instead of by path, so a deep directory was nested under whatever directory of the
  previous level came last alphabetically (for example
  `data\flutter_assets\packages\app` landed under `shaders`), and several assets were installed to
  the wrong folders. The tree is now emitted in path order with a parent-aware stack.

### Changed

- **The MSI closes a running player before it replaces the files.** Before copying, the installer
  sends `iptvs.exe` a `WM_CLOSE`, waits three seconds and then terminates what is left — the
  force-kill is what makes it work, because the app defaults to closing into the tray. The wizard's
  "files in use" prompt is gone (it ran before the close action and asked the user to do this by
  hand), and nothing is relaunched afterwards. The in-app updater is unchanged: it exits the app
  itself and launches the new version when it is done.

## [1.0.3] - 2026-11-27

### Fixed

- **A Windows update no longer deletes the shortcuts to recreate them.** The installer now removes
  the previous version *after* installing the new one (`RemoveExistingProducts` scheduled
  `afterInstallExecute`) and the shortcut components carry the permanent GUIDs every earlier release
  already used, so an upgrade overwrites the `.lnk` in place instead of removing it first — desktop
  and Start Menu shortcuts (including pinned or moved ones) no longer blink or lose their place.
- **The player's control bar restores focus when it reappears**, instead of coming back with no
  control highlighted and sending the next OK to the first button: the request used to race the
  fade-in and silently fail.
- **The auto-switch pace menu opens with its current row focused, and hands focus back to the
  zapping button when it closes** (both on choosing a period and on Back).
- **A tap no longer hides the chrome — and with it every open menu — while a panel is up.** The
  pointer-up of the long press that opened the pace menu used to land on the tap layer, which closed
  the menu it had just opened (the list of periods flashed and vanished).
- **The aspect-ratio chip is reachable by the D-pad again.** It was the one chip drawn through a raw
  pointer detector plus a hand-applied `focusable()`, which is not a focus stop the remote can walk
  onto; it now uses `combinedClickable` like every other control.
- `CH+`/`CH−` are also accepted as `MEDIA_NEXT`/`MEDIA_PREVIOUS` (player and channel list), which is
  what some remotes send. Boxes that swallow the channel keys before any app sees them need an
  external key remapper — documented in `docs/tv-navigation.md`.
- **The release pipeline is pinned to Flutter `3.47.5`** instead of `3.44.5`: the older engine
  repainted the UI incompletely on a 32-bit Android TV box (parts of the interface flickering while
  moving with the remote), which the newer engine does not.

### Changed

- **Linux is no longer published.** The fork ships and supports Windows and Android only, so
  `release.yml` builds no AppImage and `update.json` carries no `linux` key; the packaging script
  stays for a local build. Publishing a target nobody tests made every release claim support it did
  not have.
- **Developer builds show "Return to release"** in Help & about (with
  `--dart-define=IPTVS_DEV_BUILD=true`): they are signed with the release key and carry the release
  package id, so the published release installs over them — including at the same version number.
  The release pipeline never sets that define.

## [1.0.2] - 2026-11-27

### Changed

- **The update controls moved from Sources to Help & about.** "Check for updates" and the GitHub
  update track now sit at the top of the Help page — where a user looks to ask "is my app current" —
  instead of being buried under the provider accounts on the Sources screen. The gate is unchanged:
  only GitHub-direct builds show them.
- **A developer build can now return to the published release from inside the app.** Iteration
  builds (`--dart-define=IPTVS_DEV_BUILD=true`) and `.dev` builds show **"Return to release"** on the
  Help page instead of "Check for updates"; the release version is checked against the running build
  **before** anything is downloaded (`release >= current`, so the release cut from the very build
  being tested installs even at the same version), and an older release is refused instead of
  silently downgrading.
- **Settings only offer what the device can do.** The double-tap gesture is hidden on a television
  (remote only) and on desktop (where a double *click* still toggles fullscreen and the setting is
  never read); the volume/brightness swipes stay Android-phone only; and the picture-in-picture
  toggle is gone wherever nothing draws it — Android TV, Linux and iOS — while Windows (mini-player)
  and Android phones keep it.

### Fixed

- **Cloud sync is back in the published builds.** The 1.0.1 artifacts were compiled without the
  Supabase URL and anon key — the release pipeline reads them from repository variables that did not
  exist yet — so cloud profiles, cross-device favourites and watch state fell back to local-only
  without any error. The variables are configured now and every build gets them.

## [1.0.1] - 2026-11-26

### Added

- Player: **random zapping and auto-switch ("zapping") are now buttons** on every overlay — a
  shuffle and a bolt next to the channel-list opener, accent-tinted while on. The shared Flutter
  overlay (Windows SDR, Linux, iOS) used to only report both modes, and the Windows GDI overlay had
  no random mode at all; both read the state back from Dart (`ZapBannerState` / `setZapModes`) and
  send `zap:random` / `zap:auto`, and the GDI pair is also on its keyboard focus ring.
- Cloud: **authorise another device from this one** — a paired phone scans the TV's pairing QR
  (or types its code) and claims it against the same account, without a panel login on the phone.
  New `claim_pairing_as_device` RPC (a paired-device counterpart of `claim_pairing`), the
  `Authorise another device` screen with camera scanning on Android/iOS, and `pairingCodeFromScan`
  (accepts the `?code=` panel link or a bare code). Camera hardware stays optional at install time.
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
- Android player: **volume by a vertical swipe** anywhere on the picture — up is louder, a
  full height is the whole range up to 100 % — with a level panel on the left edge that
  follows the current level. The swipe never mutes (its floor is 1 %): silence is the mute
  button's alone.
- Android player: the **other half of the picture adjusts the brightness** the same way (a
  per-window override, so the rest of the system keeps its own), with Settings → "Volume and
  brightness swipes" choosing which side does what.
- Android player: a swipe now has to be **clearly vertical** (1.5× its horizontal travel) before
  it changes a level — a horizontal swipe with a little vertical wobble no longer raises the
  volume or the brightness, and is left for the system's own gestures.
- Android player: **holding "Go to live"** plays at double speed to catch up with the stream
  (resuming it first if paused); releasing restores normal speed, and a tap still reloads to the
  edge.
- VOD/series: "hide watched" followed by **jump to the first unwatched** no longer draws the focus
  ring on several tiles — a pending jump is the only autofocus candidate, and a card paints its ring
  from its node's current focus instead of the last focus event.
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
- Settings → Proxy: **per-content-kind stream proxying** — the Live / Movies / Series
  switches send the player's own video stream (ExoPlayer, mpv, the shared preview
  engine and the Linux-native process) through the configured proxy, instead of only
  API and artwork traffic. Off by default.

### Changed

- **Windows ships an MSI instead of MSIX.** Built with WiX v4
  (`tool/package_windows_msi.ps1` + `windows/packaging/Product.wxs.in`), it installs per machine
  into `C:\Program Files\IPTVS`, registers in *Apps & features* and upgrades itself through
  `msiexec /i … /qn` — no certificate to trust, no package identity to keep stable. Start Menu
  **and desktop** shortcuts are created; `msiexec /i iptvs-<ver>.msi IPTVS_DESKTOPSHORTCUT=0`
  leaves the desktop one out. The in-app updater downloads the `.msi`, verifies size and SHA-256
  and hands it to an elevated `msiexec` helper that relaunches the installed exe.
- **The Windows data folder left the old owner.** `path_provider` derives
  `%APPDATA%\<company>\<product>` from the executable's VERSIONINFO, so the fork's company rename
  moves it to `%APPDATA%\SNBogdanov\iptvs`; `migrateLegacyWindowsData` copies an existing
  `%APPDATA%\GCHOfficial\iptvs` over once, keeping settings, history and secure-storage entries.
- **Debug builds carry the release signature and the release's `versionCode`.** `buildTypes.debug`
  uses the release signing config when a keystore is configured (falling back to the committed
  debug key only when it is not, so PR CI keeps working), and `versionCode` is now derived from the
  version name (`versionCodeFromName`: `1.0.2` → `1_000_002`) instead of Flutter's `--build-number`.
  One consequence is the point of the change: `flutter build apk --debug --flavor githubDirect`
  installs **over** the release build on a phone — same package, same signer, same code — so only
  one copy of the app exists while iterating. The other is that a release always upgrades every
  earlier install; `--split-per-abi` is never used for anything installed on a device, because its
  ABI offset moves the code.
- **The release pipeline publishes `update.json` and a signed MSIX.** `release.yml` no longer
  builds a Windows zip or an Ed25519-signed manifest: it signs the MSIX with the fork's certificate
  (`WINDOWS_MSIX_PFX_BASE64`/`_PASSWORD` release secrets), exports the matching `.cer`, and writes
  the unsigned `update.json` the client reads (one URL + size + SHA-256 per platform, the Windows
  entry naming the certificate). `--dart-define=UPDATE_MANIFEST_PUBLIC_KEY` is gone from every build,
  and the `package_windows_msix.ps1` verifier now pins this fork's identity instead of upstream's
  Partner Center one (parameters still take a Store account's values).
- **Unmuting with the volume slider no longer disables the volume swipe.** The slider (and the
  swipe itself) set a level through `onSetVolume`, which now also clears `mutedByButton`: raising
  the level is an unmute, and the flag that gates the swipe used to be cleared only by the mute
  button, so a slider unmute left the gesture inert until the player was reopened.
- **Help & about now says this build is a fork** and links both repositories: this fork
  (`github.com/SNBogdanov/iptvs`, where issues belong) and the original upstream project
  (`github.com/GCHOfficial/iptvs`, credited separately). Previously both the source link and the
  issue channel pointed at upstream.
- **Updates are discovered from an `update.json` asset on the latest GitHub release** (the
  `tremotesf` model) instead of a GitHub API call plus an Ed25519-signed manifest: version, and one
  URL + size + SHA-256 per platform (Windows/Android/Linux), read over HTTPS with the same
  host/redirect allowlist. The manifest is not signed — the per-file hash is the check. **Windows
  now installs the signed MSIX** (self-signed, certificate imported into `TrustedPeople` once, then
  `Add-AppxPackage` and a relaunch by package family name) instead of swapping a portable folder.
- **The fork has its own identities.** Android applicationId is now
  `io.github.snbogdanov.iptvs` (flavours `.dev` / `.direct`, `googlePlay` without a suffix) and the
  Windows MSIX identity is `SNBogdanov.IPTVSPlayer` with publisher `CN=SNBogdanov`. Both are
  *different apps* from upstream's: installs do not update across the two, so state comes back
  through cloud pairing. The `parallel` flavour (a side-by-side local release) is removed — the
  uploader no longer needs a third local identity.
- **Android TV / phones: Back now exits in two presses.** Back on the channel list is "leave":
  one press shows "Press Back again to exit", the next exits. It no longer peels the list to its
  first row, hops into the search box or climbs the tabs, so leaving the app from the player takes
  hide-panel → close-player → confirm instead of four or five presses; arrows still move between
  the sidebar, search and tabs, and a text field still owns Back while it is being edited.
- **Android TV: the aspect-ratio chip is back in the cursor path.** A chip with a hold action used a
  raw pointer detector instead of `clickable`, and a pointer detector does not make a node
  focusable — so the remote skipped the aspect button (and "Go to live"). It is focusable again,
  with Enter/Center mapped to its tap.
- **Android TV: Left/Right on the progress bar scrubs instead of jumping to the next button.** The
  slider no longer needs an "OK to edit" mode before the arrows change the value — while it holds
  focus they are the seek step (and the volume step on the volume slider), and Up/Down leaves the
  row. Matches the Windows GDI overlay's scrubber row.
- **Android TV: bringing the control bar back returns focus to the button it was hidden on**,
  instead of always landing on play/pause; controls that are no longer offered fall back to it.
- **Live channel rows are sized per row**, not per list: a channel with a programme takes the
  tall row (now/next/progress), one without it the compact row — a portal whose guide covers a
  handful of channels no longer draws every other card with an empty EPG band. While the guide is
  still downloading a row stays tall only if it can still be matched (it carries an epg id, or the
  guide matches by name), so a catalog without epg ids opens compact immediately. The selection
  model now scrolls by the same per-row geometry it renders (`LiveRowLayout`), keeping the D-pad
  reveal exact.
- **Live TV: the category filter can select several categories at once** (union), with checkbox
  semantics in the wide sidebar and in the phone sheet; a long press (or the sheet's
  `Only <previous>`) returns to a single category in one gesture.
- **The in-player quick list shows the current union as its own category row** (titled like the
  zap banner, e.g. `Sports + News`) instead of opening on "All channels" with no row for the
  several categories the session is walking; picking it re-ranges to exactly those categories, and
  Back restores the union on the tab.
- **Random zapping now walks the whole range without repeats**: it draws from a shuffle bag, so a
  cycle shows every channel of the current range once before anything repeats, refilling when
  exhausted; turning random off or leaving the player starts a fresh cycle.
- **A VOD tab refreshes itself when its cached catalogue is older than the source's refresh
  interval** (startup / 6 / 12 / 24 / 48 h), silently in the background; previously Movies/Series
  kept the first-visit catalogue until Reload, because the scheduled refresh only covered tabs that
  were already open when it ran.
- **Xtream's Username field is no longer masked after switching the source type**: the field's mask
  now follows the field rather than the cell's position in the form (it used to inherit the MAC
  field's mask, showing dots with no reveal toggle).
- **A mute or level chosen in the Android player no longer falls off after an engine rebuild or the
  ExoPlayer→mpv fallback** (a cross-source zap, a buffer-preset change, a stream that needs mpv —
  the case that read as "mute falls off when I switch source"), and unmuting after such a rebuild
  restores the audible level rather than 10 %: every engine is seeded from the live state (mpv's own
  mute flag included), the mute button sets an explicit level, and the mute is reported to the
  session immediately instead of only on close.
- **A downward pull from the top edge no longer changes the brightness** while opening the
  notification shade; that strip belongs to the system.
- **The aspect mode is device-wide** instead of per source; **holding the aspect button** opens a
  menu that pins a different mode to the current channel (or "Use global" to drop the pin), and a
  pinned channel draws the aspect chip in the accent colour with a border. The old per-source value
  is read only as a fallback, and a pin is stored with the source's settings so it follows the
  profile.
- **The guide cache is bounded.** Programmes more than 36 hours back or a week ahead are
  pruned, deleting a source now also deletes its cached channels/guide/catalogue (it used
  to leave them unreachable in the file forever), and the write-ahead log is capped at
  64 MiB and checkpointed on pause and after a guide write. A phone database that had
  grown to 792 MiB (69% of it a duplicated, 15-day guide) settled at 188 MiB.
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

### Removed

- **Store publishing.** The Microsoft Store and Google Play pipelines (`microsoft-store.yml`,
  `google-play.yml`), the `googlePlay` Gradle flavour, the store listing assets
  (`assets/store/`), the Play upload-key helper and the Play AAB verifier, and
  `docs/store-publishing.md` / `docs/google-play-submission.md` are gone. So are the
  `googlePlay` and `microsoftStore` distribution channels and `isStoreManaged`; an unknown channel
  still parses as `development`, which means "no self-update" — exactly what those builds did.
  This fork ships from GitHub Releases only: APK (`githubDirect`), signed MSIX, AppImage, and the
  README, KB install guide and landing page point there instead of at store listings.

### Fixed

- **Previews are silent, on every platform.** Android's deliberate preview used to start at the
  session volume, and the shared engine kept fullscreen's level on the way back, so a preview — or a
  preview *returned to* from fullscreen — was audible. It now starts muted and re-applies its own
  mute on resume; the preview panel's mute button is the only way up.
- **`CH+`/`CH−` on a TV remote now change the channel from the channel list too**, not only inside
  the player: the key walks the list (next channel down, wrapping), starts the silent preview on a
  TV and opens the player on a phone, exactly as OK on that row would.
- **A channel change no longer shows the previous channel for a second.** The Android player covers
  the video surface with black while the new stream loads and lifts it on that stream's first
  rendered frame.
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
- VOD/series: the catalogue is read **lazily**, a window at a time, with the grid's
  order applied in SQL (`media_items.sort_date`); a 29k-item catalogue used to be
  read in one query whose 162 MB platform-channel message killed the app on Android
  when a tab opened on "All categories".
- Android: Page Up/Down page the open quick list by a windowful again instead of
  stepping one row.
- VOD/series: a full catalogue refresh now also drops the per-category page caches,
  so a category shows the titles the refresh brought without its own manual refresh.
- Android: a player opened with a **saved mute** keeps the volume swipe inert — the
  restore counts as the mute button's, so the gesture cannot unmute it.
- Live TV: the remembered category is no longer abandoned seconds after launch — the
  last-channel resume applies only **inside** that category, instead of re-ranging the
  whole tab to "All channels" to reach a channel the category does not list.
- Live TV: Back from a session whose in-player channel list switched groups now returns to
  **that** group with the watched channel selected, instead of the group the tab had before
  the player opened.
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

[Unreleased]: https://github.com/SNBogdanov/iptvs/compare/v1.0.4...main
[1.0.4]: https://github.com/SNBogdanov/iptvs/releases/tag/v1.0.4
[1.0.3]: https://github.com/SNBogdanov/iptvs/releases/tag/v1.0.3
[1.0.2]: https://github.com/SNBogdanov/iptvs/releases/tag/v1.0.2
[1.0.1]: https://github.com/SNBogdanov/iptvs/releases/tag/v1.0.1
