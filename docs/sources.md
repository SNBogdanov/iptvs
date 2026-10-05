# Sources — EPG guides, subscription expiry, stable source identity, the M3U→Xtream upgrade, and Stalker adult genres

Detail for two provider-layer areas whose rules are summarised in CLAUDE.md: how a subscription
expiry is obtained per provider, and how an M3U source that is really an Xtream panel gets
upgraded. Read this before touching `subscriptionExpiry()` on any `Source`, `lib/sources/expiry.dart`,
`lib/sources/m3u_upgrade.dart`, or the expiry cache.

## Multiple EPG guides per source

A source has one guide by default — the provider's own (`xmltv.php` for Xtream, `get_epg_info`
for Stalker, an explicit `epgUrl` or the playlist's `url-tvg` header for M3U). A user can add
more in **Source settings → EPG guides**: extra XMLTV URLs that fill in the channels the guides
above them do not cover.

Storage is `fields['epgUrls']`, newline-separated, holding **only the additional** guides. The
primary keeps its existing key, which is the whole reason for a new one: `epgUrl` is read as a
single URL by every already-published build, and those builds pull this source from the cloud.
Widening it in place would hand them a blob they would fetch as one URL and lose their guide
over. It is a **secret** key (`secret_keys.dart`, and the strip in
`20260823000000_epg_urls_secret.sql`) — a guide URL carries provider credentials as often as a
playlist does.

### Merging is per channel, not a row union

`mergeEpgGuides` (`sources/epg_guides.dart`) consumes the guides in order and lets **the first
guide that carries a channel own it**; later guides are filtered against those claims. Claims
accumulate per guide and are merged in only once that guide is exhausted, so a guide is never
filtered against itself.

Concatenating the guides instead would be wrong, and quietly so. `programmes` rows are keyed by
`(source_id, channel_id)` with no record of which guide wrote them, and `AppDatabase.nowNext`'s
"now" half is a bare `start <= t AND stop > t` scan whose rows are folded into a map by channel
id — **last row wins, arbitrarily**. Two guides covering one channel would therefore make its
now-playing programme nondeterministic, flipping between them across refreshes, and would draw
overlapping cells in the EPG grid.

### Failure policy turns on whether the guide had yielded

A guide that fails **before yielding anything** — refused, 404, unreadable gzip — has written
nothing, so it is logged and skipped and the merge goes on. That matters more than it sounds: the
case that motivates the whole feature is a *provider* guide that is broken or thin, with the
top-up added to replace it. A hard-failing primary would block exactly that.

A guide that fails **mid-feed** rethrows. Completing normally would commit a *truncated* guide as
a whole one: `replaceEpgStream` would drop the previous guide and advance `epg_synced_at`, so a
network drop 80% of the way through a large guide would cost the user the complete one they had,
with no retry for the whole refresh interval. Throwing abandons the whole refresh and keeps the
last good guide.

