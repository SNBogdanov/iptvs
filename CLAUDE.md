# CLAUDE.md

Guidance for working in this repository. Keep it accurate — update it when the architecture
changes. This file is the compact, always-loaded layer: the map, the invariants, the rules.
Deep detail (mechanisms, rationale, failure history) lives in `docs/*.md` — **read the relevant
doc before working in its area**, and update doc + this file together when behavior changes:

- [docs/implementation-plan.md](docs/implementation-plan.md) — temporary audit-remediation ledger; update its checklist, evidence, decisions, and progress entry in every related PR.
- [docs/validation-baseline.md](docs/validation-baseline.md) — reproducible large-ingestion workloads, public schema history, performance evidence, and native-device validation matrix.
- [docs/android-signing.md](docs/android-signing.md) — signing-compromise evidence, package-identity recovery decision, protected release-key setup, and APK certificate gates.
- [docs/store-publishing.md](docs/store-publishing.md) — Android/Play and Windows/Microsoft Store identities, signing roles, packaging, channel-specific updater ownership, and the per-release submission procedure. Scoped to what a *future* release needs; the completed one-time launch checklists and certification evidence were moved to a gitignored `docs/private/` record.
- [docs/ios.md](docs/ios.md) — **player implemented, nothing shipped to users yet.** The iOS scope: why the App Store is deliberately skipped, AltStore Classic sideloading (worldwide, $0, 7-day expiry) and its source manifest, and the player — a **single full-hybrid release** (no staged mpv-only tier): a presented `IptvsPlayerViewController` owning an `AVPlayerLayer` (default engine, real HDR/PiP/AirPlay) with libmpv via `media_kit` as the fallback for containers AVFoundation refuses (always SDR on iOS). Compiles, `swift test`, and simulator builds are green; on-device validation (real HDR, real provider headers) is still outstanding. The audio-session blocker is resolved via a git-pin to media_kit's unreleased `iosManageAudioSession` (upstream cadence has stalled — assume a git-pin, not a release, is the long-term posture). AltStore PAL and tvOS are out of scope, with the PAL rejection recorded as a revisitable decision.
- [docs/sources.md](docs/sources.md) — the provider layer's intricate corners: Stalker adult ("censored") genres that `get_all_channels` omits, multiple EPG guides per source (the claim rules that decide which guide serves a channel, and why a row union would be wrong), how each provider obtains a subscription expiry (Stalker's authorize-before-asking ordering, field/format coverage, the far-future sentinel and its phone-number trap, the shape-only diagnostics), the device-local expiry cache and its staleness rules, and the M3U→Xtream upgrade — where it runs, why cloud-managed sources are skipped, and why the web panel suggests while only the app can prove — plus the stable-identity namespace migration: why the destination may already be populated, why the **stable** namespace wins a collision, and why it can never block the first frame.
- [docs/tv-navigation.md](docs/tv-navigation.md) — the D-pad/focus system: selection models, the Back ladder, `TvTextField`/`FocusableCard` internals, the EPG grid cursor.
- [docs/player.md](docs/player.md) — the playback stack: Android dual-engine + HDR, Windows native surface, iOS native surface (implemented, on-device validation pending), the shared-engine preview handoff, auto-reconnect, PiP.
- [docs/cloud-sync.md](docs/cloud-sync.md) — the Supabase panel, pairing, the RLS security model, cloud + device-side profiles.
- [docs/updates.md](docs/updates.md) — the self-update pipeline: release changelog, per-platform install, update-dialog focus behavior.

**Upkeep rule:** documentation updates land **in the same commit/PR** as the change that
invalidates them. If a change alters behavior described in a detail doc, update that doc; if it
alters a rule or invariant summarized here, update this file too. Subagents are instructed to
flag doc impact in their reports — the orchestrator owns making the updates happen before the
work is considered done.

## What this is

`iptvs` is a cross-platform Flutter IPTV player (Windows, Linux AppImage, Android incl. Android TV, plus the
usual Flutter targets). It connects to user-configured IPTV providers, caches their
channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and plays streams
with libmpv (via `media_kit`) so it handles HEVC / AC-3 / MPEG-TS that an HTML video element
can't. There is no backend for playback — the app talks directly to user-supplied provider panels
and public metadata APIs. The one *optional* backend is a Supabase-backed cloud source panel
(docs/cloud-sync.md); it's off unless built with Supabase config and never touches playback.

## Commands

```bash
flutter analyze        # must be clean before committing
flutter test           # unit tests live under test/
flutter run -d windows
flutter run -d android --flavor development --dart-define=DISTRIBUTION_CHANNEL=development
```

**On Windows, a fix is not finished until `build\windows\x64\runner\Release\data\app.so` has been
rebuilt — see "Verification gate" below. `flutter test` proves the logic, not the artifact the
user actually runs.**

Lints: `package:flutter_lints`. CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)):
analyze + test + the Lua OSD gate (`luac5.1 -p` and `linux/mpv/overlay_layout_test.lua` — the only
thing that executes the Linux native overlay outside a Wayland+HDR session) + the panel's
`npm test` (`pages.yml` is deploy-only and post-merge, so this job is the panel suite's only
pull-request gate), then Windows and a universal Android APK. The Windows libmpv DLL is fetched at
configure time by `windows/CMakeLists.txt`; the Android libdovi AAR comes from **Git LFS**
(`android/app/libs/libmpv-dovi.aar`), so a clone needs LFS to build Android. The Windows runner
compiles `/utf-8` (non-ASCII literals trip C4066 under `/WX`). A fixed public debug keystore is
committed for non-distributable debug builds. Release builds fail closed unless protected signing
environment variables are present, and the release workflow verifies the resulting certificate.
PR CI also runs one release build signed with that public debug key — solely so release lint
(`lintVital*`, which debug builds skip; it broke v0.1.44) gates PRs; the APK is deleted, never uploaded;
see `docs/android-signing.md` before touching package identity or signing.
Direct in-app updates fail closed unless an Ed25519-signed release manifest authenticates the
exact platform filename, size, and SHA-256; GitHub-direct Linux updates replace a writable
running AppImage via a detached helper. See `docs/updates.md` before changing release assets.
The Linux AppImage does **not** bundle mpv (CI installs `mpv`/`libmpv-dev` only for the embedded
fallback build/link) — native Linux playback runtime-discovers and version-gates the host's mpv
(>= 0.40 required); see `docs/player.md`.

## Verification gate

**Never hand work to the user — or to another agent — to try out until the artifact they will
actually run has been rebuilt from the current source. Green tests are not a build.**

```powershell
# Windows: close the running app FIRST (it locks the output and leaves a stale exe behind)
& "$env:TEMP\opencode\rebuild3.ps1"
```

The script prints `FRESH OK`; confirm the change is really in there before handing over:

```powershell
# `Select-String ... -Encoding Default` does NOT work here and must not be used:
# on a 10 MB binary it silently fails to decode whole regions, so a string that is
# provably present reports 0 matches — the inverse of this section's stale-binary
# trap, a *correct* build that looks stale. Search the bytes instead.
$latin = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes(
    'build\windows\x64\runner\Release\data\app.so'))
'<new literal>'.Contains($latin)   # $true when the change really is in the artifact
```

A negative answer is worth double-checking against a **known-present** literal (e.g.
`iptvs/native_hdr_player`) before believing it: the failure mode above is a false *negative*.

**`app.so`'s timestamp is *not* a freshness proof on its own, and treating it as one is actively
harmful.** Flutter caches the AOT snapshot **by content** and the copy keeps the *original*
mtime, so an unchanged payload legitimately keeps an old timestamp; a `git rebase`/`checkout`
rewrites every `lib/*.dart` mtime without changing a byte of content. The script therefore
compares `app.so`'s SHA-256 against the content-keyed AOT in `.dart_tool\flutter_build\*\app.so`
and reports `FRESH OK (content-cached AOT, mtime unchanged)` when they are identical — that hash
match *is* the proof, because the cached snapshot is what Flutter itself reuses. **Never delete
`iptvs.exe` to "force" a rebuild.** Doing so once left the Release directory with **no executable
at all**: the mtime check called a current payload stale, the retry loop deleted the exe eight
times, and only a plain `flutter build windows --release --no-pub` brought it back. If the hash
does not match, the sources really did change — rebuild, don't delete.

Why this is a hard rule and not a nicety, all of it observed on this repo:

- **A Dart change lands in `data\app.so`, never in `iptvs.exe`.** A Dart-only fix leaves `iptvs.exe`
  at its old timestamp, which reads as "nothing changed" — so a correct fix gets reported back as
  not working, and the whole round is spent re-deriving a bug that was already closed. Check
  `app.so`, not `iptvs.exe`; the exe only moves when `windows/runner` native code changed.
- **Do not hold the build hostage to an unrelated open question.** The two number-entry fixes sat
  finished, analysed and fully green, waiting on the user's answer about a video band in a different
  subsystem — and the user spent a run testing a binary from before them. A fix that needs no
  decision gets built immediately, in the same breath as the change.
- **A stale binary produces a log that looks like evidence.** The missing `number jump settled` line
  was the honest output of code that had never been compiled in, and it cost several rounds of
  guessing before anyone checked the artifact's payload instead of trusting the log.
- **Close the app before rebuilding.** A running `iptvs.exe` fails the link; a retried build that
  reuses the old one reports success and leaves the user on the previous binary.

This applies to the same rule as the rest of this file: report what the artifact contains, not what
the source says.

## Orchestration workflow

The lead session (Opus 5) is the **orchestrator**: plan, decompose, synthesize — and keep its own
context lean by delegating rather than doing mechanical work itself.

- **Reasoning-heavy phases** (architecture, debugging complex issues, algorithm design — in this
  repo: focus/D-pad logic, the player stack, `LibraryRepository` merge paths, migrations, RLS)
  → **deep-reasoner** (Opus 5, `.claude/agents/deep-reasoner.md`).
- **Mechanical work** (boilerplate, tests following existing patterns, formatting, simple edits)
  → **fast-worker** (Sonnet 5, `.claude/agents/fast-worker.md`).
- **Registration:** discovery happens at session startup, reads `.claude/agents/*.md` at
  **project level**, and **fails silently on malformed YAML frontmatter**. No `~/.claude/agents/`
  symlinks are needed — that older advice was wrong, and the directory does not exist on the
  current machine while project-level discovery works fine. The classic failure is an unquoted
  `description:` whose text contains a `": "` (e.g. "In this repo: writing tests") — YAML rejects
  the plain scalar and the agent vanishes with no error, which is exactly how `fast-worker` went
  missing. **Always quote `description:`.** Fixing a definition re-registers the agent *mid-session*
  (observed), so a restart is not required — but the fixed agent only becomes callable once that
  re-registration lands. **Fallback** while a named type still isn't registered ("agent type not
  found"): spawn
  `general-purpose` with the matching `model`
  override and make the agent's first instruction "read `.claude/agents/<name>.md` and adopt it
  as your operating rules" — keep the definition file the single source of truth instead of
  paraphrasing it into the prompt.
- **High-stakes decisions**: one deep-reasoner pass that must develop **≥2 competing designs and
  argue the winner**; the orchestrator adjudicates. Reserve a true second, independently framed
  run for hard-to-reverse decisions (schema migrations, RLS changes).
- **Plan waves by file overlap.** Agents whose edits can't collide run in parallel in the same
  tree; every implementing agent's prompt carries an explicit file-ownership list ("you own X;
  don't touch Y"). Clusters that share files run in sequence — or run the shared-file cluster as
  a **read-only diagnose/design pass** in the first wave (no file footprint, so it parallelizes
  freely) and implement from its report in the next.
- **Handoffs between waves**: pass the design report verbatim, plus two caveats — line numbers
  may be stale (match by function name), and the tree contains uncommitted work from other
  agents (build on top; never revert unexpected diffs). A handoff that says "done" carries the
  same obligation as a handoff to the user: **the artifact must be rebuilt first** (see
  "Verification gate"). An agent that ends with green tests and a stale binary has handed over
  a bug report waiting to happen, and the next wave inherits the misdiagnosis, not the work.
- **An agent that changes runnable code rebuilds as its last step, not as a follow-up task.** A
  deferred build is the one omission nobody catches, because every check still passes.
- If an agent dies mid-task (rate limit, crash), **resume it via SendMessage** — its context
  (spec, files already read) survives; a fresh spawn re-pays the whole cold start. Stagger heavy
  Opus agents that don't strictly need to run concurrently — parallel Opus waves can hit
  session usage limits.
- When delegating work in an area covered by a `docs/*.md` detail doc, tell the agent to read
  that doc first — agents get this file automatically, but not the detail docs.

## Architecture

Layered, provider-agnostic. The golden rule: **the UI and cache never know which kind of provider
they're talking to** — everything goes through the `Source` interface.

```
screens/  ──▶  LibraryRepository  ──▶  Source (Stalker | Xtream | M3U | Demo)
                      │                        │
                      ▼                        ▼
                 AppDatabase (SQLite)    MetadataProvider (TMDB | TVDB | MDBList)
```

- **`lib/sources/source.dart`** — the core domain models (`Channel`, `MediaItem`, `Category`,
  `Programme`, `StreamInfo`, `ContentKind`) and the `Source` interface. To add a provider you
  implement this one interface and change nothing else. Read the doc comments here first.
- **`lib/sources/*_source.dart`** — provider implementations: `stalker_source.dart` (MAG portal,
  the largest/most intricate), `xtream_source.dart`, `m3u_source.dart`, `demo_source.dart` (used
  by tests). `Source.subscriptionExpiry()` feeds the sources screen's expiry badge as an explicit
  dated/unlimited/unknown value (never collapse unlimited into unknown); shared parsing lives in
  `expiry.dart` — **read [docs/sources.md](docs/sources.md) before touching expiry or the
  M3U→Xtream upgrade.** Stalker also backfills adult ("censored") genres that
  `get_all_channels` omits, via per-genre `get_ordered_list` (docs/sources.md). Invariants: Stalker **authorizes before asking** (`connect()`, i.e.
  handshake **+ `get_profile`**, before `account_info` — `_call` only guarantees the handshake, and
  the sources screen builds a fresh source per card, which is why the badge read unknown on every
  portal). A far-future sentinel is **unlimited**, but only when written as a date — a bare number
  that far out is a phone number, not a lifetime. An unknown answer logs the payload as key *names*
  plus `expiryValueShape` masks, never values (`phone`/`fname`/`ls` are customer PII). Answers are
  cached device-side (`data/expiry_cache.dart`) — **never in `SourceConfig.settings`**, which rides
  the source row into the cloud; serving from cache is logged and saving a source forces a
  re-check, because a cache that can hide a diagnostic has to say when it is doing so.
  An M3U source that is really an Xtream `get.php` panel is **upgraded** (`upgradeM3uToXtream`):
  fails closed on anything but a real `player_api.php` authentication, keeps the same source id,
  runs on edit-save, at load time (`HomeShell`, background, never on the boot path), and from
  `source_settings_screen`'s tile. **Load time skips cloud-managed sources** — a pull would revert
  them. The web panel detects the same shape but only ever *suggests*: a browser cannot verify a
  provider (mixed content, then CORS, then an unreadable opaque response), so the panel asks and
  the app proves.
