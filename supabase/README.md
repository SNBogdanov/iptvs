# Supabase backend for iptvs cloud sync

This directory holds the database schema for the optional **cloud source panel** —
a web UI where you manage your IPTV source list once and devices pull it down with
no on-device login. See the repo `CLAUDE.md` and the design notes for the full picture.

## What's here

- `migrations/*.sql` — tables, row-level security, and the RPCs (filenames use
  Supabase's `<timestamp>_<name>` convention). The first migration is the entire
  security boundary; read its header comment before changing anything. The pairing
  RPCs link a device to an account; the `push_sources`/`push_metadata` RPCs
  (`..._two_way_push.sql`) are the only device→cloud write path — owner-scoped via
  `current_device_owner()`, so an unpaired anon caller is rejected and a payload
  can't reach another account's rows.
- **Tenant isolation** (`..._tenant_isolation.sql`) — makes that last sentence
  actually true. It was not: an owner-guarded `ON CONFLICT` *skips* a foreign row
  rather than rejecting it, so a crafted `push_sources` payload could carry another
  account's source id into the secret loop and plant a credential there. Adds
  composite `(id, owner)` keys + composite FKs so a cross-owner row is
  unrepresentable, raises instead of skipping on a foreign id, filters
  `source_secrets.owner` in `get_secrets`, drops the unvalidated direct
  `pairings` INSERT path, makes `devices.device_uid` immutable, throttles
  `claim_pairing`, and revokes table-level grants on the five RPC-only tables.
- **Profiles** (`..._profiles.sql`) — an account holds multiple named **profiles**,
  each its own source list + metadata config + per-source `settings` (hidden
  categories) + `favorites`. `sources`/`metadata_configs` gain a `profile_id`
  (`metadata_configs` is re-keyed to one row per profile); `devices` gain
  `active_profile_id` (which profile that device syncs). The push RPCs take a
  `p_profile_id` and verify it belongs to the caller's account; new
  `push_favorites` and `set_device_profile` RPCs follow the same owner-scoped
  pattern. The migration backfills a `Default` profile for every existing owner
  (idempotent), so a single-profile account is unchanged. Owner-scoping remains the
  security boundary — `profile_id` is only an added filter, and a paired device can
  already read all of its owner's data. The legacy 1-arg `push_sources`/
  `push_metadata` delegate to the device's `active_profile_id` so older app builds
  stay scoped to one profile.
- **Snapshot revisions** (`..._profile_snapshot_revision.sql`) —
  `profiles.updated_at` is the revision for the complete profile snapshot.
  Triggers advance it for source and metadata inserts, updates, and deletes as
  well as direct profile/favorites edits, so the app's destructive-push warning
  detects panel changes anywhere in the snapshot.
- **Profile cap** (`..._profile_cap.sql`) — a `BEFORE INSERT` trigger
  (`enforce_profile_cap`) limits each account to **20** profiles. Enforced in the
  database so neither the panel nor a crafted client can exceed it; the panel also
  mirrors the limit (`MAX_PROFILES`) to disable its add button.
- **Account deletion** (`..._account_deletion.sql`) — the panel's
  `delete_account` RPC removes only the signed-in real account. Owner foreign
  keys cascade its cloud data, and the RPC also removes the anonymous auth
  identities of devices paired to that account.
- **Watch state** (`..._watch_state.sql`, `..._watch_state_meta.sql`,
  `..._watch_state_backdrop.sql`) — VOD/series resume points and watched marks in their
  own keyed table (`watch_state`, primary key
  `(profile_id, source_id, kind, item_id)`, `kind` limited to
  movie/series/episode), instead of another array on `profiles`: progress moves
  every few seconds, so the write has to be O(changed titles). Devices push a
  per-title delta through `push_watch_delta` (position, watched, or **cleared** —
  which deletes the row, because an absence cannot express a removal); the RPC
  skips entries whose source is not in the profile and never errors on them.
  Each row also carries the `title`/`year`/`poster`/`backdrop` snapshot the panel
  renders (the cloud holds no catalogue); the merge is field-preserving, so a
  push that does not know a value keeps the stored one, and both artwork URLs are
  http(s)-only and bounded like every other client-writable column.
  `anon`/`authenticated` hold SELECT only (RLS: the owner or a paired device);
  deleting a source cascades its progress away.
- **Device settings** (`..._device_settings.sql`) - the app's keychain preferences backed up per
  **physical device**, keyed by a SHA-256 of Android `ANDROID_ID` / a Windows file id, so a reinstall
  can restore them after pairing. RPC-only (`get_device_settings`/`push_device_settings`), RLS on
  with no policies and no table grants; a 64 KiB JSON object cap. See `docs/cloud-sync.md`
  "Per-device settings backup".

## One-time setup

For a complete walkthrough aimed at a user deploying their own instance (Supabase project + panel
host + app connection), see [`cloud/SELF-HOSTING.md`](../cloud/SELF-HOSTING.md). The steps below are
the backend-specific summary.

1. Create a free project at <https://supabase.com>.
2. Apply the migrations. With the Supabase **GitHub integration** connected to this
   repo, pushing `supabase/migrations/` applies new migrations automatically. Or use
   the CLI (`supabase link --project-ref <ref>` then `supabase db push`), or paste the
   SQL into the dashboard SQL editor.
3. **Auth → Providers / Sign In**: enable **Email** (magic link) and turn on
   **Anonymous sign-ins** (devices rely on them). The panel uses magic-link only.
4. **Auth → URL configuration**: add the GitHub Pages panel URL to the redirect allow-list.
5. **Run the security advisor** after applying (`get_advisors` / dashboard Advisors):
   the only expected warnings are the intentional `SECURITY DEFINER` RPCs (the three
   pairing RPCs, `push_sources`/`push_metadata`/`push_favorites`, and `set_device_profile`,
   all callable by `authenticated`), the anonymous-access policies on the tables (devices
   read by design), and Supabase's own `rls_auto_enable`. The push RPCs are revoked from
   `anon` (they need a real session).

> **Applying a migration out-of-band? Repair the version afterward.** When you apply a
> migration file through the **MCP `apply_migration` tool** or the **dashboard SQL editor**
> (rather than `supabase db push` / the GitHub integration), the remote ledger records it
> under a *freshly generated* version timestamp — not the file's `<version>_` prefix. The
> next `supabase db push` / "Supabase Preview" then fails with **"Remote migration versions
> not found in local migrations directory"** because the recorded version has no matching
> file. Fix it by aligning the ledger to the committed filename:
> ```sql
> update supabase_migrations.schema_migrations
>    set version = '<file_version>'   -- e.g. 20260630000000, the file's prefix
>  where name = '<migration_name>' and version = '<generated_version>';
> ```
> (Equivalent to `supabase migration repair --status applied <file_version>` when the CLI is
> linked.) The committed `supabase/migrations/*.sql` files are the source of truth; the remote
> ledger should match their version prefixes exactly.

## Wiring the clients

Both clients use the **anon/publishable** key — it is safe to commit because RLS
(in the migration) is deny-by-default. **Never** put the `service_role` key in the
app, the web panel, or this repo.

Prefer the modern **publishable key** (`sb_publishable_…`) over the legacy anon JWT.

- **Web panel** (`panel/`): set `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` (GitHub
  Actions reads these from repo **Variables** — they're public by design, not secrets). A
  self-hosted server may instead serve a `config.js` that sets `window.__IPTVS_CLOUD__` before the
  panel bundle; the runtime value wins over `VITE_*`. Every configured build also emits
  `/.well-known/iptvs-cloud.json` (with a `_redirects` rewrite for Cloudflare Pages), which is what
  the app's domain-only setup reads.
- **Flutter app** (`lib/data/cloud_config.dart`): the `--dart-define`s are **defaults only** since
  option D. The server is normally chosen on the Cloud sync screen and stored per device.
  - **CI**: the build/release workflows pass the repo Variables as defaults; remove them to ship
    an unconfigured build (see `cloud/runtime-server.md`).
  - **Local dev**: configure the server in the app, or copy `dart_define.example.json` →
    `dart_define.json` (gitignored) and run
    `flutter run -d <platform> --dart-define-from-file=dart_define.json`; the value is migrated
    into the keychain on first boot.

## Security checklist (do this before trusting it)

**These were unchecked manual boxes for months, and two of them were false** (a
`push_sources` payload *could* reach another account's secret rows; an anonymous
session *did* have a direct INSERT on `pairings`). They are now the spec for the
pgTAP suite in `supabase/tests/` — prefer extending that over re-checking by hand.

- [ ] Anonymous session reads **nothing** from `sources`/`metadata_configs` until paired.
- [ ] Anonymous session has **no direct** INSERT/UPDATE/DELETE on any table (writes need a real account).
- [ ] `push_sources`/`push_metadata` reject an **unpaired** anonymous caller (no owner).
- [ ] A `push_sources` payload can't create/modify/delete rows for another account (owner-scoped).
- [ ] `push_sources`/`push_metadata`/`push_favorites`/`push_watch_delta`/
      `set_device_profile` reject a `profile_id` the caller's account doesn't own.
- [ ] Account A cannot read or write account B's profiles, sources, favorites or
      watch state.
- [ ] `claim_pairing` rejects an anonymous claimer, an expired code, and an already-claimed code.
- [ ] Deleting a `devices` row immediately revokes that device's read access (and its push).
- [ ] `delete_account` rejects anonymous devices, deletes only the caller, and
      removes all owner rows plus the caller's paired anonymous auth users.
- [ ] A `push_sources` payload naming another account's **source id** raises
      `iptvs: source id belongs to another account` (it used to skip silently).
- [ ] `get_secrets` never returns a `source_secrets` row owned by another account.
- [ ] `sources`/`metadata_configs` cannot be inserted pointing at another
      account's `profile_id` (composite FK violation).
- [ ] An anonymous session cannot INSERT into `pairings` directly, and
      `request_pairing` still works.
- [ ] `update devices set device_uid = …` raises `iptvs: device identity is
      immutable`, and `claim_pairing` still succeeds (it re-points `owner`).
- [ ] `anon`/`authenticated` hold **no** privileges on `source_secrets`,
      `metadata_secrets`, `profile_crypto`, `device_ck`, `push_rate`, and no
      TRUNCATE on the five client-facing tables.
- [ ] `pairings.suggested_label` — the one column an **anonymous** session can write
      that is displayed in **another account's** panel — is bounded (256, matching
      `devices_validate`), rejects control characters, and is frozen on UPDATE.
- [ ] A cross-account re-pair does not carry the previous owner's `devices.label`
      into the new owner's device list, and a same-owner re-pair with a blank panel
      name does not overwrite the name already stored.
- [ ] Every `SECURITY DEFINER` function pins `search_path = ''`.