The *reason* changed once and the rule did not. Batches used to be fed straight into the caller's
open transaction, so a mid-feed failure genuinely could not be taken back. They now go through a
[spool](#the-refresh-runs-behind-the-channel-list) first, so nothing is committed either way — but
a truncated guide is still a truncated guide, and there is no way from inside the merge to tell
how much of one arrived. Rethrowing stays correct; it is now conservative rather than forced.

If **every** guide fails without yielding, the last error is rethrown for the same reason: a
normally-completed empty stream reads as a successful *empty* guide, and clearing the cache over
a transient blip is the outcome to avoid.

### The refresh runs behind the channel list

`LibraryRepository.load` returns as soon as the channels are ready and refreshes the guide
afterwards. Awaiting it put the whole download and parse — 5–10 seconds with a single top-up guide
— between the user and a channel list that was already in hand, on every forced reload.

Backgrounding it was tried once before and reverted within the day, because it deadlocked. The
mechanism is worth stating precisely, because nothing about it is visible from the call site:
`AppDatabase.replaceEpgStream` holds **one write transaction** for the whole ingest (that is its
atomicity contract, and it is right), and the batches it consumed were produced lazily — the first
thing each guide does when the transaction pulls on it is an HTTP download. So the transaction
stayed open across the network, on the single sqflite connection the entire app shares, and
sqflite serialises *everything* on it: not just other writes but channel reads, now/next queries
and favorite toggles too. Awaited, that was hidden behind the spinner the user was already
watching. Unawaited it became a multi-second freeze, and switching source mid-ingest hung outright
— `channel_list_focus_test` sat for ten minutes on sqflite's own
`database has been locked for 0:00:10` warning. The lock also had **no upper bound**: a guide
server that accepts a connection and then stalls held the whole application's database until the
read timeout fired.

Two pieces make it safe, and neither is optional on its own:

* **`ProgrammeSpool` (`lib/data/programme_spool.dart`)** drains the merged guide to a temporary
  file *before* any transaction opens. Fetch, decompress and parse happen with nothing blocked;
  the transaction then spans local inserts only — bounded, deterministic, and with no network
  inside it. Peak memory is one batch, the same bound the streaming parser already works to, so
  this trades transient disk for a lock window rather than for RAM. Frames are length-prefixed
  precisely so a truncated spool throws instead of replaying as a shorter guide, which
  `replaceEpgStream` would commit as a complete one.
* **`EpgIngestCoordinator` (`lib/data/epg_ingest.dart`)**, held on `AppDatabase` because the
  contended resource is *that connection*, keeps one refresh at a time app-wide. Starting one
  cancels its predecessor and **waits for it to actually stop** — cancellation is cooperative, so
  "cancelled" and "no longer touching the database" are different moments and only the second is
  safe to build on. `AppDatabase.close` **awaits** `shutdown()`, and that is not optional: an
  ingest mid-transaction does not stop because the connection closed, so skipping the wait merely
  moves it into `_db.close()`, which has no cancellation and logs nothing. A widget test that ended
  while a guide was still being written hung there for its full ten-minute timeout, with only
  sqflite's `database has been locked for 0:00:10` warning to go on. Waiting costs milliseconds —
  the transaction is local, and the token has already stopped it feeding further batches.

Because the list is now on screen before the guide, two things had to follow it. `AppDatabase`
announces a replaced guide on `epgChanged` (carrying the source id — a background refresh for the
source the user just *left* reaches the same stream, and re-reading for that one would blank the
current source's now/next), which `LiveController` subscribes to; without it the new guide would
sit in the database, unread, until the one-minute poll came round. And `LibraryRepository.load`
decides staleness *before* scheduling rather than inside the refresh, so a load with nothing to do
leaves `pendingEpgRefresh` null — the live status line reads that to append `· updating guide…`,
and an already-fresh guide would otherwise flash the message for a frame on every load.

### Two things the user can now see that they could not before

**The rows are sized from what the source *says*, not only from what has arrived.** A channel row
is 72 px without an EPG line and 112 px with one, and the guide now lands after the list is built —
so a source's very first load would draw short rows and jump. `LiveController.expectsEpg` takes the
source at its word while a refresh is running: Stalker and Xtream always report `supported`, M3U
does when it has an EPG URL, and anything reporting `unknown` keeps the old wait-and-see behaviour
rather than sizing rows tall for a guide that may never come. `_settleEpgRefresh` re-reads now/next
*before* clearing the flag, or the rows would drop to 72 px for the frames between the two and rise
again. `_resyncLiveRowExtent` still re-reveals the selection whenever the extent does change
(docs/tv-navigation.md) — this reduces how often that happens rather than replacing it.

**A guide that fails with nothing behind it says so.** A failed refresh retains the cached guide and
is otherwise silent, which is right — except when there is no cached guide to retain, where "this
source has no EPG" and "every guide URL is broken" look identical and only the second is actionable.
`LibraryRepository.lastEpgRefreshFailed` records the verdict (a *superseded* refresh sets neither —
it is not an outcome), and `LiveController.epgUnavailable` pairs it with an empty guide so the live
status line reads `· guide unavailable`. Deliberately both conditions: a failure standing behind a
cached guide is the retain policy working, not something to alarm anyone about.

### Saving the list forces a refetch

`load` skips the fetch while the cached guide is younger than its max age — right for a
periodic refresh, wrong when the *set of guides* just changed, where it would leave a newly added
guide invisible for hours and reading as a broken feature. So saving calls
`AppDatabase.invalidateEpg`, which clears `epg_synced_at` and deliberately **keeps** the cached
programmes: dropping them would blank every channel's EPG until the refetch lands, and for the
whole retry interval if it fails, where keeping them means the worst case is the guide the user
already had.

The running `Source` still holds the old URL list, so the guides take effect when the source is
next built — the same "applies on next load" contract the catch-up overrides have, and what the
save confirmation says.

### Stalker

The portal's guide comes from `get_epg_info`, not XMLTV, so it joins the merge as a plain feed
wrapping that call; only the top-ups go through `xmltvGuideFeed`. `epgBatched` returns null when
there are no top-ups, keeping a portal-only source on the code path it has always taken.

Two Stalker-specific points. Its channels carry **no `tvg-id`**, so an extra guide reaches them
purely through name matching — on this provider that path is not a fallback, it is the only one.
And third-party downloads use a separate `_downloadGuide`, never `_requestBytes`: the latter is
the portal transport and sends the MAC cookie and the portal Bearer token, which must never reach
an arbitrary user-supplied host. Only the emulated profile's `User-Agent` carries over, since
some guide hosts reject a default one.

### Matching: ids first, then names

`sources/epg_matching.dart`. The historical path is exact — a guide's `<programme channel="…">`
id looked up in a `tvg-id → channel id` map — and it is correct and cheap for a provider's own
guide, where both sides come from the same panel. It contributes close to nothing for a
**third-party** guide, which numbers its channels its own way: almost every id misses and the
extra guide lands empty. So names fill the gap.

**Name matching is for user-added guides only** (`epgNameIndexFor`); a provider's own guide stays
on exact `tvg-id` matching. Its guide and its playlist come from the same panel, so their ids
agree by construction and names would add only guesses — while turning it on there would silently
change the EPG of every existing install on upgrade (a channel that had no guide can acquire one
from a same-normalised-name channel, and since programmes are stored per `channel_id`, one guide
entry claiming several rows multiplies the ingest). It would also put an O(channels) index build
on the main isolate on every EPG refresh for users who added no guide at all, against a
250k-channel baseline. Gated, that cost is paid only by those who opted in.

`XmltvChannelResolver` settles claims over one streaming pass, which is enough because the XMLTV
DTD fixes document order as `(channel*, programme*)`: every `<channel>` declaration is seen
before the first `<programme>`, so the resolver can freeze a *globally* correct mapping on the
first `resolve` call rather than re-reading a multi-hundred-MB guide. Rules, in order:

1. A guide channel whose id is one of our `tvg-id`s claims **every** channel carrying that id,
   outright.
2. A guide channel whose *name* normalises onto one of ours claims it — but only if rule 1 left
   it unclaimed, so a channel the guide already covers properly is never second-guessed.
3. A channel contested by two guide channels goes to **neither**. Two names that normalise alike
   are genuinely ambiguous, and picking by document order would be a coin flip rendered as fact.

Matching is **exact after normalisation, never fuzzy**. Edit-distance matching would paint a
channel with another channel's schedule, and wrong programme data is worse than none: the row
looks authoritative, the catch-up window is computed from it, and nothing about it reads as a
guess.

Normalisation (`normalizeChannelName`) folds case, punctuation and diacritics — including the
Romanian comma-below vs cedilla forms of `ș`/`ț`, which are distinct code points a playlist and
a guide routinely disagree on, and Cyrillic `ё`/`е` — drops stream-quality tokens as whole words
(`hd`, `fhd`, `4k`, `backup`, …, so `HDNet` and `Sharjah` survive intact), and strips a leading
`RO:`/`UK |` country tag, which is ubiquitous in playlists and absent from every real guide.
Parenthesised content is deliberately **kept**: `HBO (RO)` and `HBO (HU)` must not collapse into
one key.

**Tokenisation is script-agnostic: every script's letters and digits are token characters, and only
whitespace and punctuation split.** It used to be `[^a-z0-9]`, which counts every non-Latin letter
as a separator — so a Cyrillic name reduced to the *empty* key and matched nothing. That kills name
matching outright for a Russian portal, and names are the only path for any channel whose ids miss:
on Stalker (no `tvg-id` at all) and on an Xtream Codes panel for every feed the panel gave no
`epg_channel_id` to. The same report is what exposed the single-valued id map above (both feeds on
id `146`), so both fixes shipped together: a third-party link the user specified in the source's EPG
settings, one guide entry declaring `Первый канал UHD` and `Первый канал FHD` under `146`, and one
of the two rows showing a programme. Pinned by `epg_matching_test.dart` ("keeps letters of every
script, not just Latin") and the non-Latin fan-out case in `xmltv_name_matching_test.dart`.

**One guide channel can claim several of ours — and that is not a fallback, it is the normal case.**
A channel is one channel to the guide and often several rows to us: a panel gives every feed of it
the same `epg_channel_id` (Xtream Codes: both the UHD and the FHD row of `Первый канал` carry
`146`, because to the panel they are one channel with one schedule), and a playlist does the same
thing with HD/SD entries. So **both** indexes are many-valued — `tvg-id → every channel carrying
it`, and name → every channel normalising to it — and one guide entry writes its programme to each
of them. `tvgIdToChannelId` used to be `tvg-id → one channel` with `map[tvg] = c.id`, i.e. *last
row wins*: the feeds collided, the last one in catalogue order took the whole guide, and every
other feed was permanently bare with no second path to it — on the provider's own guide, which is
id-only, there is no second path at all. The report was exactly that pair, one guide entry, both
rows on `146`, and one of the two rows showing a programme.

The cap is `kMaxMatchGroup` (8) on both indexes, and it bounds the same thing on each: programmes
are stored per `channel_id`, so one guide entry claiming N of ours writes N copies of its schedule,
and on a ~10^6-programme guide an uncapped fan-out is a multi-million-row ingest. Beyond the cap
the key matches nothing: for a name that is a generic label rather than a channel identity, and for
an id it is a panel that has lost the plot. The whole group is dropped rather than the first few
kept — there is no principled way to pick the winners, and rule 3 already says an ambiguous match
goes to nobody. On the name path the cap can only ever limit what name matching *adds*; on the id
path it can in principle take a guide away, which is the deliberate trade for never silently
dropping a feed the panel itself called the same channel. Pinned by `epg_matching_test.dart`
("`buildTvgIdIndex`: one id claims every feed carrying it") and the three Xtream feed-list cases in
`xmltv_name_matching_test.dart` — including the panel's own guide lighting both feeds with name
matching off.

## Subscription expiry

`Source.subscriptionExpiry()` feeds the sources screen's badge as an explicit
dated/unlimited/unknown value. **Never collapse unlimited into unknown** — they are different
answers and the user has a right to the first one. Shared parsing is in `expiry.dart`.

### Stalker: authorize before asking

`subscriptionExpiry()` calls `connect()` — handshake **plus `get_profile`** — before
`account_info`/`get_main_info`, then falls back to the profile `js` that call already fetched
(`_lastProfileJs`, reused rather than re-requested).

The ordering is the whole fix. A MAG session is not established by the handshake: `get_profile` is
what binds the token to the STB, and the real set-top always sends it first. `_call` only
guarantees `_resolveEndpoint` (handshake + token), so asking `account_info` straight out of a
freshly built source made it the first action on an unauthorized session, which portals answer
with an empty `js` or an error. And that was not a rare path — the sources screen builds a *fresh*
source per card, so it was the **only** path the badge ever took. Hence "unknown on every portal"
rather than on some of them.

### Field and format coverage

MAG portals put the end date in odd places, and in odd formats. Both halves matter:

- **Named fields**, in preference order: `end_date`, `expire_billing_date`,
  `subscription_expire`, `exp_date`, `expire_date`, `tariff_expired_date`, `end_date_timestamp`.
- **Stuffed fields** — free-form boxes panels render the date through: `phone` (the classic),
  `fname`, `ls`. Deliberately *not* `comment`/`description`: a date in a note is more likely about
  something else, and a wrong expiry is worse than none.
- **Nested containers**: the root map, then `tariff`, `account_info`, `info`, `data`. Root beats
  nested; named beats stuffed.
- **Every candidate field gets the lenient text extraction**, not just `phone`. Panels return
  `end_date` as `October 20, 2026` / `20.10.2026` / `expires 2026-10-20` at least as often as
  something `DateTime.parse` accepts, and only `phone` used to be read that way — so an ordinary
  `end_date` sitting in plain sight read as no answer at all.
- **Month-name dates are supported** (`October 20, 2026`, `Oct 20 2026`, `20 October 2026`),
  English only. That is PHP's default formatting, i.e. what a stock Ministra/stalker_portal skin
  emits — the single most common shape the parser used to reject outright. English only is
  deliberate: matching short words against twelve month names in a dozen languages is far more
  ways to read a date out of something that isn't one.

### The far-future sentinel, and the trap in it

A date beyond year 2100 (`9999-12-31`, `2999-01-01`) is a panel spelling "unlimited" as a date, and
is reported as **unlimited**.

**Only when written as a date, never as a bare number.** These are the same fields panels stuff a
phone number into, and a phone number read as Unix seconds lands centuries out —
`40712345678` → year 3260 — so the rule would have reported a lifetime subscription for a
customer's phone number. An out-of-range *timestamp* is garbage and stays unknown. The pre-existing
test missed this because it asserted on the parsed **date**, and unlimited carries none; the
regression test asserts on the kind.

### Diagnosing an unknown answer

When Stalker still ends up unknown, the payload is logged as key **names** plus
`expiryValueShape` masks (`dddd-dd-dd`, `aaaaaaa dd, dddd`) — never values. Key names are schema
and safe in full; values are not, because `phone`/`fname`/`ls` are customer PII and a panel that
stuffs the expiry into them is stuffing it next to the account identity. A shape answers "which
field, what format" and carries no content, which is the entire question needed to fix the next
portal that misses.

## The expiry cache

`lib/data/expiry_cache.dart`, keychain-backed like `UpdateStore`. Every sources-screen card builds
its own `Source` and asks the provider, so uncached the screen is a full portal round trip **per
card, per visit** — and for Stalker that is now handshake + `get_profile` + `get_main_info`.

**Deliberately not `SourceConfig.settings`.** That blob rides the source row into the cloud
(`push_sources`), so caching there would push a timestamp rewrite on every refresh, advance
`profiles.updated_at` through `touch_profile_snapshot_revision` on every paired device, and hand
other devices a cached answer for a portal they may not reach. An expiry reading is device-local,
disposable and derived — none of which is what `settings` is for.

**Invalidation is a fingerprint, not just the id.** `expiryConfigFingerprint` hashes `kind` +
`fields`, so an edited credential invalidates the entry while a rename doesn't. A hash rather than
the fields themselves: there is no reason for a second copy of a password to exist just to answer
"did this change?".

**Three staleness rules** (`isStale`):

| state | trusted for | why |
| --- | --- | --- |
| dated / unlimited | 12 h | a subscription end date changes on renewal and at no other time |
| unknown | 30 min | as often a briefly unreachable portal as a real absence; pinning a failure for half a day makes a recovered portal look permanently broken |
| within 48 h of the date (or past it) | not at all | the renewal window — the one time the user is watching this badge expecting it to move |

That last rule is why there is no manual refresh control: the case that would need one is the case
that never caches.

**A cache that can hide a diagnostic has to say when it is doing so.** Serving from cache is
logged (`expiry from cache source=… kind=… ageMin=…`), and saving a source forces a re-check
(`canServeCachedExpiry(force:)`, from `didUpdateWidget`). Both exist because of a real
investigation: a source whose lookup once returned unknown served that from cache on every later
visit *without calling the provider*, so the provider's own "here is why" logging never ran either
— producing an exported log with a stubbornly unknown badge and, correctly but uselessly, nothing
at all about it. Nothing else could dislodge it, since an edit that leaves the credentials alone
keeps the same fingerprint.

## Stable source identity, and the migration that gets you there

A source's cache namespace is `SourceConfig.id`, a stable uuid, not a key derived from the
credentials — so rotating a password, or the host string being normalized differently, cannot orphan
a 250k-channel cache. Installs made before that change wrote their rows under
`SourceConfig.legacyCacheId` (for Xtream, `xtream:<host>|<username>`), and
`migrateAllSourceIdentities` moves that namespace forward.

It runs from `main()` **before `runApp`**, and the Windows window is shown on the *first Dart frame*
(`windows/runner/flutter_window.cpp`, `SetNextFrameCallback`). So anything this migration throws
produces no window at all — the process starts, does nothing visible, and never reaches a frame that
could report why. Two rules keep that from happening, and both are load-bearing:

- **The destination namespace is not guaranteed empty, and the stable one wins.** The same provider
  can exist under a legacy key *and* a stable id — a re-added source, or an earlier run that
  migrated some tables and not others — leaving both holding the same category and channel ids. A
  plain `UPDATE ... SET source_id` has nowhere to put the duplicate and violates the table's
  `(source_id, id)` primary key; that is exactly what bricked one install with
  `UNIQUE constraint failed: categories.source_id, categories.id`. `migrateSourceNamespace` now
  deletes a legacy row whose key already exists under the destination — it duplicates a row that is
  already in use — and still moves every legacy row that does not collide. The key columns are read
  from `PRAGMA table_info` at run time rather than hardcoded, because they differ per table
  (`(source_id, id)`, `(source_id, kind, item_id)`, `(source_id, kind, parent_id, category_id)`, …)
  and a drifted key would silently stop protecting the one path that must not throw. `programmes` has
  no primary key at all, so it is never probed. The same rule applies to the `sources` row itself,
  whose primary key *is* `id`.
- **A repair is never a reason to refuse to start.** `migrateAllSourceIdentities` logs (redacted) and
  skips a source it cannot migrate rather than aborting the loop, and `main()` wraps the call in a
  last-resort `try`/`catch` — the cache it repairs is rebuilt from the provider anyway, so failing
  to repair it costs a fetch, not a launch. Do not move this call after `runApp` and do not let it
  throw out of `main()`.

`favorites_outbox` (schema v14) was missing from the moved-table list and now moves with everything
else: it is exactly the table the cloud delta push reads, so a source whose id migrated would
otherwise have had its pending favorite changes sent under an id the profile no longer has. Pinned by
the `stable identity migration` group in `test/persistence_test.dart`.

## M3U → Xtream upgrade

A very large share of M3U sources are an Xtream panel's `get.php` link. As a flat playlist such a
source works — live channels play — but it is strictly worse than the Xtream config the same
credentials support: **no Movies, no Series, no subscription expiry**, because none of that is in a
playlist. The panel would answer all three on request.

`upgradeM3uToXtream` (`lib/sources/m3u_upgrade.dart`) is the one implementation, with a pure
`couldBeXtreamPanel` pre-check and a `debugApi` seam so the whole path is testable without HTTP.

**It fails closed.** The panel must actually authenticate (`player_api.php`); anything else —
refused, unreachable, not a panel — leaves the source exactly as it was. This rewrites a saved
source, so a guess is not good enough.

**It keeps the same source id**, so the SQLite cache, favorites and playback positions carry over.
That is what makes it an upgrade rather than a new source that happens to look the same.

### Where it runs

- **Edit-save** (`EditSourceScreen`) — the original path.
- **Load time** (`HomeShell._loadActive`), `unawaited` and after the UI is up. It ends in a network
  round trip, and putting that on the boot path would let a slow or dead panel hold the app on a
  spinner. It exists because the save-only path meant a source added once and never touched again
  stayed a flat playlist forever. Terminates by construction: the saved config is `xtream`, so
  `couldBeXtreamPanel` rejects it on the second pass. Costs one small background request per app
  start, and nothing at all for a plain playlist.
- **`source_settings_screen`'s "Upgrade to Xtream" tile** — shown when `couldBeXtreamPanel`, probes
  on tap (never on screen open), converts only on a real authentication, then prompts to push.

The load-time path costs more than one request when the source is a **large playlist**, and it is
worth knowing why. On success it saves and re-runs `_loadActive`, which builds a new
`LibraryRepository`; `ChannelListScreen.didUpdateWidget` then disposes the old controllers, which
cancels the in-flight load's `LoadToken`. A 66 MB playlist on a low-end TV box takes ~55 s to fetch
and parse, so the probe reliably kills the very first load of exactly the source it is trying to
improve. That is survivable only because a superseded load now **seeds an empty cache** rather than
discarding its catalog (CLAUDE.md, "Async publishes are generation-guarded"); before that, such a
source could never obtain a first cache at all.

The same-id upgrade is also why a superseded load may never *overwrite* a populated cache. The
converted config deliberately keeps the source id, so an M3U load still in flight can outlive the
conversion — and writing playlist-shaped rows under a source that is now Xtream leaves
`XtreamSource.resolve` falling back to `channel.id` for the stream id, i.e. every channel silently
unplayable with a fresh `synced_at` and no age check to heal it.

### Cloud-managed sources are skipped at load time

`pullSources` replaces every cloud-managed source wholesale from its cloud row (`store.setAll`),
and a pull runs on **profile switch** as well as on demand. Converting one on this device would be
undone by the next pull and re-attempted on the load after it: the source flipping kind
indefinitely, one panel probe plus one `_loadActive` (repository rebuild + library reload) per
cycle — and the change would never reach the cloud anyway, because pushing is a deliberate user
action this must not take on the user's behalf.

So the load-time path checks `CloudSync.managedSourceIds` and **fails closed to skip**: the cost of
skipping is a source that stays M3U until the user asks; the cost of guessing wrong is that loop.
The settings-screen tile is how a managed source gets there, explicitly, followed by a push.

**"Until the user asks" is doing more work than it looks, and the panel now says so.** For a source
managed from the panel, nothing on the device converts it on its own, so the panel's own suggestion
is realistically the only prompt the user ever sees. It shipped as a muted `.hint` with a ghost
button and read as decoration; a field report is what showed the cost. A panel-managed playlist
pointed at a provider that answered `HTTP 884` on `get.php` while its `player_api.php`
authenticated normally seconds earlier stayed an M3U indefinitely — the one conversion that would
have routed around the refused endpoint was the one nothing was allowed to perform. It is now a
`.callout` (accent-tinted box, real heading, `primary` button) that states both the gain and the
fact that devices will not do this for a managed source. The panel still only ever *suggests* — it
cannot verify a provider, for the reasons in "Why the web panel suggests and the app proves" — so the
caveat about setting Kind back to `m3u` stays beside it.

The push side needs nothing: `sources.kind` is a plain `check (kind in (...))` column with no
immutability trigger, `splitFields` sends `host` broad and `username`/`password` as secrets, and
the stale `playlistUrl` secret is preserved server-side (absent secret → preserve) but inert, since
`build()` switches on kind.

### Why the web panel suggests and the app proves

**Only the device can verify; only the panel can make it stick for every device.**

The panel detects the same shape (`xtreamCredentialsFromPlaylistUrl` in `panel/src/validate.js`,
mirroring the Dart `xtreamCredentialsFromUrl`) and offers "Switch to Xtream" with the fields
prefilled — but it must **never** convert on its own, because it cannot verify what it detects:

- The panel is served over HTTPS, so an `http://` provider URL is blocked as **mixed content**
  before CORS is even consulted. Most IPTV panels are http-only.
- Cross-origin `fetch` without `Access-Control-Allow-Origin` can't be read, and IPTV panels don't
  send it.
- `mode: 'no-cors'` issues the request but returns an **opaque** response — status reported as 0,
  body and headers unreadable — so a 200 with `auth:1`, a 404 and a 500 are indistinguishable. It
  rejects only on a network-level failure. "Something answered" is already true of a get.php link
  that works fine as a playlist, so it answers nothing.

Panel-side detection is therefore a guess about a URL *shape*, and some resellers proxy `get.php`
while serving no `player_api.php` at all — converting one of those blind turns a working source
into a broken one. Hence: the panel asks, the app proves.

Server-side verification (a Supabase Edge Function, which has no CORS problem) was scoped and
**deferred**. Two reasons, the second being the strong one: outbound HTTP to a user-supplied URL is
an SSRF surface whose sharp edge is DNS rebinding — Deno's `fetch` gives no way to pin a connection
to a validated IP — and, more fundamentally, it means sending provider credentials to the backend
in cleartext, which directly contradicts what E2EE exists to guarantee for a profile that has it
enabled. If it is ever built it needs its own threat model and an explicit decision for E2EE
profiles, not a rider on a source-handling change.

## Stalker adult ("censored") genres

Ministra marks adult genres `censored: 1` in `get_genres`, and many portals
leave those genres' channels **out of `get_all_channels`** — a MAG box keeps
them behind its parental PIN and fetches them per genre. The same portals
answer `get_ordered_list` for that genre normally. Reading `get_all_channels`
alone therefore produced a source whose adult categories were silently empty
(a user report: "why don't the adult channels show on my Stalker source?").

`StalkerSource._withCensoredGenres` runs after a successful `get_all_channels`
and fetches, through `get_ordered_list`, exactly the genres that are adult
**and** came back with no channels. A genre is adult when the portal flags it
(`censored` as `1`/`"1"`/`true`) or when its title says so
(`isCensoredStalkerGenre`: adult/xxx/porn/erotic/18+) — portals that never set
the flag still name the genre. Properties worth keeping:

- **No cost when the portal already included them**: a populated genre is never
  re-asked, so a portal that does return its adult channels makes zero extra
  requests.
- **Fails soft**: a refused `get_genres` or `get_ordered_list` keeps the catalog
  already fetched; losing every channel over the adult genres would be worse.
- **Diagnostics** log `censored_genres=N backfilled_channels=M` under
  `parse:stalker`, so an export shows whether the backfill ran and found
  anything.
- The paginated fallback (`_fetchChannelsWithOrderedList`) needs none of this —
  it already walks every genre with `get_ordered_list`.

Hiding them again is the user's call, through the per-source category toggles
in `source_settings_screen` — the app does not filter adult content itself.

Pinned by `test/stalker_censored_genres_test.dart`.

## Xtream: the live stream format, and the panel's own direct link

Two per-source Xtream preferences live in **Source settings → Live stream format**, and they answer
two different questions, which is why they are two tiles rather than one three-state cycle.

**Which container to request** (`settings['streamExtension']`, absent = automatic) is about a URL
the *app* composes. Xtream live streams follow `/live/USER/PASS/STREAM_ID.ext`, and most panels
serve both `.ts` and `.m3u8`, so the automatic case asks the panel what it has: a per-channel
`container_extension` from `get_live_streams` (`xtreamLiveExtensionFor`, mapped camelCase into
`extra['containerExtension']` by `mapLiveChannels`), else the platform default in
`streamExtension` — `ts` everywhere, `m3u8` on iOS so live routes to AVPlayer rather than the
permanently-SDR mpv fallback (docs/ios.md "The `streamExtension` lever"). An explicit `ts`/`m3u8`
outranks the panel, because a panel that doesn't serve the chosen container answers 404, which is a
dead channel rather than a degraded one, and Dart's `engineFailed` fallback reopens the *same* URL
on the other engine. A value outside `{ts, m3u8}` — including a case or whitespace variant, which
the tile never writes but a hand-edited config can carry — is *not* a choice, so the panel decides.
`validatedXtreamStreamExtension` is the single reader both the tile and the resolver go through,
because they once disagreed on exactly that: `'TS'` read as unset in the UI and as a choice in the
URL.

**Whether to use the panel's own address** (`settings['useDirectUrl']`, off unless exactly `true`)
is about a URL the *panel* composed. `get_live_streams` often carries `direct_source` (and
sometimes `stream_url`) pointing at whatever CDN the reseller chose; `directUrlFor` uses it verbatim
when it is a plain absolute URL, `direct_source` first, then `stream_url`. It is deliberately
off by default: a direct URL is whatever the reseller baked in **at catalog-fetch time**, which on
many panels is a rotating expiring token, and the app re-requests the composed `/live/...` URL at
play time — so the default survives a cache that is hours old, and the direct one can 403 minutes
after the catalog load with nothing to re-resolve against. Some users need it anyway: a provider
that only serves the CDN host, or one that refuses the `player_api` path its own direct URL would
have worked on. Two refusals are the point of the shape: a **schemeless or relative** address is
skipped rather than completed against the panel host (inventing a stream the user never asked for is
worse than either answer), and an **explicit `streamExtension` keeps composing the URL**, so a
deliberate `.ts`/`.m3u8` choice is never silently ignored — which makes direct playback exactly the
Automatic case, since a spelled-out address leaves no container to choose. **Catch-up is never
taken direct**: timeshift is a panel-built path with no direct counterpart, and a live address
there is a 404.

Pinned by the `XtreamSource direct source URL` group in `test/xtream_url_test.dart`, beside
`XtreamSource stream extension` for the container half.

## Leaving the sources screen must not re-ingest the catalog

`HomeShell._loadActive` runs on **every** return from the sources screen, the profile picker and the
cloud screen, and it used to build a brand-new `Source` + `LibraryRepository` every time.
`ChannelListScreen.didUpdateWidget` watches the repository by **identity** (`!identical(old.repo,
widget.repo)`) and treats a new one as a new source: it disposes its controllers and re-runs
`_loadLive()` plus both EPG refreshes. So hiding a category and going back cost a full channel load
on a 250k-channel portal - a cold start for an edit that changed no cached row.

Two predicates decide instead, both pure and both unit-tested
(`test/source_config_test.dart`, `test/metadata_config_test.dart`):

- **`SourceConfig.hasSameCatalogInputs`** - the cache is keyed by `id` and its rows are built from
  `kind` + `fields` alone (credentials, playlist URL, `epgUrl`/`epgUrls`). So a *settings-only* edit
  leaves every row correct and the repository is **reused**: `LibraryRepository.source` becomes
  settable so the new settings can be handed to the instance already loaded. Note the EPG guide list
  rides in `fields`, so editing it still forces the rebuild `invalidateEpg` expects - the guide
  refresh must not be deferred. The metadata half is `MetadataConfig.sameConfiguration`, because the
  repository's `MetadataProvider`s are `final`: a changed key, provider or `autoEnrich` flag has to
  rebuild, or enrichment keeps credentials the user just replaced.
- **`SourceConfig.sameSourceInputs`** - the narrower question of whether the *built* `Source` itself
  is stale. Hidden categories, aspect mode, buffer preset and the resume preference never reach
  `build()`, so the common edit keeps the source object as well: nothing to swap, nothing to retire,
  and no chance of disturbing work in flight. The catch-up overrides, the two Xtream levers and the
  label (`displayName`, printed by the player badge and the zap banner) *are* baked in by `build()`,
  so those reuse the repository but hand it a freshly built source.

**A reused repository's old source is retired, not disposed** (`HomeShell._retiredSources`). A
source's `dispose()` force-closes its HTTP client, and an in-flight channel load or streamed guide
fetch still holds the repository that was reading through it; retiring one immediately would abort
that work, and unlike the full rebuild - where the child starts a fresh load straight after - nothing
would be there to replace it. Retired sources are closed on the next rebuild or on teardown, which is
prompt enough: an idle source costs a keep-alive socket and nothing else.

Keep the two predicates in step with `build()` and with the settings keys
`source_settings_screen` writes. A key `build()` reads that is missing from `_sourceReadSettings`
leaves a stale source until the next rebuild; a settings key wrongly listed there costs a needless
source swap (retirement churn), not correctness.

## Scheduled catalogue refresh

Each source carries an optional **catalogue refresh interval** — `settings['refreshInterval']`, one
of `startup` / `6` / `12` / `24` / `48` hours, default 24, edited in the source-settings screen's
"Catalogue refresh" tile (`lib/sources/refresh_interval.dart` for the enum and the pure
`planSourceRefresh`, `SourceConfig.refreshInterval` for the read). It refreshes **channels and VOD,
never the EPG**: the guide has its own freshness window and its own ingest coordinator, and forcing a
large XMLTV download behind every catalogue refresh is exactly the coupling that separation exists to
avoid. `LibraryRepository.refreshCatalog` is the no-EPG channel path (`load`'s `forceRefresh` makes
`_epgNeedsRefresh` return true, so reusing it would force a guide fetch), and the VOD halves reuse
`loadMedia(forceRefresh: true)`.

**The schedule runs after the cached load, never instead of it** (`ChannelListScreen`): the cached
catalogue paints first, then `_maybeAutoRefresh` decides whether a refresh is due and runs it in the
background, one shot per screen — a launch must never show a spinner for a refresh the user did not
ask for. A failed background refresh leaves the cached list and its chrome untouched (fail soft); the
live half goes through `LiveController.refreshCatalog`, which deliberately sets no `error`.

**When the last refresh ran is device-local, never `settings`.** `settings` rides the source row into
the cloud, so a last-run timestamp there would push a rewrite on every refresh, advance
`profiles.updated_at`, and hand a paired device a clock reading that describes *this* device's
schedule. `SourceRefreshStore` (`lib/data/source_refresh_store.dart`) keeps a `{sourceId: epochMs}`
map in the keychain beside the expiry cache, and **a manual refresh resets it** — pressing Refresh
records "now" so the scheduled one does not immediately fire again. An absent/unreadable record reads
as *never refreshed*, which the planner treats as due: the safe direction, since a missing record
must not silently disable the feature.

