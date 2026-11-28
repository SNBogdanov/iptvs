# Self-hosted cloud server — design and deployment notes

> **Want a working personal cloud today?** Follow [`SELF-HOSTING.md`](SELF-HOSTING.md): your own
> managed Supabase project plus a static panel you host yourself. It uses neither the author's
> Supabase nor the author's panel/LAN host. The stack described below is the **fully self-hosted
> backend** (no Supabase Cloud), which is still a proposal; runtime server selection in the app is
> implemented (`runtime-server.md`).

## What the cloud backend is

The app's optional cloud feature is a Supabase project. Nothing else is involved:

| Piece | What it does | Where it lives |
|---|---|---|
| Postgres | 11 tables, deny-by-default RLS, ~45 SQL functions (pairing, profile push/pull, watch state, E2EE keys, account deletion, rate limits) | `supabase/migrations/` |
| GoTrue (Supabase Auth) | Devices sign in **anonymously**; the panel signs in with a **magic link** | Supabase service |
| PostgREST | The panel and the device read tables through RLS and call the RPCs | Supabase service |
| Web panel (Vite + `@supabase/supabase-js`) | Source management, profile list, pairing codes, account deletion | `panel/` |
| Flutter client | `supabase_flutter`; URL + anon/publishable key compiled in from `--dart-define` | `lib/data/cloud_config.dart`, `lib/data/cloud_sync.dart` |

Services that are **not** used: Storage, Realtime, Edge Functions, Vault/pgsodium. E2EE is
application-level (`profile_crypto`, `device_ck`, `source_secrets`) on top of plain Postgres
columns; only the `pgcrypto` extension is required.

The security boundary is the SQL, not the vendor: the anon key is public by design, the
`service_role` key never ships to any client, and every row is pinned to its owner by RLS plus
composite foreign keys. That is why the same migrations can run on a private server unchanged.

## Options

### A. Self-hosted Supabase — recommended

Run the official Supabase Docker stack (Postgres + Auth + PostgREST + gateway), apply the
existing migrations, serve the existing panel from the same domain.

- **No SQL changes.** Migrations reference `auth.users`, `auth.uid()` and `pgcrypto`, all of
  which a self-hosted Supabase provides.
- The panel and the app speak the same protocol; only their endpoint configuration changes.
- The pgTAP suite in `supabase/tests/` can be run against the private database, so the security
  invariants stay testable.
- Cost is operational, not code: TLS, SMTP for magic links, backups, image updates, and
  internet exposure of the anonymous sign-in endpoint.
- Footprint: a trimmed stack (db, auth, rest, gateway, Caddy) is roughly 1.5–2 GB RAM. A
  Proxmox LXC/VM is the natural host, like the other containers on the LAN.

### B. A custom lightweight server (Go/Dart/Node)

Reimplement Postgres semantics, RLS, ~45 RPCs, anonymous auth, magic-link auth and a
PostgREST-compatible query surface. Weeks of work and a fresh chance to reintroduce every
hole the migrations already close. **Not recommended.**

### C. No server setting — build-time endpoint only

Keep `--dart-define=SUPABASE_URL/SUPABASE_ANON_KEY/PANEL_URL` and produce a private build that
points at the self-hosted server. Cheapest option (hours), but a downloaded build cannot be
pointed anywhere else. This is a valid **first phase** even if Phase 2 is never done.

## Recommendation

Do **A**, in two phases:

1. **Phase 1 — infrastructure.** Add this `cloud/` stack and prove that the released app,
   built locally with `--dart-define` overrides, pairs and syncs against it. This validates
   portability without touching the client.
2. **Phase 2 — runtime server selection.** Only if Phase 1 is worth keeping: let the app point
   at a server chosen at runtime (see below), and make the panel build endpoint-agnostic.

## Proposed layout (not present yet)

```
cloud/
  README.md                 # this document
  docker-compose.yml        # db, auth, rest, gateway, caddy; studio behind a profile
  .env.example              # POSTGRES_PASSWORD, JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, SMTP_*
  caddy/Caddyfile           # TLS, static panel, /.well-known/iptvs-cloud.json
  scripts/bootstrap.sh      # key generation, apply ../supabase/migrations in filename order
  scripts/backup.sh         # pg_dump to a NAS path, cron-friendly
  scripts/verify.sh         # run the pgTAP suite against the private database
  panel/Dockerfile          # builds ../panel with a runtime config
  .gitignore                # .env, volumes/, backups/
```

**`supabase/migrations/` stays the single source of truth.** `cloud/` mounts it read-only and
applies it; no SQL is duplicated here.

## Deployment runbook (what the README will contain)

1. Host: Debian LXC/VM on Proxmox, 2 vCPU, 2–4 GB RAM, 20 GB disk.
2. DNS: `cloud.example.com` → the host or the LAN reverse proxy; expose only 443.
3. Secrets: copy `.env.example` to `.env`; generate `POSTGRES_PASSWORD`, `JWT_SECRET`,
   `ANON_KEY`, `SERVICE_ROLE_KEY` (the anon/service keys are JWTs signed by the JWT secret).
   `SERVICE_ROLE_KEY` exists only in `.env` on the server and in backup tooling — never in the
   app, the panel or git.