- **`lib/data/library_repository.dart`** — orchestration between a `Source` and the cache: serves
  from SQLite when fresh, refreshes EPG on its own schedule, handles paging (`loadMore*`), runs
  metadata enrichment. The most logic-dense file; treat its cache/refresh/merge paths carefully.
  EPG contract: a normally completed empty `Source.epg` result is **success** and atomically
  replaces the cache (clears stale rows, advances `epg_synced_at`); a thrown error retains the
  last good guide with the un-advanced timestamp as the failure record. `replaceEpgStream` is
  the streamed counterpart (large XMLTV guides via the optional `BatchedEpgSource` capability):
  same one-transaction, success-empty semantics, and a cancelled feed must end in a thrown
  `LoadCancelledException` — never a quiet stream close — so the transaction rolls back instead
  of committing a half-fed guide.
  **`load` returns as soon as the channels are ready and refreshes the guide behind them** — and
  the two things that make that safe are load-bearing, not incidental. `ProgrammeSpool`
  (`data/programme_spool.dart`) drains the merged guide to a temp file *before* the transaction
  opens, because `replaceEpgStream` otherwise held its write transaction across each guide's
  **download**, on the single sqflite connection the whole app shares — which serialises reads
  too, and has no upper bound when a guide server stalls. `AppDatabase.epgIngest`
  (`data/epg_ingest.dart`) keeps one refresh at a time app-wide and *waits for* a superseded one
  to stop, not merely cancels it — and `close()` must `await epgIngest.shutdown()`, because an
  ingest mid-transaction doesn't stop when the connection closes; skipping the wait just moves it
  into `_db.close()`, which has no cancellation and logs nothing (a widget test hung there for its
  full ten-minute timeout). A replaced
  guide is announced on `AppDatabase.epgChanged` **carrying the source id** (a refresh for the
  source the user just left reaches the same stream, and re-reading for it would blank the current
  source's now/next). Staleness is decided in `load` before scheduling, so a load with nothing to
  do leaves `pendingEpgRefresh` null — the live status line reads that to say `· updating guide…`.
  Don't reintroduce an `await` on the refresh, and don't feed a lazy provider stream straight into
  `replaceEpgStream`. **A repository's identity is a load signal, not a formality**:
  `ChannelListScreen.didUpdateWidget` watches it with `!identical(old.repo, widget.repo)` and re-runs
  `_loadLive()` on a new one, so `HomeShell._loadActive` must not rebuild the repository for an edit
  that left the cache valid — that made leaving the sources screen cost a full channel load. It reuses
  the loaded one (hence `LibraryRepository.source` being settable) when
  `SourceConfig.hasSameCatalogInputs` and `MetadataConfig.sameConfiguration` both hold, and keeps the
  *source* too when `sameSourceInputs` does. The EPG guide list rides in `fields`, so editing guides
  still re-ingests — the refresh `invalidateEpg` schedules must not be deferred — and a reused
  repository's old source is **retired, not disposed** (`_retiredSources`: `dispose()` force-closes
  the HTTP client an in-flight load is still reading through). See [docs/sources.md](docs/sources.md)
  "Leaving the sources screen must not re-ingest the catalog".
  Because the guide now lands *after* the list is built, two states are
  surfaced that used to be impossible: `LiveController.expectsEpg` sizes rows tall while a refresh
  runs on a source whose `capabilitiesOf(...).epg` is `supported` (an `unknown` source waits and
  sees, so it isn't sized tall for a guide that never comes), and `epgUnavailable` —
  `lastEpgRefreshFailed` **and** an empty guide — reads `· guide unavailable`, since a failure
  behind a *cached* guide is the retain policy working. See [docs/sources.md](docs/sources.md). Don't reintroduce an `isNotEmpty` guard before `replaceEpg`/
  `replaceEpgStream`, and don't write the `sources` row with `INSERT OR REPLACE` (it destroys
  columns the writer doesn't own — see `replaceLibrary`).
- **`lib/data/app_database.dart`** — local SQLite cache keyed by `Source.id`, versioned schema
  with hand-rolled `onUpgrade`. See "Database migrations" below.
- **`lib/data/*_client.dart`** + **`metadata_provider.dart`** — `MetadataProvider`s enriching
  `MediaItem`s with posters/overviews/ratings. `ratingsOnly` providers (MDBList) only contribute
  ratings and run after a visual provider has matched.
- **`lib/data/source_store.dart`** — persists `SourceConfig`s (credentials included) in the OS
  keychain via `flutter_secure_storage`, plus the active source and metadata config. The whole
  source list lives under one storage key (fine: the Windows v4 backend is a DPAPI file with no
  per-entry size cap; Android likewise).
- **`lib/data/local_profile_store.dart`** — device profiles: keychain-persisted `LocalProfile`s,
  per-cloud-profile `ProfileSnapshot`s, the picker's startup mode. See docs/cloud-sync.md.
- **A form that rebuilds `fields`/`settings` from its own controllers must carry forward the
  keys it doesn't render.** `EditSourceScreen._save` and the panel's source form both do this:
  the Dart side keeps unrendered `fields` entries, the panel re-merges unrendered *secret* keys
  (`carryUnrenderedSecrets`) because `set_source_secret` replaces the payload wholesale. Both are
  gated on the kind being unchanged, since field keys are provider-specific. Without it an
  unrelated edit — fixing a label typo, renaming a source in the panel — silently destroys
  `epgUrls` on every paired device. This has now bitten twice (hidden categories and catch-up
  overrides via `settings`, then EPG guides via `fields`); write new keys to be safe by default.
- **`lib/screens/`** — UI. `home_shell.dart` resolves the active source and builds its
  repository. The main browsing UI: `channel_list_screen.dart` (screen state, routes, dialogs,
  and controller/focus ownership), `channel_list_chrome.dart` (tabs, toolbar, dropdowns —
  controller notifications rebuild scoped `ListenableBuilder` subtrees, never the whole screen),
  `live_tab_view.dart` (live body: channel list, category pane, preview panel, catch-up +
  phone-preview sheets), `media_tab_view.dart` (movies/series grid, details sheet, series
  browser; its **"Continue watching" rail leads with the series name**, resolved
  episode -> season -> series by `readSeriesTitlesForEpisodes` — an episode row's own
  `title` is the *episode* name, so a rail of those read as unrelated titles. The tile has exactly
  two single-line runs and its rail height is derived from that, so the episode name lives in the
  semantics label rather than a third line). **A started, unfinished movie card carries a green
  watched-progress bar across the bottom of its poster** — `WatchProgressBar`, one shared widget
  for the card *and* the rail (the rail moved off `AppColors.accent` onto `AppColors.success` so
  the two agree). It's a `Positioned` child **inside the poster's `Stack`**, which is what keeps
  `childAspectRatio`, `textBudget` and `memCacheWidth` untouched; a bar below the poster would make
  the cell geometry follow a value that changes while you scroll. No bar at the end of a film
  because `playback_positions` has no row by then (`kFinishedFraction` 95%, sub-10 s ignored), not
  by a rule in the widget. **Movie tab only** — a movie row's `itemId` *is* the card's id, while a
  series tab's rows are episodes and its grid lists series, so `_loadResumeProgress` publishes an
  empty map there rather than an episode-keyed one that can never match a card (which would read as
  the feature working and invite an invented "average of your started episodes" aggregate).
  **The read runs *after* the rail publishes, not before** — `load()` calls
  `loadContinueWatching()` unawaited, so an extra round trip ahead of the rail pushed the rail's own
  publish a tick later and made `test/media_tab_controller_test.dart`'s generation tests flaky (they
  gate on one `_flush()`); the map lands as an additive `mapEquals`-guarded publish, and `_set` does
  not compare, so that guard is load-bearing. It fails soft. Pinned by the `card progress` group in
  `test/media_tab_controller_test.dart`, `test/media_progress_bar_test.dart`, and the DB group in
  `test/persistence_test.dart`; detail: docs/player.md "The card's watched-progress bar".
  **The movie and series grids are
   reorderable; live, the Continue Watching rail and the season/episode lists
   deliberately are not** (`media_sort.dart`, `MediaTabController.sort`). The five modes are
   release date both ways (default: newest first), name both ways, and **"As provided"** — the escape
   hatch back to the panel's own arrangement, since a portal with deliberate grouping has a reason for
   its order. The choices are **per VOD tab and session-scoped**, not persisted: no preference key, no
   cloud surface, nothing for another device to agree about. **A sorted mode loads the whole catalogue
   (`loadAll`), because global release-date ordering needs every page** — so paging there is a pure
   *display window*: `MediaTabView.displayPages` (owned per kind by `ChannelListScreen._mediaDisplayPages`)
   reveals page `p` at **`p * screenSize - 1` items, because the "Next page" card takes the last cell
   of every screen** — so the card always sits bottom-right (page 1 = 23 items of a 24-cell screen,
   page 2 = 47, not 24/48). The screenful is computed from what actually fits the viewport
   (`MediaTabView._mediaPageSize` — grid columns × visible rows, or the list's visible rows), and a row
   counts only when **at least half of it is visible**, so a sliver of the next row is not "fitting".
   Because the screenful is re-read every build, a resize re-lands the card on the last row with no
   stored bookkeeping, and the card carries **no page number** (a number was wrong after a resize). A
   provider-order ("As provided") tab still fetches a page at a time (`_mediaPagesPerLoad` = 1) and its
   "Next page" also pulls the next page when the controller has unfetched pages. The window resets to
   one screen on every dataset-replacing load, category change and sort change. Note the two fetch
   paths still record the page differently, and must not be "tidied" into agreement: `loadMedia` stores
   the **requested** page (`loadedPages = page`) while `loadMoreMedia` stores the page the provider
   **echoed** (`fetched.page`), because a portal that renumbers is authoritative only mid-stream.
   Pinned by `test/media_paging_test.dart` and `test/media_display_paging_test.dart`. **Card shape is a global device preference, portrait (2:3) or
   landscape (16:9)** (`VodCardOrientation`, `AppSettingsStore`, cycled in Settings), and the whole
   setting is one number: `MediaGridMetrics.posterAspectRatio` is an instance field set by
   `forSize`'s `orientation` argument, which **defaults to portrait** because the column ladder and
   every pinned metric were established against 2:3. `childAspectRatio` already derives the cell
   height from that ratio plus a fixed `textBudget`, so landscape is just a shorter cell. **The
   column ladder must stay width-only** — tile width feeds `memCacheWidth`, which is part of the
   image cache key, so moving it re-decodes every poster for a preference that only claims to change
   height. The grid **listens** (`ListenableBuilder` on the notifier) rather than reading once: the
   tile is toggled from the Settings route pushed *over* the media tab, so nothing there rebuilds on
   its own. The Continue Watching rail stays 16:9 in both modes (its thumbnails are video frames,
   already landscape) and the narrow list thumb stays 2:3 (sized to the text beside it) — neither is
   a card. Pinned by `test/vod_card_orientation_test.dart`, the shape group in
   `test/media_grid_metrics_test.dart`, and the both-shapes sweep in `test/layout_overflow_test.dart`;
   detail: docs/player.md "VOD/series card shape". Dates come from `MediaItem.year`, a
   provider-supplied **`String?`** holding ISO `2026-09-29`, dotted/slashed `29.09.2026`, a bare
   `2026`, or something unparseable — so `releaseSortKey` normalises shape into one integer
   (`yyyyMMdd`) and **an unparseable row sorts last in both directions**, never as year 1: "unknown"
   dragging a name sort or reading as ancient is worse than admitting the provider said nothing.
   Day-first vs month-first slash dates is genuinely ambiguous, and `releaseSortKey` picks **day-first
   for every row**, never per row — a convention misread uniformly still leaves relative order intact,
   while guessing per row does not. A row with only a year takes part in both directions. **Ties keep
   their incoming order** (`favorites_order.dart`'s explicit-last rule, same reason: `List.sort` is not
   stable), which is why Favorites is `orderedByCatalog`-grouped *first* and sorted after — and the
   visible-list memo keys on `sort`, since the snapshot itself is never reloaded. Pinned by
   `test/media_sort_test.dart` and the "grid ordering" group in `test/media_tab_controller_test.dart`
   (`setSort` is idempotent and `_set`-gated, like every other controller publish), `live_focus_coordinator.dart` (the live D-pad selection model),
  `epg_grid_screen.dart` (the TV-guide timeline, selection-cursor model) — both navigation models
  are documented in docs/tv-navigation.md. `sources_screen.dart` manages provider configs
  (add/edit/delete/activate, ↑/↓ reorder via `SourceStore.setAll`); `source_settings_screen.dart`
  toggles a source's categories, edits advanced catch-up timezone/offset/window overrides, and cycles
  the per-source **catalogue refresh interval** (`settings['refreshInterval']`, startup/6/12/24/48 h,
  default 24 — `lib/sources/refresh_interval.dart` + `SourceRefreshStore`); it refreshes **channels +
  VOD, never the EPG**, runs after the cached load (never instead of it), is decided once per screen
  by the pure `planSourceRefresh`, and stores *when it last ran* device-locally in the keychain, not in
  `settings` (which rides the cloud). A manual refresh resets that timestamp. See docs/sources.md
  "Scheduled catalogue refresh". Those edits are persisted on `SourceConfig.settings`; its category rows are **lazy slivers**, because
  `ListView(children: [...])` builds every child up front and a portal with thousands of
  categories rebuilt all of them on every keystroke and every toggle — the D-pad took seconds to
  answer. The filtered lists are cached on the query and the hidden-id set is resolved once per
  section, since `hiddenCategoryIds` rebuilds a `Set` per call. `SourceCapabilityReporter` owns the EPG/catch-up/
  resolution summary; the UI preserves `unknown` for playlist-dependent M3U behavior rather
  than guessing. Favorites are tagged from
  the per-item surfaces and appear as a "Favorites" entry atop each category list. Live adds a
  second **"Favorites · All sources"** entry when favorites exist in a source *other* than the
  active one (`kAllSourcesFavoritesCategoryId`, `global_favorites_controller.dart`): it is **not**
  a filter over the loaded catalog but a cache read across every `source_id`, so it lists channels
  the active source has never heard of. It needs no schema or cloud change — the `favorites` key is
  already `(source_id, kind, item_id)` and `SecretLocatorVault` is process-wide, not per-source —
  and it plays a row through a repository built for its *owning* config (`_repoFor`), never the
  active one. Rows carry an **EPG keyed by `(sourceId, channelId)`**
  (`GlobalFavoritesController.epgFor`, refreshed on the same one-minute cadence as the active
  guide) — never the *active* source's maps, which are keyed by a channel id a foreign row can
  collide with, so reading them would print another provider's programme against this channel.
  Every surface that prints a programme resolves through the owning source (`_epgFor`): the row,
  the preview panel, the phone sheet and the fullscreen player. `LiveTabView.epgFor` is that
  pair-keyed path, and `showsEpg` — not `now.isNotEmpty` — is now the row-height input, because a
  view served by `epgFor` has empty maps while its rows are the tall kind. A foreign source's
  guide is only refreshed while that source is active and so can be stale; that degrades to
  *nothing* rather than to something wrong, since both halves of the query are bounded by the
  current instant. The refresh uses the channel-constrained `nowNextForChannels` (the row set is a
  small known list — the case that query exists for), not the whole-source `nowNext`.
  A favorite starred on the **active** source reaches this view immediately through
  `applyLocalChange`, which inserts the row in catalog order with no I/O: the write goes through
  `FavoritesController`, which knows nothing about this controller, so without it the view only
  caught up on the next full reload. It is an insertion rather than a reload because it runs on
  every star press, and a reload re-reads the OS keychain and requeries every contributing source.
  They **do preview**, on the owning source's repository
  (`LivePreviewController.start(from:)`), and go fullscreen through the same seamless handoff as
  any other row (`_openLivePlayer(repo:)`); the star and the reconnect re-resolve are likewise
  routed to the owning source. The controller **fails soft** — a keychain or cache
  error empties the view rather than taking the main channel list down with it.
  **The preview's identity is `(sourceId, channelId)`, never the channel id alone**
  (`LivePreviewController.isPreviewing`, the screen's `_isPreviewing`/`_repoForChannel`). Channel
  ids are unique only *within* a provider, and this view is exactly where two of them meet — an id
  match alone can be a different provider's channel, which silently means going fullscreen on the
  wrong stream, suppressing a hover re-arm that should have fired, or locking the preview panel to
  the wrong row. Every "is this the previewing channel?" comparison in `channel_list_screen` and
  `live_tab_view` goes through that pair; the one inside `_openLivePlayer`'s read-once block reads
  `previewSourceId` as a local beside `previewChannelId` rather than calling the helper, because
  re-reading the controller mid-decision is the desync that block exists to prevent.
  **Every Favorites view is ordered by the catalog, never by insertion**
  (`favorites_order.dart`): source order (the sources screen's own arrangement) → category order
  → the channel's order inside that category. Favorites are a *set* keyed by
  `(source_id, kind, item_id)` synced as a delta, so there is deliberately nowhere to store a
  sequence — two devices could not agree on one, which is the conflict class the delta exists to
  avoid — and the order is therefore derived at display time. Callers pass rows **already filtered
  out of the catalog in catalog order** and `orderedByCatalog` only regroups them, so there is no
  index to build over a 250k-channel list and nothing that can drift out of step with it; the
  incoming order survives as the innermost tie-break, which is **explicit because `List.sort` is
  not stable**. An unranked row (category dropped by a refresh, null `categoryId`, deleted source)
  sorts *last* — it is still a deliberate pick, and ranking it 0 would float the least
  identifiable rows to the top. The live view ranks against the **full** category list, not the
  visible one, because a favorite is shown even when its category is disabled. The category order
  it ranks against is now stable in its own right — see "Category order" below.
  Live channels
  with an archive (`Channel.hasArchive`) get a catch-up button (`CatchupSheet`, played via
  `Source.resolveArchive`). `diagnostics_screen.dart` views/exports the in-memory log;
  `profile_pick_screen.dart` is the boot-time profile picker.
- **`lib/widgets/`** — shared widgets: `focusable_card.dart` and `tv_text_field.dart` (central to
  TV navigation — see docs/tv-navigation.md), `app_bar_action.dart` (AppBar actions are icon +
  **label** on the wide layout — every TV, where a remote can't hover a tooltip — and icon-only
  with a tooltip below it; use it rather than a bare `IconButton` for AppBar actions),
  `profile_avatar.dart`, `favorite_controls.dart`,
  `release_notes_view.dart` (dependency-free changelog renderer used by the update dialog), and
  `image_utils.dart` (all network images go through `cached_network_image` with display-sized
  decode — don't add bare `Image.network`). **Pass `memCacheWidth` alone, never both dimensions:**
  both non-null selects `ResizeImagePolicy.exact`, which decodes to the target aspect *regardless
  of the source's* — i.e. `BoxFit.fill` at decode time, leaving the `BoxFit.cover` that was meant
  to crop with nothing to crop. Every VOD poster was stretched 5–38% (varying tile to tile in one
  row, since the box aspect moved with how much text a tile carried) and a backdrop-less
  continue-watching thumb squashed 2:3 into 16:9. Use `ResizeImage(..., policy: .fit)` explicitly
  if a ceiling on the other axis is ever genuinely wanted.
  **`memCacheWidth` is part of the cache key, so a size that wobbles is a re-decode** — a miss
  re-runs the whole async resolve with the `placeholder` on screen. Decode widths snap *up* to
  `kImageCacheSizeBucket` (32 physical px) so a window drag / text-scale change / fractional grid
  division reuses the bitmap, and — the bug that prompted it — **a focus indicator must never
  change layout**: `FocusableCard`'s ring is a `foregroundDecoration` behind a fixed-width
  transparent border (`kFocusableCardBorderWidth`, which `MediaGridMetrics.tileBorder` reads
  rather than restates), because a `decoration` border insets the child and animating it
  1→2 px re-decoded every poster the D-pad walked over (docs/tv-navigation.md). Every `errorWidget` must call
  `logImageFailure` (`image` diagnostics scope, redacted, throttled): call sites deliberately render
  the *same* widget for `placeholder` and `errorWidget`, so a screen of fallbacks is otherwise
  indistinguishable from one still loading — which is exactly why a real "no artwork until restart"
  report left nothing in the exported log.
- **`lib/theme.dart` carries the design tokens, the breakpoints, and the motion helper.**
  **The wide/narrow choice goes through `isWideLayout(size)`, never a bare width comparison** — a
  television is the two-pane layout whatever its logical width says. Logical width is physical
  pixels over the device pixel ratio, so one 4K panel reports 960 at dpr 4.0 and 873 at dpr 4.4:
  a set-top box lands either side of `kWideLayoutMinWidth` on a density it picked, and the phone
  layout it falls into is silent (no category pane, no preview panel, so no shared-engine preview
  path at all). `isTelevision` (`data/device_class.dart`) is resolved **once, awaited in `main`
  before the first frame** off the existing `iptvs/device` channel, and fails closed to false.
  Kotlin answers it from `UiModeManager` **or** the leanback/television system features, because
  boxes that report `UI_MODE_TYPE_NORMAL` while being televisions are common. Don't lower
  `kWideLayoutMinWidth` to fix a TV — that band exists to keep large phones in landscape on the
  handset layout.
  `AppColors` includes semantic `danger`/`warning`/`success` (they exist because six call sites had
  hand-rolled the same red) and `accentFill` — `accent` darkened just enough that white 14 px bold
  clears WCAG AA 4.5:1 on a filled button (measured 4.64:1; plain `accent` is 3.95:1), while
  `accent` itself stays the brand hue for rings and progress, where it sits on the dark ground.
  Every breakpoint lives here and **must be measured against `MediaQuery.sizeOf`**, never a
  `LayoutBuilder`'s post-`SafeArea` constraints. Route explicit animation durations through
  `appMotion(context, …)` — Flutter honours the "remove animations" accessibility flag for its own
  route transitions but not for `AnimatedContainer` and friends, which is most of what this app
  animates.
- **`lib/player/player_screen.dart`** — playback lifecycle/native coordination;
  `player_overlay.dart` contains the embedded presentation widgets. See "Player" below +
  docs/player.md.

## Key conventions

- **Provider-specific data rides in `extra`.** `Channel`/`MediaItem` carry a
  `Map<String,dynamic> extra` that only the owning `Source` interprets (Stalker `cmd`, Xtream
  stream id, etc.). Keep provider details out of the shared models and out of the UI.
- **Resolve streams at play time, never ahead.** Stalker `create_link` URLs are short-lived.
  `Source.resolve` / `resolveMedia` are called right before playback.
- **Sealed playback locators: models come out of the cache encrypted; only `LibraryRepository`
  reveals them.** `protectSecretLocators` encrypts the locator fields of `extra` (`url`, `cmd`,
  `streamUrl`, …) into `extra['secretLocator']` on write; `readChannels`/`readMediaItems`/
  `readMediaItemsByIds` map rows **synchronously with no crypto** and hand back *sealed* models
  (decrypting a 250k-channel library to play one channel was the dominant cold-start cost — see
  docs/validation-baseline.md). `AppDatabase.revealChannel`/`revealMediaItem` decrypt one model,
  and are called at exactly these **reveal points** in `library_repository.dart`: `resolve`,
  `resolveArchive`, `resolveMedia`, `mediaDetails`, and the **`parent` argument** of `loadMedia`
  and `loadMoreMedia` (`StalkerSource._seasonPlaybackHints` reads a *cached* season's
  `extra['cmd']` to build playable episodes — the easiest one to miss). Reveal is a no-op on an
  already-plaintext model, so it's always safe to add one. Missing a reveal point makes that
  content silently unplayable, so every `Source` site that consumes a locator field carries a
  release-inert `assert(!hasSealedLocator(...))` (`m3u_source` resolve/resolveArchive,
  `stalker_source` resolve/resolveMedia/`_seasonPlaybackHints`) — keep that assert when adding a
  locator-consuming path. Write paths must survive a *sealed* model round-tripping back through
  them (`protectSecretLocators` preserves the existing ciphertext when it finds no plaintext
  locator); `resetEnrichedMediaDisplayFields` relies on this. On-disk format is unchanged — this
  is a model-lifetime contract, not a schema one. Pinned by `test/sealed_locator_reveal_test.dart`,
  the "AppDatabase sealed locators" group in `test/persistence_test.dart` (including a
  `SecretLocatorVault.decryptCount` assertion that a bulk read decrypts *nothing*), and
  `test/secret_locator_vault_test.dart`.
- **Async publishes are generation-guarded.** `MediaTabController`, `LiveController`, and
  `HomeShell._loadActive` each hold a monotonic `_loadGeneration`: only dataset-replacing ops
  (`load`, `setCategory`) bump it and publish results only if still current; subordinate ops
  (`loadMore`, `search`, `clearSearch`, `refreshNowNext`) read it without bumping and abandon
  superseded results — so a refresh always beats an in-flight pagination, never the reverse.
  Disposal is expressed solely through `_disposed`, checked in `_set` (the only
  `notifyListeners` site). Pinned by `test/media_tab_controller_test.dart` and
  `test/live_controller_test.dart` — keep new async publish paths behind these guards.
  Additive to (never instead of) the generation guard: a `LoadToken`
  (`lib/data/load_token.dart`) per generation stops a superseded load from **overwriting a
  populated cache** (the generation guard only stops the UI publish). It is
  delivered via the settable `LibraryRepository.loadToken` field — set in the same synchronous
  prologue as the call, read into a local before the method's first `await` — not a method
  parameter, because the pinned tests' `_GatedRepo` overrides would break on any signature change.
  **A settable field is inherited unless a caller claims it**, and the repository is shared: the
  movie and series `MediaTabController`s are built over one, each cancels only its own token, and
  `dispose` cancels one outright. So every caller sets `loadToken` in its own prologue — including
  the non-controller ones, `MediaDetailsSheet`'s season/episode drill-downs, which set it to
  **null** (nothing can supersede a load writing to its own `(kind, parentId)` key) rather than
  inheriting a token that may already be cancelled. Pinned by `test/media_details_episode_test.dart`.
  **Overwriting, not writing: a superseded load still *seeds an empty* cache**
  (`db.replaceLibrary`/`replaceMediaLibrary`'s `onlyIfAbsent`, whose predicate is evaluated
  *inside* the write transaction and is the exact complement of the matching cache-read gate).
  Refusing the write outright is how a device gets permanently stuck, and it is a field report,
  not a hypothesis: a 66 MB playlist costs ~55 s on a low-end TV box (29 s download + 26 s
  isolate parse), every repository rebuild cancelled the load — the load-time M3U→Xtream probe
  alone does one per app start — and the finished catalog was discarded, so the cache stayed
  empty and the next attempt paid the full 55 s again, forever. Overwriting stays barred because
  the channel cache has **no age check** (anything written stands until a forced refresh),
  commit order is not fetch order, and `upgradeM3uToXtream` keeps the source id — so a late M3U
  write can land playlist-shaped rows under a source that is now Xtream, whose `resolve` falls
  back to `channel.id`, silently unplaying every channel. `loadMoreMedia` keeps the plain skip:
  it guards page bookkeeping, not freshness, and returns early when there is no cache to seed.
  A superseded load also schedules **no** EPG refresh — `EpgIngestCoordinator` is last-start-wins,
  so a late one would take the slot from the correct refresh already running. `loadToken` does
  not reach the EPG batch path at all; the coordinator mints its own tokens for that. Pinned by
  `test/epg_batch_cancel_test.dart` and the "replaceLibrary onlyIfAbsent" group in
  `test/persistence_test.dart`.
- **Large provider payloads are ingested one-pass off the main isolate.** Xtream/Stalker
  catalogs ≥256 KB go bytes-in→typed-list-out through top-level workers
  (`decodeLiveChannelsBytes`/`decodeMediaItemsBytes`, Stalker `_ingestStalkerChannels`) — the
  dynamic JSON graph never crosses the isolate boundary; smaller payloads parse inline (isolate
  spawn would dominate). Downloaded XMLTV guides go **to a temp file, never to memory**
  (`xmltvGuideFeed` → `readToFile`), and the worker inflates and event-parses them from disk
  (`parseXmltvFileBatched`), skipping unmatched programmes at the start tag — so a guide's size
  costs disk and parse time, not RAM (`kEpgWorkload` 512 MiB body / 4 GiB decoded; don't
  reintroduce a whole-body read on that path — docs/sources.md "Guide size"). Batches stay
  bounded (single in-flight batch by design) on their way into `replaceEpgStream`.
  Sources with a batched guide implement the optional `BatchedEpgSource` capability interface —
  deliberately separate from `Source`, since `implements` doesn't inherit default bodies.
  Don't add new parse/map work on the main isolate for provider-sized payloads, and don't
  return both a dynamic and a typed graph from a worker.
  A source that memoizes its catalog in memory (Stalker `_channelCache`, M3U `_ensureParsed`,
  Xtream `_mediaListCache`) implements the same-shaped optional `RefreshableSource { invalidate() }`
  so a *forced* reload actually re-hits the provider: `LibraryRepository.load`/`loadMedia` call
  `invalidate()` (via `is RefreshableSource`) only when `forceRefresh` is true — never on a
  non-forced load or on `loadMoreMedia` pagination.
- **A source can carry several XMLTV guides, and they merge per *channel*, never per
  row.** `fields['epgUrls']` (newline-separated, **additional** guides only — the primary stays
  `epgUrl`/`url-tvg`, `xmltv.php` or `get_epg_info`, so an older build pulling this source still
  reads guide 1)
  feeds `mergeEpgGuides` (`sources/epg_guides.dart`), capped at `kMaxEpgGuides`. A channel is
  claimed by the first guide that carries it and later guides are filtered against those claims,
  because `nowNext`'s "now" half has no `GROUP BY` and folds rows into a map by channel id — two
  guides covering one channel would make its now-playing programme *nondeterministic* and draw
  overlapping cells in the EPG grid. **Failure policy turns on whether the failing guide had
  already yielded:** a guide that fails *before* yielding (refused, 404, bad gzip) wrote nothing
  and is skipped — the provider's own guide being the broken one is exactly why a user adds a
  top-up — while one that fails **mid-feed rethrows**, because its batches are already in the
  caller's transaction and completing normally would commit a *truncated* guide as a whole one,
  dropping the previous guide and advancing `epg_synced_at`. All failing likewise rethrows, since
  `replaceEpgStream` reads a normally-completed empty stream as a successful *empty* guide.
  Matching is `tvg-id` first, then normalised display names for whatever the ids missed
  (`sources/epg_matching.dart`), and **both indexes are many-valued — one guide entry claims
  *every* channel that carries its id or its name** (`kMaxMatchGroup` = 8 on each). That is the
  normal case, not a fallback: a panel gives every feed of one channel the same `epg_channel_id`
  (Xtream Codes: both the UHD and the FHD row of `Первый канал` carry `146`, because to the panel
  they are one channel with one schedule). `tvgIdToChannelId` used to be `tvg-id → one channel`
  with `map[tvg] = c.id` — *last row wins*, so the feeds collided, the last one took the whole
  guide, and the others were permanently bare, with no second path to them because a provider's own
  guide is id-only. **Names are for user-added guides only** (`epgNameIndexFor`) — a provider's
  guide and its playlist share ids by construction, so enabling names there would change every
  existing install's EPG on upgrade and put a 250k-channel index build on the main isolate for
  users who added nothing. On **Stalker**, whose channels carry no `tvg-id` at all, names are the
  only path — which makes `normalizeChannelName`'s token separator load-bearing rather than
  cosmetic: it is whitespace and punctuation and **never `[^a-z0-9]`**, because that class counts
  every non-Latin letter as a separator, so a Cyrillic name once reduced to the empty key and a
  Russian portal's guide matched nothing at all. Same trap on Xtream Codes for every feed the
  panel gave no `epg_channel_id` to (`mapLiveChannels`). Both halves are the same report: two
  feeds of one channel, **both** on `epg_channel_id: 146`, one guide entry declaring both names,
  fetched from a **link the user specified in the source's EPG settings** — the id map silently
  dropped one feed, and the name path could not pick it up either. Stalker's own guide is not
  XMLTV, so it joins the merge as a plain feed, and
  its third-party downloads deliberately bypass the portal transport, which would otherwise send
  the MAC cookie and Bearer token to an arbitrary user-supplied host. Saving the guide list calls
  `AppDatabase.invalidateEpg` (clears `epg_synced_at`, **keeps** the programmes), or the change
  would be invisible until the guide aged out. Read
  [docs/sources.md](docs/sources.md) before touching the claim rules.
- **Liveness is provider metadata, not inferred.** `StreamInfo.isLive` is set by the `Source`.
  Don't guess from stream duration (an HLS live window looks finite). Live = no seek bar.
- **Secrets must never reach logs, on-screen errors, or exported diagnostics.** Provider URLs and
  errors carry credentials. Use `redactUrl` (`lib/data/net.dart`) for any URL that goes into an
  error/log, and `redactText` (same file) for free-form text that may *embed* a URL — it also
  scrubs credential-shaped *path* segments (`/live/user/pass/1.ts`): token/long-shaped segments,
  plus the two segments right after an IPTV route keyword (`live|movie|movies|series|timeshift|play`)
  regardless of length (the stream id/filename stays), which `redactUrl`'s query-focused redaction
  doesn't touch. Stalker additionally uses `redactStalkerDiagnostic` /
  `_redactUrl` for MAC/Bearer tokens. The diagnostics log is user-exportable — assume anything
  you log may be shared for support. **Redaction is not a reason to log nothing**: a failure line
  must name the *source* (`repo.source.name`) and carry the exception type plus its redacted text
  (`detail=`), because `sourceLoadErrorMessage` is a deliberately coarse bucket and an export of
  those alone could not tell an `HTTP 403` from a closed client — nor, on a four-source install,
  say which source failed.
- **A provider that answered with a status gets that status quoted back at the user.**
  `sourceLoadErrorMessage` reads `HTTP <nnn>` out of the thrown message and maps 401/403/407 to
  credentials, 404/410 to the URL, 429 to rate-limiting, and **everything else to the provider** —
  including codes outside the standard range, since a real report arrived as `HTTP 884`. The status
  is printed on purpose: the URL beside it is already redacted, so the number leaks nothing, and
  attributing a refusal to the provider stops the old generic "check its details and try again"
  sending users to re-type credentials that a `player_api.php` call had authenticated seconds
  earlier. The keyword path stays for status-less failures — `{"user_info":{"auth":0}}` arrives as
  HTTP 200 and only `XtreamSource.connect` knows it failed. Pinned by
  `test/source_load_error_test.dart`.
- **HTTP timeouts.** All `HttpClient`s set `connectionTimeout` (TCP handshake only). For the
  response, use `response.readBytes()` and `.timeout(kHttpReadTimeout)` on `request.close()`
  (both in `lib/data/net.dart`) — `connectionTimeout` does **not** cover a server that connects
  then stalls mid-body.

## TV / remote navigation (essentials)

Full D-pad navigability is a hard requirement (Android TV target). **Read
docs/tv-navigation.md before touching focus or navigation code** — the current design replaced a
per-row-focus approach whose races produced repeated D-pad bugs, and the doc records why.

- Lists/grids use `FocusableCard`; text inputs use `TvTextField` ("OK to edit") — never a bare
  `TextField` on a TV-facing screen (it traps D-pad focus). The profile-PIN dialog
  (`widgets/pin_entry.dart`) takes that further and uses **no text field at all** off desktop: a
  3x4 pad of `FocusableCard`s is arrow-navigable by construction and needs no IME, while hardware
  digits still bubble up from the focused button so a remote's number keys work
  (`pinKeypadForPlatform`). **That pad fits the window rather than scrolling** — a D-pad cannot
  scroll a modal, so a key below the fold is a profile that cannot be opened: `Flexible` +
  `FittedBox(scaleDown)`, the explanatory line dropped below a 420 px viewport, and digit labels
  opted out of text scaling. Swept over sizes and text scales in `test/layout_overflow_test.dart`.
- **Exception:** the two live-tab lists and the EPG grid are **selection models** — one focus
  node + a selected index; rows are *not* focus targets. Never add focus nodes to their rows.
  Both live lists set an explicit `itemExtent` (`kChannelRowExtentWithEpg` 112 /
  `kChannelRowExtentPlain` 72 / `kCategoryRowExtent` 48 in `live_tab_view.dart`) — uniform rows
  make index→offset exact; the tallest EPG row must fit the extent.
- **The EPG grid's horizontal reveal must use the geometry the row painted, not the programme's
  own times.** Grid rows are horizontally virtualized, so a reveal that pans away from the cursor
  doesn't hide the selected cell — it stops building it, and the guide "jumps somewhere with no
  apparent focus". `_revealProgrammeAt` therefore takes (items, index) and passes `nextStart` to
  `_cellWidth` exactly as `_layouts()` does, and a cell `width >= _timelineWidth` is revealed from
  its **leading** edge (the title is drawn there).
- **Movement is deliberately asymmetric: Down wraps; Up never wraps — it escapes upward.**
  Right first enters the selected channel row's **favorite star** (the intra-row
  `ChannelRowColumn`; OK there toggles the favorite in place) and Left peels it back before
  crossing panes; beyond that Left/Right cross panes, and every arrow is consumed (geometry
  traversal never runs in the live body).
- **A body with no focusable rows must put focus on its own action.** The live tab is a
  selection model, so when a load fails there are no rows *and* no focus targets: the "Try again"
  button rendered, was the only thing on screen, and could not be pressed from a remote. Both
  tabs' error bodies are now `SourceErrorView` (`widgets/source_error_view.dart`), whose retry
  autofocuses — safe because that body only mounts on a failed load, which replaces the list
  wholesale. Pinned by `test/source_error_view_test.dart`.
- **A media tab opens its focus on its Continue-watching rail, when it has one.** The movies/series
  tab is ordinary focus nodes, but its *initial* one is a priority rule (`railTakesFocus` in
  `media_tab_view.dart`): rail drawn + nothing played this session → the rail's newest entry;
  rail drawn + `lastPlayedId` still visible → **that grid tile, unchanged on purpose** (returning
  from a details sheet must land where you left); no rail → grid item 0 (the old behaviour);
  searching → the results (the rail isn't drawn); loading/error/empty body → **not the rail**, the
  body's own action owns it. The rail used to be unfocusable entirely (no `autofocus`, no focus
  node) while the grid's `else i == 0` sent a fresh open to the catalog's *first* title with the
  recents drawn right above the cursor. **Exactly one autofocus candidate per tab** is part of the
  rule — two racing ones are decided by tree order — so both sites are gated on the same flag, and
  the rail's sliver is built by a closure because the answer is only known inside the
  `LayoutBuilder`. Pinned by `test/media_tab_focus_test.dart` (asserts the autofocus *set*, and real
  `hasFocus`). Detail: docs/tv-navigation.md "Where a media tab opens its focus".
- **Typed channel numbers are one shared entry, and the coordinator does not perform the jump.**
  `ChannelNumberEntry` (`screens/channel_number_entry.dart`) owns the digits, the match, the commit
  rules and the chip, and both surfaces that accept a number (the live list and the fullscreen
  player) use *that* one — a chip is learned once, and two entries would be two answers to "what
  does 200 mean". 1–4 digits; **exact match anywhere in the catalog beats a prefix match**, then the
  first prefix match in catalog order; a four-digit match **commits on the keystroke**; a shorter or
  unmatched buffer waits 1500 ms (clock restarts per digit) or Enter/Numpad-Enter/Select; a
  no-match commit is a no-op. The **search space is every channel some view can draw** (catalog
  minus disabled categories, plus favorites — a favorite is drawn from a disabled category on
  purpose), never `_visible`: matching against the current group would make the same digits mean
  different channels depending on where the user was. `LiveFocusCoordinator` handles digits **before**
  the empty-list bail (a number is the way *out* of an empty group) and hands the matched channel to
  the host's `onNumberCommitted` — it used to move its own cursor, which only worked for a channel
  already on screen, and the live list is a selection model that cannot select what it does not draw.
  The host reveals (search cleared first, then the pure `planNumberJumpGroup` ladder: current group →
  "All channels" → Favorites), selects, and then per surface: retarget a running preview (never
  restart one already showing that exact `(sourceId, channelId)`, never *start* one that is not
  running), or in full screen the same same-engine swap a zap does, realigning the list behind
  without focusing it. **Both live player routes must wire it** — `_openLivePlayer` *and*
  `_openFullscreenDirect` (narrow windows, cross-source favorites); the second one originally passed
  `onZapChannel` alone, so digits were inert on a phone and on every foreign favorite, and a null
  gate fails silently rather than visibly. **The reveal's scroll is deferred, the cursor is not:**
  after a group switch `selectChannel(index, reveal: false)` runs synchronously and
  `revealSelectedChannel()` runs in a post-frame callback, because the list scrolls by
  `index * extent` arithmetic and a reveal issued before the new group is rendered is clamped
  against the *outgoing* list (and `_selectCategory`'s post-frame `jumpTo(0)` would override it) —
  a jump that selects correctly and looks like it did nothing, with the row above the viewport.
  `_selectCategory` takes `scrollToTop: false` for that case. A channel no view can draw is not
  matchable, because the chip would name it and
  then select nothing — and re-enabling a category the user disabled is not a keystroke's decision.
  The preview **picture** takes a double click as fullscreen (a single click is already "preview
  this"), which requires `HitTestBehavior.opaque` because the running video is `IgnorePointer` and
  nothing else under the middle of the picture would satisfy a `deferToChild` detector.
  Pinned by `test/channel_number_entry_test.dart`, `test/channel_number_chip_test.dart`, the
  `number entry` and `revealing a jumped-to channel` groups in
  `test/live_focus_coordinator_test.dart` and the preview-picture group in
  `test/live_tab_layout_test.dart`. Detail: docs/tv-navigation.md "Typed channel numbers".
- **The Back ladder** (`channel_list_screen` `_handleRootBack`): Back never changes data or
  filters — it peels exactly one rung per press toward the exit (rung list in
  docs/tv-navigation.md); chrome (AppBar/toolbar buttons, route key `''`) sits above the ladder;
  exit is behind a double-Back snackbar.
- Pinned by `test/live_focus_coordinator_test.dart`, `test/channel_list_focus_test.dart`,
  `test/epg_grid_test.dart`, `test/tv_text_field_test.dart` — keep them green.
- Selection-model rows still expose accessibility semantics: useful
  channel/programme labels, selected state, list position, activation, and
  favorite state/action. `FocusableCard` consumers should provide a concise
  `semanticsLabel` when visual descendants would otherwise read as a fragmented
  tile.
- **The fullscreen live player has its own key map, live only while chrome is hidden.** Arrows zap
  only when `live && !chromeVisible`: Up = the next higher list index (`index + 1`) and **both
  directions wrap** — a deliberate divergence from the live tab's Up-never-wraps rule, since there
  is nothing here for Up to escape *to*. Right is the "previous channel" toggle, and **Left (or
  GUIDE) opens the quick list** (Phase 6). Digits, PageUp/Down, CHANNEL_UP/DOWN
  and the last-channel key are
  live regardless of chrome, since they're unambiguous; none of the zap keys ever reveal the
  chrome — revealing it on the first Up would hand the second Up to the control row instead of the
  next channel. With chrome visible, Up/Down keep their ordinary volume binding. The digit-entry
  constants and key map (`kDigitEntryCommitDelay`/`kDigitEntryMaxDigits`/`kDigitEntryKeys`) are
  shared between `LiveFocusCoordinator` (the live tab) and `player/zap_command.dart` (in-player) —
  typing a channel number on a remote is the same gesture in both places. A digit match is scoped
  to the **zap range only** (never the whole source); a miss shows "No channel N" in the banner
  and leaves playback alone. **Android implements the same rules natively (Phase 2, done):**
  `ZapKeyPolicy` (Android-free, pinned like `PlayerBackPolicy`/`ReconnectPolicy`) is consulted in
  `HdrPlayerActivity.dispatchKeyEvent` ahead of Back/`super`, digit-pending Back/OK read a native
  mirror of `setZapBanner`'s buffer rather than round-tripping to Dart, and a settled `zapTo`
  rebuilds the engine only when headers or the buffer preset actually changed (resetting every
  watchdog counter either way, never `armHandoff`) — a rebuild of an adopted engine un-adopts via
  `SharedEngine.invalidateFromFullscreen` first. The favorite star reports **both** live (`nativeZap
  favorite:0|1`, so a session that has zapped away updates the right channel) and at close
  (`RESULT_FAVORITE`, the one guaranteed to survive a kill) — both absolute, never a toggle, so they
  can't disagree. **Phases 3–5 are now implemented too**: the shared Flutter overlay draws its own
  bottom-bar banner (`ZapBannerState`, pure — reused by Windows' SDR embedded surface), the Windows
  native HWND surface owns a C++ key ring (`zap_key_policy.h`, a structural mirror of `ZapKeyPolicy`)
  plus its own GDI banner, and the Linux Lua OSD registers its own zap-only key bindings per stream
  and draws the same banner. Only iOS's zap input remains outstanding.
  Detail: docs/player.md "Live zapping", "Android native input + banner (Phase 2)", "Windows",
  "Linux"; the key table is in docs/tv-navigation.md "In-player navigation".
- **The quick list (Phase 6) is a mode stack over one list, not a three-column panel.**
  categories → channels (each with a now-playing line) → that channel's schedule for **today**;
  Right/OK descends, Left/Back ascends, Back at the top closes. It opens on the *channels* mode
  positioned on the playing channel — the only rung that needs no fetch, so it draws on the frame
  of the keypress. **Picking a category re-ranges the session's Up/Down too** (an empty one is
  refused rather than applied, since a session with no entries has no channel to be on); on the
  cross-source Favorites range, whose rows have no provider categories, the top mode lists the
  **owning sources** instead. OK on a channel zaps to it through the ordinary settle path and
  closes; OK on a **past** programme of an archive channel does **not** play catch-up in place —
  catch-up is VOD-shaped, so the controller records `pendingCatchup`, asks the route to close, and
  the channel list opens it through the shipped `_playCatchup`. While the list is open it owns
  navigation: nothing changes channel except an explicit OK, digits move the cursor instead of
  zapping, and the zap banner yields to it. Dart owns cursor, mode and paging; natives get a
  **window** of ~40 preformatted rows (`setQuickList`, `kZapWindowRows`) and send
  `zap:list`/`zap:close`/`zap:move:±n`/`zap:activate`/`zap:descend`/`zap:back`. The frozen payload
  is in docs/player.md "The quick list (Phase 6)"; the selection model and its Back rungs are
  in docs/tv-navigation.md. **The pointer speaks the same vocabulary**: a click on a row is the keys'
  OK verbatim (`zap:move:<delta>` only when the row is not already under the cursor, then
  `zap:activate`), and one wheel notch is `zap:move:±kZapWheelRows` — a cursor move, never a channel
  change. That is a rule about *meaning*, not about focus: rows are still not focus targets, and a
  press in the panel's margin is swallowed rather than reaching the chrome toggle underneath. On the
  Windows native surface it costs `WS_EX_TRANSPARENT`, which the **banner keeps** and the open list
  drops, and the wheel has to be handled on the native **video** surface too, because Win32 sends
  `WM_MOUSEWHEEL` to the focus window rather than to the one under the cursor. **Every surface renders it** (Flutter overlay, Android Compose, Windows
  GDI, Linux Lua) and every renderer **prints, never formats or derives**; the highlight is drawn at
  `selectedIndex - windowStart`, never from a row's own `selected` flag, so scroll and highlight are
  one computation. **While the list is open, its surface claims the arrows and Back regardless of
  chrome visibility** (the one exception to "arrows zap only while chrome is hidden" — a list on
  screen gives them an unambiguous job) and opening it stands the chrome down, since a control row
  left up behind it strands the D-pad. Desktops have no GUIDE key: Windows uses `G`, Linux `g`
  (registered per stream like every zap-only mpv key). Android's quick-list Back is a rung on
  `nextPlayerBackAction` (a gesture Back has a list to close) while the digit rung deliberately is not.

## Cloud sync + profiles (essentials)

Optional Supabase-backed web panel for managing sources; device pairs by code, pulls the profile's
sources/metadata/favorites, and can push back. Hidden entirely unless built with
`SUPABASE_URL`/`SUPABASE_ANON_KEY` (`cloud_config.dart` `isConfigured`). **Read
docs/cloud-sync.md before touching sync, pairing, profiles, or `supabase/`.** Non-negotiables:

- The **anon key ships in clients by design**; access control is *only* RLS + `SECURITY DEFINER`
  RPCs (`supabase/migrations/`, deny-by-default — read the first migration's header before
  changing it). The `service_role` key must never appear in any client or this repo.
- **Favorites are the one collection that syncs automatically** (`cloud_auto_sync.dart`, started
  from `HomeShell`; everything else stays manual Pull/Push). That works only because they push a
  **delta**, not a set: `push_favorites_delta` merges adds/removes per row under the profile's row
  lock, so same-row conflicts resolve by arrival order and **no `updated_at` revision guard is
  needed**. The delta comes from `favorites_outbox` (schema v14), written only by `setFavorite`
  (user intent) and never by the pull, which rebases the outbox onto the pulled state.
- **No tombstones in `profiles.favorites`, deliberately — don't add keys to that element shape.**
  A removal drops the element outright. Tombstones only pay off in a "changes since T" sync; this
  pull **mirrors** the profile, so an absent favorite is already a deletion on every device. More
  importantly the shipped `pullFavorites` reads only `source_id`/`kind`/`item_id`, so any new key
  is invisible to it — a `deleted_at` entry looked like an ordinary favorite, meaning an old store
  build would pull a deleted favorite back and push the resurrection to everyone. That is why the
  legacy whole-set `push_favorites` stays forever and why the migration is safe to deploy ahead of
  a store release: nothing changes what an old client reads or writes.
- Devices are anonymous users with **no direct table writes**; the only device→cloud write path
  is the owner-scoped `push_*` RPCs. Push is row-level last-write-wins **refined by field-preserve**:
  broad fields merge through `merge_preserving_nonempty(stored, incoming)` so a device push can
  never blank a stored non-empty value — **only a direct panel edit can clear one**.
- **Ownership is a schema invariant, not just an RPC predicate.** `profiles`/`sources` carry a
  redundant `unique (id, owner)` and every owner-bearing child is pinned by a composite FK
  `(parent_id, owner) → parent(id, owner)` (`..._tenant_isolation.sql`), so a row whose owner
  disagrees with its parent's is unrepresentable. This exists because an owner-guarded
  `ON CONFLICT` **skips silently instead of rejecting**, which let a crafted `push_sources` payload
  plant a credential on another account's source. Keep new child tables inside that pattern.
- **Never add `alter table … force row level security`.** The five RPC-only secret tables have
  zero policies by design and the `SECURITY DEFINER` RPCs run as `postgres`, which owns the tables
  — `FORCE` would make every one of those RPCs silently read and write nothing. Defence in depth is
  the table-level `REVOKE` (which also strips TRUNCATE — RLS does not filter TRUNCATE). Rationale
  in docs/cloud-sync.md.
- **Secrets are isolated + optionally E2EE (Phase 2/3 — implemented; docs/cloud-sync.md).** The
  cloud `sources.fields`/`metadata_configs.config` rows carry only **broad** keys (a server strip
  trigger enforces it); secret keys (`secret_keys.dart`: mac/username/password/playlistUrl/epgUrl/
  epgUrls/userAgent; tmdb/tvdb/tvdbPin/mdblist keys) travel through dedicated RPCs (`get_secrets`, a
  per-source `secret` element on `push_sources`, `p_secret` on the 3-arg `push_metadata`) as
  `{format:0|1,payload}`. **Absent secret = server preserves** (never blanks). When a profile opts
  into E2EE the secret is `format` 1 — AES-256-GCM under a per-profile content key the device
  unwraps with its own P-256 key pair (`cloud_crypto.dart`; **secret format is server-enforced**).
  `CloudCryptoStatus` = off/ready/**locked**; a locked device (no CK — devices never prompt for the
  passphrase) disables Push and badges credential-less sources as needs-attention (fail closed,
  never activate empty credentials). Pull applies a **defensive local overlay** so a locked/partial
  profile never blanks a locally-held secret. **The server is not trusted on E2EE state:** both
  clients keep a sticky per-profile mark (device `cloud_e2ee_marks`, panel `iptvs_e2ee_seen`), and a
  server reporting E2EE *off* — or an *older* `ck_version` — after a client has seen it on is treated
  as a **downgrade** and fails closed to `locked`, never to plaintext. Only an explicit local
  acknowledgement clears the mark, because a legitimate panel-side disable is indistinguishable from
  the attack. Write paths throw rather than emit `format 0`; the read path still degrades to empty.
  Crypto is protected vs DB-at-rest / operator / broad
  RLS bugs, **not** vs an unlocked/XSS'd panel or a paired device holding the CK; `rotate_content_key`
  is the revocation remedy (against a compromised *device* — not against a compromised backend). `package:cryptography` 2.9.0 has no VM/native ECDH, so P-256 is pure-Dart
  in `cloud_crypto.dart` (RFC-5903-validated); vectors in `test/fixtures/crypto_vectors.json`.
- **The pairing screen's QR is a shortcut over the existing code flow, not a new path.** It encodes
  `<panelUrl>/?code=…` (`pairingPanelLink`); the panel accepts it only in `gen_pairing_code()`'s
  exact shape (`pairingCodeFromUrl`), **stashes it in `localStorage` under the code's own 10-minute
  TTL** (`emailRedirectTo` carries no query and the magic link often opens a new tab, so nothing
  else survives sign-in — and widening the redirect would risk the exact allow-list), and **clears
  it only on a successful `claim_pairing`**: both `onAuthStateChange` and `getSession()` render on
  load, so a consume-on-render blanks the form the other pass just filled. The QR sits
  beside the printed code and link, never instead of them, and every failure (bad `PANEL_URL`,
  blank code, over-long payload) drops the QR rather than the screen. Rendering is
  `PairingQrView` (`lib/widgets/pairing_qr.dart`), swept over sizes/text scales in
  `test/pairing_qr_test.dart`: it sizes the symbol against the window (a fixed `size` narrower than
  its slot is clamped on **width only** and draws an unscannable rectangle) and bounds the link at
  `maxLinkLength`, because **`QrValidator.validate` reports `valid` for a payload that then throws
  in the painter** — `_calculateTypeNumberFromData` walks versions 1..39 and returns the largest
  when nothing fits rather than failing.
- **The panel re-renders on a change of signed-in *identity*, never on an auth event.**
  supabase-js re-emits `SIGNED_IN` on every hidden→visible transition and `TOKEN_REFRESHED` on its
  refresh ticker; `render()` rebuilds the tab body, and the panel's sub-views (source editor,
  metadata form, a half-typed Pair form) live only there — so the old handler threw the user's open
  form away, and re-locked the CK, every time they switched browser tabs. `sessionIdentityChanged`
  (`panel/src/validate.js`) gates it on the user id; `secrets.lock()` likewise notifies only when
  something was really unlocked. Read [docs/cloud-sync.md](docs/cloud-sync.md) before adding a
  `render()` to any listener.
- **A device is named at pairing time, and RPC overloads here are arity-distinct with no
  `DEFAULT`.** The device sends a platform-derived suggestion (`request_pairing(p_label)` →
  `pairings.suggested_label`); the panel's Pair form sends an optional name
  (`claim_pairing(p_code, p_label)`). Precedence is **panel > existing `devices.label` (same owner
  only) > suggestion > `''`** — the scalar form of the never-blank rule, so a blank panel field
  can't clobber a hand-chosen name, and a cross-account re-pair never inherits the old owner's
  name. `suggested_label` is attacker-controlled (anonymous device → another account's device
  list): bounded 256 (**must stay ≤ `devices_validate`'s limit**, or a device can deny its owner's
  claim), control-chars rejected, frozen on UPDATE, `esc()`-rendered. **Never add a `DEFAULT`
  beside a narrower overload** — PostgREST matches on the parameter-name set and answers
  `PGRST203`, breaking 100% of pairings; the narrow forms stay forever as delegates because app
  installs are arbitrarily old and a panel tab outlives a deploy. Device-side naming is
  deliberately zero-typing (read-only hint, no focus target) — the primary device is a TV remote.
- Every profile (local and cloud) owns a `ProfileSnapshot`; switching snapshots the outgoing
  state and restores the incoming one, keeping cloud-managed source ids scoped per profile so
  pulls never leak sources across profiles (`local_profile_store.dart`).
- **A profile can carry an optional 4-digit PIN, and it is a gate on a shared television — not a
  security control.** Ten thousand values means whoever holds the verifier recovers the PIN
  whatever the KDF cost, so `profiles.pin` is a **broad** column (encrypting it would buy nothing
  and would make the gate unenforceable on an E2EE-**locked** device, which is the one that most
  needs it), and `kProfilePinIterations` is sized for a set-top box verifying on the UI path, not
  for an attacker. What makes guessing impractical is the dialog's cooldown (5 misses → 30 s).
  The format `pbkdf2-sha256$<iters>$<salt>$<hash>` is a **three-implementation contract** —
  `profile_pin.dart` derives *and checks*, `panel/src/pin.js` only ever *sets* (a browser cannot
  be asked to prove a PIN), Postgres validates the shape only — and both client tests assert the
  same vectors, because nothing would reveal a mismatch later. An unparseable verifier **fails
  closed** (a future format must not read as "no PIN" on an older build), and the server's shape
  check is deliberately *narrower* than the app's parser — storing a verifier the device cannot
  read is the unopenable profile that check exists to prevent. Devices write it through
  `set_profile_pin`, never directly; a PIN change advances `profiles.updated_at` (deliberately
  *not* favorites-exempt). The wrong-PIN cooldown is **per profile, not per dialog** — in the
  dialog's state it reset on every Cancel, which made it decoration. Device-side: a locked *active* profile overrides the startup mode and
  withdraws Skip, the active profile isn't re-asked outside that boot, cloud verifiers are
  mirrored **with their names** in `LocalProfileStore.cloudPins` so an offline boot can still draw
  and unlock one, and manage-mode **delete is deliberately not behind the PIN** — it reveals
  nothing and is the only way out of a forgotten PIN on a local profile. Read
  [docs/cloud-sync.md](docs/cloud-sync.md) "Profile PINs" before touching any of it.
- The app boots into `ProfilePickScreen`, which self-decides via
  `shouldShowPickerAtStartup(mode, profileCount, activeProfileLocked:, hasActiveProfile:)` —
  single-profile installs boot straight to `HomeShell` unless the active profile is PIN-locked, or
  the device is **ownerless**: the state deleting the active profile leaves behind (empty
  baseline, nothing marked active — deliberately, so no snapshot is overwritten with state that
  isn't its own). The picker is the only thing that restores a snapshot, so short-circuiting past
  it there boots into an empty library that a relaunch cannot repair — `auto` with one profile
  left never opens the picker again. Ownerless is a **persisted mark**
  (`LocalProfileStore.ownerless`), never inferred from "is an entry drawn as active": an offline
  device can't draw its active cloud profile *and still holds its sources*, while a stale cloud
  `active_profile_id` (never cleared by switching to a local profile) would otherwise claim the
  empty baseline through both the boot short-circuit and `_selectProfile`'s identity shortcut.
  While it is set, `_check` marks no entry active at all. Delete-of-active also **adopts the sole
  survivor** when it is local and unlocked (`_adoptSoleSurvivor`); a locked or cloud survivor is
  left for the picker.
- Cloud writes are bounded by BEFORE-triggers on the tables (binding panel *direct* writes too)
  plus pre-mutation count/size guards in the push RPCs, and pushes are rate-limited DB-side —
  limits are sized ≥10x over a 250k-channel portal, and rejections are `iptvs: `-prefixed
  `check_violation` errors that never echo payload values. Every `SECURITY DEFINER` function pins
  `search_path = ''`. Last-write-wins timestamp authority is server `now()` — clients send no
  timestamps. `profiles.updated_at` is the whole-snapshot revision: source and metadata child
  mutations advance it through `touch_profile_snapshot_revision`, so destructive device pushes
  can detect intervening panel changes. **A favorites-only update is exempt** — `profiles_touch`
  preserves the revision when nothing but `favorites` moved, because favorites are device-owned
  (the panel never touches them) and automatic pushing would otherwise fire the "panel changed"
  overwrite warning constantly, training users to click through it. The child-revision path sets
  a transaction-local `iptvs.force_profile_revision` flag so its `updated_at`-only write is *not*
  exempt; both directions are pinned by `supabase/tests/15_profiles_favorites_revision.test.sql`,
  and the "still advances" cases matter most — a revision that silently stops moving disarms the
  guard. Client error surfaces (`friendlyCloudError`, panel `friendlyError`) must never
  render Postgres `details`/`hint` (CHECK-style "Failing row contains" leaks credentials).

## Category order

**`readCategories`/`readMediaCategories` order by `rowid`, which is the provider's own order —
never by `title`.** A fresh load shows `Source.categories()` (the provider's arrangement, the one
the user recognises) while the cached read used to re-sort alphabetically, so the pane silently
reshuffled between a forced refresh and the next app start — and once Favorites derived their
order from it (`favorites_order.dart`), the favorites list reshuffled too.

The **invariant that makes an implicit rowid sound is that these tables are never patched in
place**: `replaceLibrary`/`replaceMediaLibrary` delete the source's rows and re-insert the whole
list, in list order, in one transaction, so SQLite hands out ascending rowids along it. A stored
`position` column would be a second copy of a number the table already has, bought with a
migration. **If a path is ever added that updates a category row in place, add the column
instead.** (`replaceMediaLibrary`'s paged `parentId != null` branch re-inserts categories without
deleting first, so `ConflictAlgorithm.replace` moves them all to fresh rowids — harmless, because
it rewrites the whole list in order.) Two non-hazards, recorded so they aren't re-litigated:
`VACUUM` renumbers rowids but rewrites rows *in rowid order*, so relative order survives (and
nothing here vacuums); a duplicate category id inside one payload collapses to the *later*
position, the same row the alphabetical read would have shown. Pinned by `persistence_test.dart`.

## Database migrations

`AppDatabase` is at `schemaVersion = 14` (v14: `favorites_outbox`, the pending local favorite
changes a cloud *delta* push sends — a favorite in the cloud but not locally is either "deleted
here" or "added there and not pulled yet", and `favorites` alone can't tell those apart; written
only by `setFavorite` (user intent), never by the pull, which mirrors through
`clearFavorites`/`setFavorites`; v9: `favorites` table, deliberately separate from
`channels`/`media_items` so a refresh never drops favorites; v10: `channels.archive_days` →
`Channel.hasArchive` / catch-up; v11: VOD playback positions / Continue Watching; v12:
`idx_prog_source_start(source_id, start)` on `programmes` for the source+time now/next lookup —
channel-scoped guide/catch-up queries keep using `idx_prog_lookup`; v13:
`idx_prog_now(source_id, start, stop, channel_id)`, the *covering* index for the now/next "now"
query — `stop` is in the index so the `stop > ?` term is decided without a table lookup per
candidate row). The two `nowNext` halves are index-pinned by design: "now" is served by
`idx_prog_now`, and "next" carries an explicit **`INDEXED BY idx_prog_lookup`** because the
planner otherwise picks `idx_prog_source_start` and sorts every future programme through a temp
B-tree (measured 952 ms vs 98 ms on a 960k-programme guide; `ANALYZE`, which production never
runs, picks the pinned index on its own). That pin is a hard dependency — dropping or renaming
`idx_prog_lookup` makes the query fail outright — so the v13 branch re-asserts it, and
`explainNowQueryPlan`/`explainNextQueryPlan` pin both plans in `persistence_test.dart`. When
changing the schema: bump `schemaVersion`, add an
`onUpgrade` branch, make new tables/columns idempotent (`CREATE TABLE IF NOT EXISTS`, the
`_isDuplicateColumn` guard) — **and keep every branch re-entrant**: there is no `onDowngrade`
handler, so an older build opened against a newer file silently re-stamps the version down
without undoing anything, and upgrading again re-runs the branches over a schema that already
has their changes. **Design trap:** upgrading from before v3 calls `_createMediaTables`,
which builds the *current* media schema, so later `oldV >= 3` ALTER branches are intentionally
skipped for those users — therefore **any table `_createMediaTables` doesn't create must also
have an `oldV < N` repair branch**, or fresh installs miss it (the v7 `external_metadata` bug:
created only in an `oldV >= 3 && oldV < 7` branch, fresh installs crashed on every metadata
query; v8 fixed it both ways). `AppDatabase.openAt(path)` is the `@visibleForTesting` seam used
by `test/persistence_test.dart`. Connection tuning lives in `onConfigure` (WAL, `synchronous =
NORMAL`, an 8 MB `cache_size`); `sqflite` runs it outside the migration transaction, which is
what makes `journal_mode` legal there. `temp_store` is deliberately left at the default —
`readChannels` sorts by `number, name` unindexed, so `MEMORY` would move an unbounded sorter
into RAM on a 250k-channel source. **Supported upgrades are the publicly shipped schemas only**
(8–12 → current; tag ranges in docs/validation-baseline.md), pinned by
`test/released_schema_fixtures_test.dart` — per released version: fixture → migrate →
pragma-based schema parity with a fresh install → seeded-data checks → stable second open. Keep
that suite green (and extend the fixtures) whenever the schema changes; pre-v8 branches are
best-effort dev-era repair paths outside the claim.

**A repair migration must never be able to stop the app from starting.** The one migration that
runs *before* `runApp` is `migrateAllSourceIdentities`, and the Windows window is shown on the
**first Dart frame** — so a throw there yields a live process with no window, no frame, and nothing
on screen to explain it. That is a real report, not a hypothetical: one install held the same
provider under three `sources` rows (two stable ids and a credential-derived legacy key), so
`migrateSourceNamespace`'s `UPDATE ... SET source_id` hit
`UNIQUE constraint failed: categories.source_id, categories.id` and the app "did not start". Two
invariants now hold, both pinned by the `stable identity migration` group in
`test/persistence_test.dart`: **the stable namespace wins a collision** (a legacy row whose key
already exists under the destination is deleted, every non-colliding legacy row still moves, and the
PK columns are read from `PRAGMA table_info` rather than hardcoded because they differ per table),
and **failure is non-fatal** (`migrateAllSourceIdentities` logs redacted and skips the source,
`main()` guards the call as a last resort). Don't move that call after `runApp`, don't let it throw
out of `main()`, and don't add a moved table to the list without checking the delta push and the
read paths that key on `source_id`. See docs/sources.md.

## Player (essentials)

`player_screen.dart` plays a resolved `StreamInfo` via `media_kit`, with native-HDR paths on
Android (`HdrPlayerActivity`: **ExoPlayer default**, **mpv fallback** only when ExoPlayer can't
decode — chiefly DV P5 on non-DV hardware, needing the vendored libdovi AAR), Windows (native
HWND surface, mpv d3d11 — for HDR; a same-channel **SDR** preview→fullscreen stays on the embedded
texture for a seamless handoff via `preferWindowsEmbedded`, escalating embedded→native once on
PQ/HLG detection, the same SDR-embedded/HDR-native split Linux uses). **VOD, catch-up and
preview-less live open on the native HWND surface** — they deliberately do *not* pass
`preferWindowsEmbedded`, so the constructor default (false) leaves them native. That is the 0.1.63
behaviour and the one that plays correctly: forcing them onto the embedded texture (a local
experiment) showed VOD as a black picture with working audio, and was reverted. Only the SDR adopted
preview→fullscreen handoff passes `preferWindowsEmbedded`
(`decision.adoptsEmbeddedPreview && Platform.isWindows && !streamLikelyHdr`); an HDR one escalates to
the real D3D11 surface. **Both Windows surfaces run `hwdec=auto-copy`, not `auto-safe`**, on their
respective paths (`lib/player/hwdec_policy.dart` for the embedded controller, `player_screen.dart`'s
`_configureNativePlayer` for the native one): `auto-safe` negotiates d3d11va zero-copy, which loses
the bottom chroma rows and draws the green stripe. See docs/player.md "The embedded Windows surface
asks for `hwdec=auto-copy`" and the native paragraph after it., and iOS (**implemented,
on-device validation pending** — a presented `UIViewController` owning an `AVPlayerLayer`, the
`HdrPlayerActivity` analogue: **AVPlayer default** for real HDR/PiP/AirPlay, **libmpv via
`media_kit` fallback**, always SDR on iOS, for containers AVFoundation refuses; see docs/ios.md
and docs/player.md "iOS"). Linux: embedded
`media_kit_video`/libmpv (with the shared Flutter
overlay) is the default fullscreen path, and a host-discovered (not bundled), version-gated
(>= 0.40, 0.41 recommended) native mpv window with an IPTVS-specific GPU/OSD Lua overlay is used
**only for an HDR stream on Wayland** (X11 has no HDR output path, and SDR gains nothing from the
non-adoptable native process) — same-channel-preview HDR is decided ahead in `_openLivePlayer`,
otherwise `PlayerScreen` escalates embedded→native once on PQ/HLG detection. Other platforms:
embedded `media_kit_video`, HDR tone-mapped to SDR.
**Read docs/player.md before touching playback, preview, or overlay code.** Non-negotiables:

- **Windows handoff: set `wid` before `vo`** in `_configureNativePlayer`, or mpv flashes a stray
  top-level window.
- **Windows system tray icon** (docs/player.md "System tray icon"): the runner puts the app icon in
  the notification area and intercepts `WM_CLOSE` so closing the window hides it to the tray instead
  of quitting. Restore = left-click; quit = tray **Exit** or the in-app double-Back exit, both of
  which set `force_quit_` so the close cannot be re-intercepted. The in-app exit must use the
  runner's `exitApp` method, not `SystemNavigator.pop()` — the Windows engine handles
  `System.exitApplication`, so a bare `pop()` is a no-op there. `close_to_tray_` (default true) is the
  X-button policy, settable via `setCloseToTray`; `OnDestroy` removes the icon through the retained
  `tray_owner_hwnd_` because the base class has already nulled its own handle by then. Hiding sends a
  native `trayHidden` event on `iptvs/tray` (the Windows `hidden` lifecycle does **not** fire for a
  `SW_HIDE`), and Dart pauses the preview/player on it via `silenceRequest`; restoring sends
  `trayShown` and resumes via `resumeRequest`. The **boss key** is F12 (a `HardwareKeyboard` handler
  on the app root, plus a runner-side `WM_KEYDOWN`/`VK_F12` for the native HDR surface) and just calls
  `hideToTray`. A global Settings screen (avatar menu → Settings) hosts the close-to-tray, random
  zapping and always-on-top-in-fullscreen preferences in `AppSettingsStore`.
- **Windows remembers the window's position and size** (`lib/player/window_placement.dart`), on by
  default. Dart owns the record (keychain, `AppSettingsStore`) and the runner owns the HWND, so the whole
  native surface is `getWindowPlacement`/`setWindowPlacement` on `iptvs/native_hdr_player` — the
  **frame** rect in physical pixels (`GetWindowRect`, never `GetClientRect`: client coordinates shave
  the border off on every run), plus `IsZoomed`. Three rules are load-bearing. **Recording is by
  *moment*, never `WM_MOVE`** (a keychain write per drag frame): the tray hide (`silenceRequest`, where
  `GetWindowRect` still answers) and `paused`/`detached`/`hidden`. **A monitor can be gone**, so the
  runner requires the rect to still land on one via `MonitorFromRect` + **`MONITOR_DEFAULTTONULL`**
  (`NEAREST` would accept a detached monitor, and a window restored onto one is the failure that needs no
  bug report — the app looks like it did not start); a refusal is `false`, not an exception, and the
  runner's own startup placement stands. **A malformed record is discarded whole, never half-applied**,
  and `maximized` must be a real `bool` — it picks `SW_MAXIMIZE` vs an explicit rect, so coercing a
  corrupted value to `false` would open a maximized window as a resizable one at the maximized rect.
  Turning the setting off deletes the record; a surviving record is still not applied. Pinned by
  `test/window_placement_test.dart`; detail: docs/player.md "System tray icon".
- **Windows: the runner sizes mpv's VO window itself** (`ResyncNativeVideoRenderer`) — never rely on
  mpv's `--wid` parent hook. mpv reaches `ResizeBuffers` only via a real `WM_SIZE` on its child HWND
  (`VO_EVENT_RESIZE`), and its `EqualRect` early-out never revisits a size it missed: a dropped edge
  left a `1920x1080` surface with mpv's child at the pre-fullscreen `1264x681`, painting the top-left
  with black around it, permanently. The post-transition passes additionally **force** a `WM_SIZE`
  (1px step) even when sizes agree, covering the sibling failure where `resize()` abandoned a
  swapchain resize mid-frame — same symptom, and undetectable from Dart (`osd-dimensions` reads
  `vo->dwidth/dheight`, already correct there). A repaint-level "VO refresh" fixes neither.
- **Android preview and fullscreen share one engine** (`SharedEngine` adoption) — only one
  provider connection ever exists (single-connection accounts); the Activity never releases an
  adopted engine and **hands it back in `finish()`, not `onDestroy`** (Dart's return leg runs as
  soon as the result arrives, and `onDestroy` can lag seconds on a TV box — a zapped return's
  stop/open used to land on a still-adopted engine and leave the preview black), and the preview is never paused around the *adopted* handoff. But **any
  *non*-adopted fullscreen (last-channel zap, EPG-grid play) must silence the running preview** in
  `_openLivePlayer` — even one previewing a *different* channel — or its audio doubles up behind the
  new pipeline: a same-channel preview is *paused* (resumed on return, `pausedPreview`), a
  different-channel one is *stopped* (`stoppedPreview`, releases the 2nd connection; not restarted).
  **iOS's AVPlayer↔mpv engine switch is a cross-engine case of the same rule: stop + re-resolve,
  never pause** — a paused media_kit engine still holds its provider connection, and accounts are
  single-connection, so pausing across a Dart↔Swift handoff would double-connect exactly like an
  unpaused different-channel preview would.
- **The preview→fullscreen handoff's *return* leg has its own liveness watch, in the engine.**
  `ExoPlayerEngine.attachPreviewSurface` arms `previewFrameWatch`: no frame within
  `PREVIEW_NO_FRAME_REBUILD_MS` (3 s, sized like the forward leg's `HANDOFF_NO_FRAME_STALL_MS`
  and for the same IDR-wait reason) triggers **one** `rebuildVideoDecoder`, then a log-only
  verify pass. It lives in the engine rather than in `HdrPlayerActivity` because the Activity —
  which owns the forward leg's `FrameLivenessWatch` and its ticker — is finishing by the time the
  return leg runs, so the return leg had no watchdog and no recovery at all. Coming back is the
  same output-surface transition as the claim, on the same hardware that re-instantiates a codec
  for one, and a `setOutputSurface` that produced no frames left the preview black
  **permanently**, with nothing in the log but silence where a `first frame sinceReattachMs=`
  should be. Found on a stream that changed codec mid-session (HEVC→H.264 across a `kind=ended`
  reconnect), so the codec handed back to the preview was one created against the *Activity's*
  SurfaceView — nothing channel-specific, and any reconnect during a long fullscreen session
  reaches it.
- On a TV remote the preview is **deliberate and locked**: only OK (or a pointer tap on the row)
  starts/switches it; D-pad focus movement never does. The one exception is the **start-up resume**
  (`lib/data/last_channel_store.dart`), which is a deliberate OK the user already gave on a previous
  run. The preview engine is stopped when the app backgrounds or exits. A second OK **while that
  same channel's preview is still resolving waits
  for the in-flight resolve and then goes fullscreen** (`decideChannelPlayAction` 
  `LivePreviewController.pendingStart`) - it must never fall through to "start a preview", which
  superseded the in-flight `create_link` with a second one and reloaded the running shared engine:
  the visible stream reload behind the Android TV "it reconnects when I go fullscreen" reports.
- **The start-up resume selects the last live channel once per screen, and starts its preview only
  on the wide layout.** `ChannelListScreen._maybeResumeLastChannel` runs at the end of the *first*
  `_loadLive` (guarded by `_resumeAttempted`, so a Reload or a source change inside the same screen
  does not re-run it) and never opens fullscreen - selection plus a preview says "this is where you
  were" while leaving one press from anywhere else. The decision is `planResumeAction`, a **pure
  function**, so the rules are tested without a keychain, a widget or a provider: the record must
  match the active `sourceId` (a channel id is unique only within a provider), the channel must be
  one a view can draw, and nothing may be playing already (`_resolving || _preview.hasPreview`) -
  resolving into a running preview is the double-connect single-connection portals cannot survive.
  Three things it deliberately does **not** do: never fullscreen, never a preview on the narrow
  layout (no panel to show it, and the engine would spend the user's one connection on video nobody
  can see), and never unmute - the preview it starts is muted on every platform including Android,
  because unprompted sound at launch is a worse failure than a silent picture. It must not go
  through `_revealAndPreview`, which only ever *retargets* an already-running preview (a selection
  move must never start one); it reveals and starts the preview itself. The record is
  **device-local, never `SourceConfig.settings`** - that blob rides the source row into the cloud,
  so a last-watched channel there would push a rewrite on every channel change, advance
  `profiles.updated_at` and hand a paired phone the television's channel; the same argument
  `ExpiryCache` makes, hence keychain and not a table. It is keyed by **profile** (local first, then
  cloud, then `kNoProfileResumeKey`) while the **preference** is per source
  (`settings['autoResumeLastChannel']`, `SourceConfig.autoResumeLastChannel`, absent = on and only
  `false` is ever written) beside `aspectMode` and `bufferPreset`. The record is written by
  `_notePlayedChannel`, which takes the `sourceId` for the same reason the preview's identity is
  pair-keyed - keep it that way, and note it now has **five** call sites including the zap quick
  list, so a zap is remembered as the last channel too. A failure to read it is a log line, never a
  snackbar: the app is fully usable starting normally. Pinned by `test/last_channel_resume_test.dart`.

- **Two device-wide preferences hide the clock badge and the VOD time readout, and the shared
  overlay keeps both on screen while the chrome is down.** `showPlayerClock` /
  `showPlaybackTimes` (Settings, `lib/player/player_chrome_prefs.dart`; default-on, only an explicit
  `false` written) gate the top-bar clock and the two texts either side of the VOD scrubber — hiding
  the readout keeps the scrubber. When the chrome auto-hides, `player_overlay.dart`'s
  `_persistentHud` draws the clock top-right and the readout bottom-right (`IgnorePointer`), so they
  are readable *during playback* rather than only while the mouse moves. The preference reaches every
  surface (`showClock`/`showPlaybackTimes` on the native payloads); the always-on HUD is implemented
  on the embedded/shared overlay, with the native surfaces applying it to their chrome only so far.
  **The dated clock badge is the machine's own regional format on Windows** — the OS long date
  (formatted by NLS from `LOCALE_SLONGDATE`, so the inflected month is right) + short time, sourced
  once over `iptvs/clock` (`clock_format.dart`) so the native GDI overlay and the shared Flutter
  overlay cannot disagree, with the hand-rolled English `Sat 8 Aug · 16:02` as the fail-closed
  fallback everywhere else.
  See docs/player.md "Player chrome preferences" and "The clock badge's regional format".
- **The live chrome is one layout on every surface that draws its own overlay.** Where the VOD
  scrubber sits, live gets a three-row EPG strip (programme title + `HH:mm – HH:mm`, progress bar,
  `Next · HH:mm – HH:mm · title`); LIVE is a **top-bar badge**, and the badges read source, LIVE,
  resolution, HDR, fps, clock — in the compact labels every native uses (`1080p`, `HDR10`, `50fps`,
  **nothing** for SDR; Dart's pure `resolutionBadgeLabel`/`hdrBadgeLabel`/`fpsBadgeLabel`/
  `sourceBadgeLabel`/`playerClockLabel`). **Control buttons are one geometry across the surfaces**
  — 44x40 r12 in the Flutter pointer metrics (`EmbeddedOverlayMetrics`) and the Windows GDI overlay
  (`kNativeButtonWidth`/`kNativeButtonHeight`/`kNativeButtonRadius`), 44dp on Android
  (`PlayerDimens.ButtonSize`); a text button picks its own width, never its own height. The GDI
  overlay additionally draws text with **`ANTIALIASED_QUALITY`, never ClearType** — it is a
  per-pixel-alpha layered window, where ClearType's subpixel filter leaves colour fringes it never
  writes alpha for (docs/player.md "Windows"). The jump-to-live-edge control is a plain text chip reading
  **"Go to live"** on every surface — never "LIVE", which duplicated the status badge greying beside
  it — and it **hands focus to play/pause before it disappears** (it is the one control that removes
  itself while focused; on a D-pad that stranded the remote until Back). Android Compose, iOS UIKit,
  the Windows GDI overlay, the Linux Lua OSD and the shared Flutter `EmbeddedPlayerControls` must all
  agree — the two Windows surfaces show the same channel to the same user, chosen only by whether
  the stream is HDR. The Lua OSD is pinned by `linux/mpv/overlay_layout_test.lua` (headless ASS
  render, run in CI with `luac5.1 -p`) — the only thing that executes that script outside a
  Wayland+HDR session. **The in-player zap banner is a fifth thing all four surfaces must agree
  on**: an identity run (channel number · name, or an accent digit readout mid-entry, or a transient
  message/position-of-total), plus the same live EPG strip, in the same bottom-bar slot — reusing the
  bar's own drawing rather than a layout of its own (`ZapBannerState`/`_zapBanner` in Dart,
  `PaintZapBanner`/`DrawChannelIdentityRow` in the Windows GDI overlay, `draw_zap_banner` in the Lua
  OSD, `ZapBanner` in Compose). **The banner shows the cursor's channel and guide; the bottom bar
  shows the playing one** — a held key's acknowledgement has to be ahead of what is actually on
  screen, and reading the playing channel's fields there would show yesterday's channel through the
  banner during a fast scan.
- **Overlay Back is owned by the root `onPreviewKeyEvent`** (not the `BackHandler`) so a focused
  control can't eat the first press to clear its highlight; single-press peels menu→info→hide→exit.
  **Every surface answers that same ladder**, including the shared Flutter overlay
  (`EmbeddedPlayerControlsState.handleBackPeel`, which used to peel the info panel *only* — so Esc
  with the chrome up left the player outright) and, natively, the Windows HWND surface
  (`windows/runner/player_back_policy.h`, where Escape used to exit outright from any state; it
  carries no quick-list rung, because the key ring claims that press first). The Flutter menu
  rung is the Navigator's, since the track menus are modal routes that answer Escape themselves. The route's Escape binding is the one key
  binding that must **not** reveal the chrome first, or the hide rung would undo the reveal and
  the exit rung would be unreachable. The on-screen back arrow still exits directly.
  Relies on predictive back staying **off** (no `enableOnBackInvokedCallback`). Live channels get a
  **favorite star**, and it is in **one slot on every surface**: the control row, immediately right
  of "Go to live", at that row's ordinary button size (Kotlin `RightCluster`, iOS `clusterStack`,
  the Windows GDI `BottomLayout::favorite`, the Flutter `cluster`, the Lua OSD). **The quick-list
  opener has one slot the same way**, so the rule is a two-control one: the same row, the opener
  immediately *left* of "Go to live" and the star immediately *right*, both at ordinary button
  geometry, on every surface, the opener drawn only when the stream is **live and zap is
  enabled** (Android `EXTRA_ZAP_ENABLED`, Windows `zapEnabled` on `setControlState`, Flutter
  `zapEnabled`, Lua the presence of the pushed `quickList` block — all fail closed). It is tinted
  by nothing (it opens a panel; it isn't state) and is a focus stop like the star. It is the only
  way a mouse or a finger reaches the list. **Windows' opener toggles** (`zap:list`/`zap:close`,
  the only mouse-only way to close a panel that isn't a hit target) because that surface keeps
  its chrome up over the list; Android, Linux and the Flutter overlay only **open**, since
  opening stands their chrome down and takes the button off screen. Each surface draws its own
  icon set's bulleted-list glyph. The keyboard half is `GUIDE` **and `G`**, which every desktop
  surface binds (the Windows key ring, the Lua OSD's `g`, and the shared Flutter overlay's `keyG`
  — no PC keyboard has a `GUIDE` key, and Windows SDR live lands on that overlay). Windows/Flutter/Lua
  used to draw it in the top bar among the badges at three different sizes. The accent tints the
  *glyph*, never the button, whose filled state means focus. The native one round-trips state via
  Intent extra + a
  `RESULT_FAVORITE` reply on close (no live channel from the Activity to Dart).
- **Buffer depth is a per-source preset, and only the *sustained cushion* moves between the
  presets.** `settings['bufferPreset']` (`low`/`normal`/`high`, absent = normal) reaches ExoPlayer
  as a name on the native `open` payload — its `LoadControl` is a build-time argument, so
  `SharedEngine` rebuilds the engine when the preset changes, exactly as it does for changed
  headers — and mpv as **`cache-secs` only**, layered over `kLiveMpvOptions`
  (`player/buffer_preset.dart`, applied on the embedded, preview, Windows-native, Linux-native and
  Android-fallback paths). `demuxer-max-bytes` is deliberately left alone: media_kit already owns
  it via `PlayerConfiguration.bufferSize`, and this app sets it *per surface*, so driving it from
  the preset would override two deliberate different choices with one — and retune the VOD cache
  (sized for seek smoothness) from a control whose UI talks about stability.
  **The start gates deliberately do not move:** what absorbs network variance once playing is
  `min`/`maxBufferMs`, while the gates decide how long a zap stares at black — and they cannot
  rise far anyway, because a stream below the resume threshold sits in `STATE_BUFFERING` and
  `ReconnectPolicy.STALL_RECONNECT_MS` (8 s) of that reloads the source, so the 4x margin caps the
  resume threshold at 2 s. `normal` is byte-for-byte the previously hardcoded tuning on both
  engines (the mpv map is *empty*), so an untouched install plays exactly as before.
  iOS takes the same name on the same payload and applies it as
  `AVPlayerItem.preferredForwardBufferDuration`, held on the engine (not passed to `load`) so a
  reconnect or "Go to live" keeps it — a preset that survived only the first open would revert to
  automatic buffering on exactly the flaky link it was raised for. **`normal` leaves that property
  unset on purpose**: AVFoundation's default (0) means "the player chooses", and writing a concrete
  duration in its place would change the default install while claiming to preserve it — the same
  reason the mpv map for `normal` is empty. `ExoBufferPolicyTest` asserts every invariant for
  **every** preset, which is the point now that the durations are user-selectable.
- **The aspect cycle is Fit → Fill → Stretch → 16:9 → 4:3, and `Fill` ≠ `Stretch`.** Fill *crops*
  to fill and keeps the picture's shape (`RESIZE_MODE_ZOOM` / mpv `panscan=1.0` /
  `.resizeAspectFill` / `BoxFit.cover`); Stretch *distorts* to fill and keeps every pixel
  (`RESIZE_MODE_FILL` / mpv `keepaspect=no` / `.resize` / `BoxFit.fill`). Every mode restores
  `keepaspect` explicitly, because the modes are cycled and leaving Stretch must undo it.
  **The cycle is shared, not per-surface** (`player/aspect_mode.dart` — `kAspectModes`, pinned by
  `test/aspect_mode_test.dart`; it used to be private to `_PlayerScreenState`, so Kotlin and Swift
  were pinned and Dart was not). **The default is the container's shape, not the app's taste:**
  `defaultAspectModeIndex({container})` picks **Fill on a television** — a fixed 16:9 panel that
  never rotates and usually matches the content, where Fill and Fit are indistinguishable and
  differ only on 4:3 material — **Fit on a desktop**, whose window is whatever shape it was dragged
  to, so Fill would crop continuously and by an amount that changes as it is resized, and on a
  **handset/tablet whatever the window's own shape asks for**. That last one is the correction: a
  phone *rotates*, nothing pins the player to landscape, and in portrait Fill opened on a vertical
  sliver of the middle of the frame. The window's aspect is tested against `kFillMinContainerAspect`
  (4:3 — the narrowest shape TV material was authored for; above it Fill trims, below it Fill
  discards), so landscape still opens Fill and portrait and near-square foldables open Fit. The
  container is read from `PlatformDispatcher`'s view, **not a `MediaQuery`**, because the player
  resolves its mode in a `late` field initialiser that runs before the first build; an unreadable
  window **fails to Fit**, which shows every pixel. A stored choice still wins over all of it.
  Kotlin's and Swift's `Fill` initial values are the **seedless fallback**, not a second copy of
  this rule — every native open carries `aspect` on its payload — and are kept equal to each other
  so the two native surfaces can't disagree when neither was told. It keys off
  `isTelevision`/`Platform`/the window, **never off which rendering surface is in use**: on Windows
  the native and embedded surfaces are chosen purely by HDR, so keying off the surface would frame
  the same channel differently depending on its dynamic range. **The choice persists**, per source, in
  `settings['aspectMode']` (`SourceConfig.aspectModeLabel`, saved by
  `channel_list_screen._persistAspectMode` against the *owning* config, so a cross-source favorite
  stores against its own provider) — a broad key, not a secret, riding the existing blob. It
  round-trips through the native players too (`EXTRA_ASPECT` in, `RESULT_ASPECT` out on Android),
  so a change made in the native overlay persists exactly like one made on the Flutter side, and a
  label this build doesn't know is dropped rather than stored. The Windows native surface's
  initial `panscan`/`keepaspect`/`video-aspect-override` are **derived from the resolved index**,
  not hardcoded — they are halves of one statement, and the chip previously said "Fill" while
  the embedded surfaces rendered letterboxed; all three because a restored index can be `16:9` or
  `4:3`, which only the override expresses. `RESULT_ASPECT` comes back for **VOD too**, unlike the
  favorite beside it. The
  **embedded** surface is framed by Flutter (`Video(fit:)`), not by the mpv properties, so
  `AspectMode` carries both — the two surfaces swap on one machine on HDR alone, and framing must
  not change with a stream's dynamic range. iOS offers the three that map onto `videoGravity`
  exactly; 16:9/4:3 would need a hand-computed layer transform (docs/ios.md). Android's player
  theme sets `windowLayoutInDisplayCutoutMode=shortEdges` so video reaches into the notch — safe
  only because the Compose overlay insets itself with `safeDrawingPadding()`.
- **Live zap (PgDn/PgUp) swaps channels inside the fullscreen player on the same engine.**
  **Page Down advances and Page Up steps back, deliberately *against* `CHANNEL_UP`/`CHANNEL_DOWN`**
  (which keep their own direction — so the app has two keys meaning "next" and two meaning
  "previous", on purpose). The *commands* are the authority on meaning and are unchanged:
  `zap:up`/`channelUp` is the next channel (`_index + 1` — the next row *down* the launch list) and
  `zap:down`/`channelDown` the previous one, both wrapping. Only the **key→command** mapping was
  swapped, identically on all four surfaces (`player_screen.dart`'s `CallbackShortcuts`,
  Kotlin's `ZapKeyPolicy`, C++ `zap_key_policy.h`, Lua `zap_key_command`): `pageDown`/`PGDWN`/
  `VK_NEXT`/`KEYCODE_PAGE_DOWN` → `zap:up`, and `pageUp`/`PGUP`/`VK_PRIOR`/`KEYCODE_PAGE_UP` →
  `zap:down`. The reason is the remote's own idiom — Page Down is "step forward", the scrollbar
  gesture — and on a desktop keyboard the page pair is the *only* stand-in for a remote's channel
  keys, where "up" has no channel meaning to preserve. The arrows are untouched, and still differ
  between states: closed they zap, open (quick list) they become literal `zap:move:∓1` moves. The
  quick list's page keys inherit the new direction through the same commands, so Page Down now
  moves its highlight **down** — before the swap it moved against the way the key reads. Don't
  "fix" one surface's pair without the other three; the frozen command vocabulary is unchanged, so
  the direction lives in exactly one place per surface and must agree across all of them.
  `PlayerScreen.onZapChannel` is a host callback (`channel_list_screen._resolveZapTarget`) over the
  currently-visible list; the pure cursor is `liveZapIndex` (wrap at both ends, pinned by
  `test/live_zap_test.dart`). The target is applied by swapping the route's `_current*` mirrors and
  reopening the same `_player` — resolve-through-owning-repo, EPG through the pair-keyed path, and
  the favorite closure routed to the owner, because a zap can cross sources from the cross-source
  Favorites view. It is gated off `_separateEngineOwnsPlayback` exactly like every other Dart-side
  control (Linux native mpv window, Android/iOS native players own their input; **Windows' GDI
  overlay is not gated** — it forwards unclaimed keys back to Flutter, so the key works on the
  Windows-native surface too). When the player route adopted the shared preview engine and the user
  zapped, the pop re-seats the preview's **identity only** (`LivePreviewController.repointAdopted`:
  channel/stream/owning-repo/buffer-preset/EOF-restart bookkeeping, never an engine restart — a
  restart would double-connect a single-connection portal and re-apply the preview's mute). It takes
  `(Channel, StreamInfo)`, not a host-built `LiveZapTarget` — the host-side zap target type and its
  resolve/reopen path are **gone**; the controller owns the list, the cursor and the resolve. Its
  caller is still outstanding after that removal (docs/player.md "Live zapping" → Ownership). The
  buffering preset and aspect choice stay session-level across a zap. docs/player.md "Live zap".
- **Random zapping (Ctrl+R) and the auto-switch countdown are two session-scoped zapping modes.**
  The countdown (`lib/player/auto_switch.dart`, its own `ChangeNotifier` so its per-second tick never
  holds the zap banner up) walks the range on each source's `ChannelDwell` and advances through
  `channelUp`. Random (`LiveZapController.random`, toggled by Ctrl+R, persisted in
  `AppSettingsStore.randomZapping`) makes `channelUp`/`channelDown` pick a random index that is never
  the one under the cursor — inherited by the countdown's `channelUp` funnel, so an auto-walk also
  jumps randomly. The shuffle marker is `ZapBannerState.random`, drawn beside the countdown chip
  (which renders when the countdown is on **or** random is on, so the mode stays answerable with the
  chrome gone); `onRandomChanged` persists it back from the channel list. docs/player.md
  "Live zapping" → "Auto-switch countdown + random zapping". The countdown **holds (freezes), never
  reselects, while the window is hidden to the tray** (`AutoSwitchHold.silenced`, driven off the
  process-wide `silenceRequest`): the F12/close-to-tray hide pauses playback and swallows every
  input, so switching channels on is reconnects into a window nobody can see; restore un-freezes the
  same countdown rather than restarting it. Pinned by the `silenced` group in
  `test/auto_switch_test.dart` and the tray-hide test in `test/live_zap_controller_test.dart`.
- **A typed number in the fullscreen player is a zap, not a second input system.** `PlayerScreen`
  owns **no** `ChannelNumberEntry`: it reads the session's `LiveZapController.numberEntry` and draws
  the shared `ChannelNumberChip`, so a digit moves the same cursor PgDn/PgUp move, in the same range,
  through the same settle and the same resolve. The search space is the **zap range**
  (`digitMatch` over the cached `_rangeChannels`), not a host-passed catalog — the player cannot
  enumerate channels, so a "catalog" was the launch range in disguise. A miss is the **chip's**
  business: it reads `No Data Found` while buffering, and a commit on no match clears the entry and
  changes nothing — no resolve, no cursor move, and deliberately **no** `No channel N` banner, which
  would report a channel change that never happened (the banner slot is the zap cursor's `message`).
  A full-length number commits on the keystroke via the shared
  `kChannelNumberFullLengthCommitDelay`, and **while the quick list is open a digit moves the cursor
  without playing** — the list claims the digits the way it claims the arrows.
  `LiveZapController.playEntry(ZapEntry)` is the host activation path: inside the range it moves the
  cursor and plays, and its future **completes only once that channel is on screen**
  (`_moveTo(…, immediate: true)` returns the settle for that caller); outside the range it stashes
  `_hostTarget` for the next settle, which any cursor move supersedes. The entry is gated off
  `_separateEngineOwnsPlayback` exactly like a zap, except the chip's `isActive` is read *inside*
  its `ListenableBuilder` — an `if` on the entry's state outside the builder is a rebuild that a
  keystroke never causes. docs/player.md "Typed channel numbers".
- **Mute/volume is a device-wide `PlaybackAudioSession`** (top-level in `player_screen.dart`):
  `applied` is `0` while muted else `volume` (0–100), re-applied at every open/reopen (embedded,
  preview-adopted, zap, iOS mpv fallback), and mirrored back from the `volume` stream listener and
  the Android Activity's `RESULT_VOLUME` close relay (`EXTRA_VOLUME` carries it in). A zero records
  mute, a non-zero a level + unmute; the app's own unmute restores the remembered level rather than
  forcing `100`. Load-bearing broadcast subtlety: media_kit volume is **not replayed to late
  subscribers**, so the
  by-design-muted preview engine (muted before the listener attaches) can't poison the session with
  a mute the user never made. Every mute toggle — the M key (`_toggleMute`), the native GDI overlay's
  mute button and volume slider — **`record()`s into the session explicitly, never by reading the
  engine's raw `state.volume`**: mpv's volume event can lag or never arrive on the native surfaces,
  so a toggle against that stale read re-mutes instead of restoring sound, and a slider level that
  never reached the session reverts on the next zap; `apply()` never flips the session's own muted
  flag (it relies on the volume stream), so unmute clears it with its own `record()` first.
  docs/player.md "Playback audio is a device-wide session".
- **Live auto-reconnect reloads the source** (capped backoff, "Reconnecting…" indicator); VOD
  keeps the manual error/Retry overlay. **A stall is three shapes on Android, not two:** buffering,
  ended, and **playing-but-not-rendering** — `isBuffering`/`ended` are the engine's own *claims*,
  and a decoder re-instantiated across the preview→fullscreen surface swap sits in `STATE_READY`
  reporting `isPlaying` with nothing on screen, so every flag read healthy and the freeze was
  permanent *and* unlogged. `FrameLivenessWatch` (pure, in `ReconnectPolicy.kt`) samples
  `PlaybackEngine.renderedFrameCount` on the existing 500 ms tick; `-1` (mpv, audio-only channels),
  any non-healthy state, **a decoder whose `droppedBufferCount` is climbing *inside the handoff
  window*** (dropping frames means decoding them — alive but behind, and the rebuild that window
  arms cannot make a decoder faster; **outside** it, dropping every frame is a frozen picture that
  a reload genuinely fixes, so it must still escalate), and **a counter never seen to advance** are
  all **inert**, never a stall —
  that last one because a counter that never moved can't be told apart from a decode path that
  doesn't report one, and a stream rendering *nothing* is a buffering stall the older watchdog
  already owns. **The one exception is the adopted handoff, where the proof already exists:** the
  Activity calls `armHandoff(now, renderedFrameCount)` when it adopts, because those frames were
  drawn by that same renderer moments ago — without it, a handoff that freezes the decoder *before
  its first frame* stays inert forever (measured: 11.2 s of black ending in the user pressing Back).
  **Inside the handoff window there are two clocks:** `HANDOFF_NO_FRAME_STALL_MS` (3 s) until the
  claimed surface draws a frame of its own, and `HANDOFF_POST_FRAME_STALL_MS` (1 s) once it has,
  because a live stream that drew a frame a second ago and claims to be playing unbuffered has
  drawn twenty-five more. The ticker drops to `HANDOFF_POLL_MS` (125 ms) while `inHandoffWindow`
  so 1 s is eight samples, not one gap. **Both clocks are deliberately generous, because the two
  errors are not symmetric.** They were 1.5 s / 500 ms, sized from a single healthy claim that drew
  in 251 ms — and an Amlogic set-top box then fired a *spurious* rebuild on two consecutive opens
  of the same 1080p channel: one at 1576 ms against a first frame that legitimately landed at
  `sinceClaimMs=1830` (first-frame latency after an output-surface switch is a wait for the next
  IDR — a whole GOP on broadcast MPEG-TS), one at 502 ms against `dropped=0 skipped=0 toKeyframe=0`,
  a decoder in no distress at all. Each false rebuild costs another codec release, another IDR wait
  and a dropped-frame catch-up against a still-running audio clock — i.e. it *is* the "black screen
  going fullscreen, then the picture runs behind the sound" report. A false **negative** costs only
  latency: `armHandoff` leaves `sawProgress` set, so the ordinary 6 s `NO_FRAME_STALL_MS` clock
  still catches the freeze once the window closes. Nothing goes undetected — it is decided later.
  Keep `HANDOFF_WINDOW_MS` clear of both clocks summed, or the window closes before its own
  recovery can run (`ReconnectPolicyTest` asserts it).
  **The frame counter must be read through `ExoPlayerEngine.videoCounters()`**, which calls
  `DecoderCounters.ensureUpdated()` — the fields are plain `int`s written on the playback thread and
  the entire stall decision is "this number did not change between polls", so without that barrier a
  stale read is indistinguishable from a wedged decoder. Never read `player.videoDecoderCounters`
  directly. **"Has drawn" comes from the renderer
  (`onClaimedSurfaceFirstFrame` → `markHandoffFirstFrame(now)`), never from the frame counter** — the
  counter is surface-agnostic and the claim is deferred, so preview frames would trip the short
  clock on a healthy handoff and rebuild (then reload) a working decoder. `markHandoffFirstFrame`
  also restarts the progress clock at that frame, because the post-frame clock means "drew, then
  stopped" and must be measured from the frame rather than from the last counter movement (which
  during a deferred claim is preview frames on the old texture).
  `attachOwnSurface`'s `playerView.player = null; … = player` is **not** a spare output transition
  and must not be replaced with a direct `setVideoSurfaceView`: `attachPreviewTexture` already
  nulled it, so the first line no-ops — and dropping the second leaves PlayerView player-less with
  its shutter closed over a rendering decoder (permanent black), plus no aspect resize or subtitles.
  Both clocks run for `HANDOFF_WINDOW_MS`
  (5 s) after the claim, and inside that window the **first recovery is a local decoder rebuild, not
  a reload** (`tryHandoffDecoderRebuild` → `PlaybackEngine.rebuildVideoDecoder` → a custom
  `PlayerMessage` making `HdrMediaCodecVideoRenderer` do `releaseCodec()` +
  `maybeInitCodecOrBypass()` — verbatim what media3 does for itself on a device it *knows*
  mishandles `MediaCodec.setOutputSurface`, decided by evidence instead of by a device list this
  chipset isn't on). One attempt, then the ordinary reload: a reload spends a provider round trip,
  the whole buffer and a second connection to replace the one thing that broke, and the evidence
  says only the decoder did (same URL, same surface, minutes of clean playback after).
  The Activity also reports surface-claim
  mode/wait, first-frame latency, stream shape, reconnect `kind=` + frame tallies
  (`rendered/dropped/toKeyframe/skipped/inits`, which separate "throwing frames away to catch up"
  from "stopped emitting"), re-resolve outcome and engine
  swaps into the **exportable** log — everything after `adopted=…` used to be silent, which is why
  a handoff report could arrive looking healthy. Keep that relay credential-free (docs/player.md).
  Four independent watchdogs (Kotlin for Android native;
  Dart for Windows/embedded; Dart-over-IPC for Linux native mpv; Swift for iOS native), sharing one
  timing policy (`reconnectMinGapMs`, mirrored by Kotlin `ReconnectPolicy` and Swift
  `ReconnectPolicy`). **All four now re-resolve before reloading** (Stalker `play_token`s are
  single-use, so retrying the same URL a portal already killed can never reconnect) — Android's
  and iOS's reload each go through a single-flight re-resolve gate shared with their own "Go to
  live", so a reconnect and a manual go-live can't both fire overlapping `create_link` calls.
  iOS's live watchdog is additionally inert before the stream's first frame: a stream that never
  starts hands off to the mpv fallback at 10s (`PlaybackStartBackstop`) rather than reconnecting on
  the usual 8/16/24/30s cadence. A **clean server-side EOF** maps
  to media_kit `completed=true`/`buffering=false` — invisible to the buffering-gated stall poll —
  so live treats `completed` as a drop (`shouldReconnectOnCompleted`; VOD completing stays a
  legitimate end), and the preview auto-restarts its own channel on EOF, capped by the same
  policy (`reconnect_at_eof` must stay out of `kLiveMpvOptions` — it hangs HLS on FFmpeg 8).
  **One engine must never carry two live watchdogs.** The embedded seamless handoff
  (`decision.adoptsEmbeddedPreview`) builds the route with `existingPlayer: _preview.player`, so
  `LivePreviewController.adoptedByFullscreen` is set around the push and makes the preview's EOF
  recovery inert (`previewOwnsEofRecovery`) until the route pops. Without it a single clean EOF
  reopened the player twice *and* re-applied `setVolume(muted ? 0 : 100)` from the preview's
  remembered mute — a hover-started preview came back from a reconnect silent, and a
  single-connection provider saw two overlapping `create_link` calls. Live
  reloads **re-resolve** via
  `PlayerScreen.resolveAgain` when wired (Stalker `play_token`s are single-use — a stale URL can
  never reconnect after a portal-side kill).
- Playback headers go to both `Media(httpHeaders:)` and mpv `user-agent`/`referrer` properties;
  all playback logs go through `_logPlayback` (redacted). mpv's `http-header-fields` is a
  comma-parsed list — never naively join it: Linux sends a native JSON array over IPC, Android
  encodes items with mpv `%n%` raw-length quoting (`MpvOptionEncoding`).
- **mpv's own log is a separate, console-only stream, and FFmpeg's is filtered out of it.**
  media_kit calls `mpv_request_log_messages(ctx, 'warn')` — a *bare* level, i.e. warn-and-above
  for **every** module, including the `ffmpeg` one, so a provider's problems (`mime type is not
  rfc8216 compliant`, `non-existing SPS`, `PES packet size mismatch`, `Packet corrupt`) print in
  bulk. `kMpvLogFilter` pins `msg-level=all=warn,ffmpeg=error` and is applied wherever the other
  mpv options are (`_configureNativePlayer`, `LivePreviewController._createPlayer`). Both halves
  are load-bearing: **`all=warn` is restated** because setting `msg-level` after init *replaces*
  media_kit's request rather than adding to it, and **`ffmpeg=error` and not lower** because
  media_kit consumes error-level messages to populate its `errorController`, which is what
  surfaces a failure to the error/reconnect path — `fatal`/`no` starves recovery. One notch
  deliberately higher than Android's native `ffmpeg=fatal` (`player/MpvController.kt`), since a
  real decode failure prints at error (`Failed setup for format d3d11`, `no frame!`). Logging
  only: it never changes what mpv decodes — `hwdec` is decided separately (the embedded Windows
  surface defaults to `auto-copy`, Linux to `auto-safe` — see docs/player.md "The embedded Windows
  surface asks for `hwdec=auto-copy`"), and a stale
  `hwdec_override.txt` beside the exe silently wins over that default. Pinned by
  `test/mpv_log_filter_test.dart`. Detail: docs/player.md "mpv's own log, and why FFmpeg's is
  filtered out of it".
- **`media_kit_video` is vendored and patched — `packages/media_kit_video`, a `path:` dependency, not
  pub.dev 2.0.1.** Its Windows texture callbacks run **inside the Flutter engine** on the raster
  thread, where a C++ throw is fatal to the process: the engine *does* catch it (it is not an
  unhandled `std::terminate` — that reading was wrong and a dump corrected it), then deliberately
  calls `__fastfail(FAST_FAIL_FATAL_APP_EXIT)`, which surfaces as
  `STATUS_STACK_BUFFER_OVERRUN 0xC0000409` **with no Dart log at all**, despite the name
  implying a buffer overflow. Upstream's `pixel_buffer_textures_.at(texture_id_)` threw
  `std::out_of_range` there whenever a resize or teardown erased the entry while `texture_id_`
  was still live (it was cleared outside the mutex), killing the process with `0xC0000409`.
  Every lookup is now a non-throwing `find()`, the id is cleared under the lock, the `Post`/promise
  paths around teardown can't throw, **and every boundary the engine calls into is wrapped in
  `try`/`catch(...)` — both texture callbacks and `HandleMethodCall`** — because the dump's throwing
  frame could not be attributed to any line of ours (no `.at(` anywhere in the package, so it came
  from a header, and there is no Release PDB to name it). Re-applying this on a version bump is a documented checklist —
  `packages/media_kit_video/VENDORED.md`, every edit marked `// iptvs patch:` in place — and
  **`app.so` cannot witness it**, since no Dart changed: verify the `.text` section of
  `build/windows/x64/runner/Release/media_kit_video_plugin.dll` (a whole-file hash is useless, the PE
  `TimeDateStamp` differs between builds of identical source). Also set the file's mtime after copying a
  new version in: a pub-cache timestamp is older than the object file, MSBuild skips the recompile,
  and the build reports success while shipping the old DLL. Detail: docs/player.md "Windows".

- Both media_kit and the libmpv AAR ship `libmpv.so` — `jniLibs.pickFirsts` must keep the
  libdovi/libplacebo one.
- **Debug-only resource counters must balance.** Every player-lifecycle resource is counted in
  the layer that owns it — Dart `ResourceCounters` (media_kit players, the live watchdog timer,
  channel-owner claims, Linux native mpv IPC sessions), Kotlin `DebugCounters` (Exo/mpv engines, preview views, progress ticker,
  `SharedEngine` slot), C++ `windowsSurfaces`/`windowsOverlays`/`windowsOverlayDibs` (the last is
  the cached overlay back-buffer DIB), Swift (`iosAvPlayers`/`iosPlayerControllers`/
  `iosPipControllers`/`iosTimeObservers`/`iosAudioClients` — `iosTimeObservers` matters because an
  un-removed periodic time observer retains the `AVPlayer` forever) — all release-inert
  (`kDebugMode`/`BuildConfig.DEBUG`/`#ifndef NDEBUG`) and merged by `ResourceCounters.snapshot()`
  via a `debugCounters` method on the existing HDR channel, called on Android/Windows/iOS.
  Counters must return to zero after an
  open/close cycle; `integration_test/player_soak_test.dart` (owner-run on hardware, never CI)
  asserts it over 100 cycles. When adding a lifecycle resource or a new create/dispose path, keep
  the counting balanced. Detail: docs/player.md "Debug resource counters + lifecycle soak".
- **Inbound native channels are token-owned.** `iptvs/native_hdr_player` and
  `iptvs/native_preview` are process-static; handler registration goes through
  `ChannelHandlerOwner` (`lib/player/channel_owner.dart`): claim bumps a monotonic token,
  release clears only if still current, superseded owners' calls are ignored — so an old
  route's dispose can't null a newer route's handler. Cleanup is identical on Android, Windows
  and iOS (Dart-side; natives are owner-agnostic — the iOS plugin reuses the same
  `iptvs/native_hdr_player` channel name Android already registers). Real handlers keep a
  `mounted`/`_disposed` second gate. Pinned by `test/channel_owner_test.dart`.
- **`iosManageAudioSession: false` is set at both `PlayerConfiguration` sites**
  (`lib/player/player_screen.dart`, `lib/screens/live_preview_controller.dart`) — done, not
  pending. The option defaults to `true`, so dropping it at either site silently reintroduces
  mpv's `ao_audiounit` clobbering the process-wide `AVAudioSession` state AVPlayer owns.
  `media_kit` is git-pinned to the commit that adds the option (unreleased upstream — docs/ios.md
  Constraint 1). Both sites construct a `PlayerConfiguration` independently, so keep the line at
  each one when either site's construction changes.
- **iOS `engineFailed` never dead-ends** — the reopen gate is three vetoes (native PiP, native app
  state, Flutter lifecycle), any absence is not a veto, and a deferral that outlasts
  `kIosFallbackSurfaceAfter` surfaces Retry rather than waiting silently. Detail: docs/ios.md
  "What routes to which engine", docs/player.md "iOS".
- **In-player live zapping (channel up/down, previous-channel, digit entry) is Dart-authoritative
  (Phases 1–6 implemented on Android, the Flutter overlay, Windows and Linux; iOS zap input
  pending).** `LiveZapController`
  (`lib/player/live_zap_controller.dart`)
  owns the launch-range list, the cursor and the resolve; every native surface is an **input
  source and a view**, never a second copy of the list — the launch range's ordering rules (the
  category filter, favourites' catalog order, the cross-source Favorites view's per-row
  `SourceConfig`) already live in exactly one place, and re-deriving any of them in Kotlin/C++/Lua
  would be a second place for them to drift into playing provider B's channel through provider A's
  resolve. Every surface speaks **one command vocabulary**, parsed by `parseZapCommand`
  (`zap:up|down|prev|list|close|activate|back|digit:N|move:±N`, `favorite:0|1`) —
  Android's `nativeZap`, Windows' existing `nativeControl`, Linux's existing `iptvs-control`
  property, and the shared Flutter overlay's own key map, all through the same parser. Outbound:
  `zapTo` (the settled channel, carries the locator — **never logged**) and `setZapBanner` (the
  **cursor's** channel, so a held key shows where it's got to; deliberately not routed through the
  2 Hz `setControlState` coalescer, since a banner has to track every press). A cursor move waits
  `kZapSettleDelay` (600 ms) before it resolves and plays — a held key costs one `create_link`, not
  one per channel passed — and the settle is **stop → resolve → play**, because single-connection
  accounts refuse the new stream while the old one holds the slot; a failed zap reverts the cursor
  and re-plays the channel that was on screen. **The surface never changes on a zap** — no
  embedded↔native de-escalation path exists — but the one-shot HDR/PQ escalation is re-armed per
  zap, since a zapped-to channel deserves its own chance at a real HDR surface.
  `PlayerScreen.resolveAgain` now re-resolves the channel **on screen** (`zap.resolveCurrent()`,
  not the route's launch channel), and the reconnect watchdog stands down while `zap.settling` — a
  settling zap deliberately stopped the stream it would otherwise reconnect. Favourite and aspect
  writes (including native `RESULT_FAVORITE`/`RESULT_ASPECT`) apply to the **current** entry's
  *owning* source, which a cross-source zap changes mid-session. A zap never *resumes* the live
  preview on return (`decidePreviewReturn`) — that would show the channel the user navigated away
  from — it **restarts** it (stop, then resolve) on the channel the session **ended** on, wherever
  an un-zapped return would have brought a preview back. The channel list restores selection to
  that ended channel, and **follows a quick-list re-range into its category** (`_followZapRange`;
  active-source categories only — the cross-source range's per-source sub-ranges are already inside
  the view it launched from), since otherwise the row isn't in the list and selection fell to row 0.
  "Previous channel" is a channel **plus the range it was played from**: recalling one the quick
  list re-ranged away from restores that range with it, rather than being a dead key. It also
  **outlives the session**: the ending controller's `ZapRecall` seeds the next one
  (`_zapRecall`), so fullscreen A → Back → fullscreen B recalls A. The launch range is a snapshot at open time, wrapped **lazily**
  (`zapEntriesOf`) so an unfiltered 250k-channel source costs nothing up front: cross-source
  Favorites contribute their own per-row `SourceConfig`; a search falls back to the whole active
  source minus hidden categories (a search result has no meaningful "next channel"); otherwise the
  visible category, in catalog order; the EPG grid hands over the list it is already showing.
  Detail: docs/player.md "Live zapping".

## In-app updates (essentials)

Self-updates from GitHub Releases (`GCHOfficial/iptvs`): shared Dart service
(`update_service.dart`, pure version compare, unit-tested) + keychain prefs (`update_store.dart`)
+ per-platform installer (`update_installer.dart`: Android system installer via FileProvider;
Windows PowerShell swap + `exit(0)`, spawned via `cmd /c start` — `windowsUpdaterLaunch` — not a
bare detached `powershell.exe`, which a GUI parent's exit killed mid-`Wait-Process` before any
work, silently no-opping the update). `update_flow.dart` drives prompt → download →
install; Android persists a verified pending APK, retries it after unknown-source settings, and
offers to resume it after OEM installer/settings detours with repeat cache hash + native
package/signer checks. Dialogs are D-pad-safe (primary action autofocuses; the update dialog traps focus).
Release bodies open with an AI-generated changelog (fail-open Gemini step in release.yml),
rendered by `ReleaseNotesView`. Detail: docs/updates.md.

## Testing notes

- **`flutter test` locally is not the same suite CI runs, and the difference is
  silently reported as "skipped".** `channel_list_focus_test.dart` builds a real preview player, so
  **22 of its 23 tests skip on any machine without libmpv** — which is every Windows dev box. The
  whole Back-ladder and live-focus model therefore runs *only* on CI's Linux runner. A local
  `flutter test` will happily print "All tests passed!" with a hard `assert` failure sitting in
  that suite. Read the `~N` skipped count, not just the pass count, and treat focus/Back-ladder
  changes as unverified until CI says otherwise.
- `test/layout_overflow_test.dart` is the one test that **loads real font assets** (Inter, from
  `android/app/src/main/res/font/`). `flutter_test`'s default font lays every line out at exactly
  `1.0 × fontSize`, so any bug that depends on real line metrics — the whole class of fixed-extent
  row/tile overflows — is invisible to every other test in the suite. Sweep window sizes *and*
  text scales there, and assert `tester.takeException()` is null.
- Mostly pure-logic / persistence unit tests; use `DemoSource` or a small fake `Source` rather
  than hitting the network. Real widget tests exist for `TvTextField`, focus/Back-ladder
  behavior, the EPG grid, and the update dialog — keep them green when touching those areas.
- The data layer is well covered: Stalker series/episode parsing, Xtream mapping & paging, XMLTV,
  redaction, metadata config, source-hint language detection (`widget_test.dart` — mostly logic
  tests despite the name); redaction + DB migrations + repository cache behaviour (`net_test.dart`,
  `persistence_test.dart`).
- Migration coverage: `released_schema_fixtures_test.dart` pins every publicly shipped upgrade
  path (v8–v11 → current: schema parity with fresh install, seeded-data survival, stable second
  open); `persistence_test.dart` keeps the v1→current chain and the v7→8 `external_metadata`
  repair as regression tests. **Known gap:** the v3→7 ALTER/`media_page_state` rebuild branches
  are uncovered — dev-era paths outside the supported claim, worth tests only if they change.
- Kotlin has a small plain-JUnit harness (`android/app/src/test/kotlin/` — `PlayerBackPolicyTest`,
  `ReconnectPolicyTest`, `LiveResolveTest`; run via `./gradlew :app:testDevelopmentDebugUnitTest`)
  for pure logic
  extracted from the native player. `integration_test/player_soak_test.dart` is owner-run on real
  hardware only (see docs/player.md) — plain `flutter test` doesn't collect it.
- The Linux native OSD has its own harness, in Lua: `linux/mpv/overlay_layout_test.lua` stubs the
  three mpv modules `iptvs_overlay.lua` requires, renders a frame per scenario and asserts on the
  emitted ASS events (row order, badge order, the live strip clearing the transport row). Run it with
  `lua linux/mpv/overlay_layout_test.lua` — mpv's dialect is 5.1, and CI runs it plus `luac5.1 -p`.
  Nothing else in the suite executes that script: it only renders on Wayland+HDR. It also covers the
  zap banner (`draw_zap_banner`/`draw_channel_identity_row`) and the key policy
  (`zap_key_command`) and the quick list (`draw_quick_list`, its 40-row slice), exercised through a test-only seam the module exports rather than by
  simulating real mpv key dispatch.
- Credential-shaped test fixtures (`username=u&password=p` in URL literals) trip GitGuardian on
  every PR that adds one — it's a false positive to dismiss in their dashboard, or avoid the
  literal `username=…&password=…` pattern when the parser under test doesn't need it.