4. Start the stack; `bootstrap.sh` applies the migrations in filename order (idempotent).
5. Mail: configure SMTP in `.env` so the panel can send magic links; set `SITE_URL` and the
   redirect allow-list to the panel URL. Without SMTP there is no way to create a panel
   account.
6. Panel: build `panel/` into the stack and serve it from `cloud.example.com`; the build emits
   `/.well-known/iptvs-cloud.json` from `VITE_SUPABASE_*`, so the app's pairing QR and its
   one-field server setup both point at the private server.
7. Verify: `scripts/verify.sh` (pgTAP), then create an account, pair a device, push and pull.
8. Operations: nightly `pg_dump` to the NAS, pinned image tags, `docker compose pull` only
   deliberately, and re-apply migrations after each app release that adds one.

## Phase 2 — connecting the app to that server

Accepted as **option D**: the build carries the feature but no server; the endpoint is a
per-device setting that survives updates. The full contract (stored values, boot order,
well-known file, UI states, what is cleared, tests) lives in
[`runtime-server.md`](runtime-server.md). In short:

- the server may publish `/.well-known/iptvs-cloud.json` so the user types only a domain;
- the endpoint is stored in the keychain and read before `Supabase.initialize` at boot;
- changing the server clears only cloud identity and asks for a restart;
- local sources, favorites and watch state are never touched.


## What changes for existing data

A new server means a new account and a new anonymous user: the device must be paired again.

- Local sources, favorites and watch state remain on the device and are pushed into the new
  profile.
- E2EE is server-scoped: the content key is wrapped per device and stored server-side. After a
  move the passphrase has to be entered again (the key is re-provisioned); old
  `cloud_e2ee_marks` are reset.
- There is no supported data export from the managed project into a private one; treat the
  move as "re-pair and push".

## Risks

- **Operations are the real cost**: TLS certificates, SMTP deliverability for magic links,
  Supabase image updates, backups, monitoring. The SQL is the easy part.
- **Anonymous sign-in is internet-facing.** Anyone who finds the endpoint can create an
  anonymous user; the app only does so after the user opens Cloud sync or requests a pairing
  code, but a custom client can call the API directly. Rate limits exist in the SQL for
  pairing and pushes; account creation itself is GoTrue's policy.
- **Public panel sign-up.** The panel uses magic-link sign-in, so anyone with the URL can
  create an account on the project. On the managed project that is intended (it is a public
  service); on a private server it may not be. Options if that matters: keep the server
  behind a VPN/Tailscale, or restrict sign-ups in the auth configuration.
- **Update drift**: self-hosted Supabase images move; pin tags and re-run the pgTAP suite after
  upgrades.

## What a downloaded build points at (current behaviour)

This is unrelated to `cloud/`, but it decides whether self-hosting is worth the trouble.

**Since option D the endpoint is stored per device and survives updates.** The release workflow
builds app artifacts **without** `SUPABASE_*`, so a downloaded build contains neither the URL nor
the key and starts on the connect form; the panel deploy still uses the variables to publish the
discovery file. A device that connected once keeps its server across updates. If an older install
never wrote the keychain (it predates the migration), it simply connects once.

Release artifacts are compiled by `.github/workflows/release.yml` **without** `SUPABASE_*`, and the
old "Require the cloud configuration" gate is gone: unconfigured is now the intended state. The
panel deploy (`pages.yml`) still uses the variables to build the panel and publish the discovery
file. Consequences for a downloaded APK/MSI:

- It contains neither the project URL nor the key; the first launch shows the connect form.
- Once the user connects a server, that choice lives in the keychain and survives updates.
- Nothing is pre-pointed at the author's project. The public panel, if the author still deploys one,
  is only a discovery/UI host the user may choose to enter.
- The project URL + anon key are **not secrets**; anyone holding them can reach a Supabase API, but
  RLS and pairing decide what is readable. Removing them from the artifact removes the default, not
  the login.

For a personal setup the release artifact is therefore safe to publish as-is: your own devices
connect once (normally by entering the LAN/public panel's domain), and a stranger's install has
nowhere to go until they bring a server of their own.

## Effort (rough)

| Work | Estimate |
|---|---|
| `cloud/` stack, Caddy, key generation, bootstrap, backup, README | 1–2 days |
| Panel runtime config + container image | 0.5–1 day |
| Phase 2 client: endpoint store, boot resolution, server card, well-known fetch, tests | 3–5 days |
| End-to-end verification (pairing, push/pull, watch state, E2EE) on the private server | 1–2 days |

## Decision checklist

- Is the server reachable from outside the LAN, or only over VPN? (TV devices may not have VPN.)
- Which SMTP account sends magic links?
- Does the private server need to accept accounts for other people? If yes, self-hosting adds
  little over the managed project; if no, how is sign-up restricted?
- Is Phase 2 (server selection in the app) wanted, or is a locally built APK/MSI with
  `--dart-define` enough?
- Who owns TLS renewal, image updates and backups?
