# Runtime server selection (option D)

> Status: accepted and implemented on the client. This document is the contract; the app-side code
> lives in `lib/data/cloud_endpoint.dart`, `lib/data/cloud_runtime.dart`, `AppSettingsStore` and
> the Cloud sync screen. The deployment stack in `cloud/README.md` is still a proposal.

## Problem

The cloud endpoint is compiled into the artifact (`SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`PANEL_URL`). Two consequences:

- anyone who installs the published build is pointed at the author's server;
- a build without the defines hides the feature, and because GitHub Releases is the only update
  channel, stripping the defines from a public release would also remove the cloud from the
  author's own devices after the next update.

Option D separates the **server** from the **build**: the build ships the feature with no server,
and each device stores the server it talks to. The setting lives in the OS keychain and survives
an in-place update (Android `adb install -r` / MSI upgrade).

## Behaviour

| State | UI |
|---|---|
| No server | Cloud sync screen shows a "Connect a server" card; no network call, no Supabase init |
| Server stored | Normal pairing / profile / push-pull screen |
| Server unreachable | The cloud screen shows the error; the rest of the app is unaffected (offline-first) |
| Server changed | Cloud identity is cleared; the screen shows a restart-pending state and talks to neither server until the app restarts |

A downloaded public build therefore has nowhere to go until the user connects a server — that is
what makes publishing safe for the author.

## Stored values

`AppSettingsStore` (keychain):

| Key | Value |
|---|---|
| `cloud_server_url` | normalized `https://host[:port][/path]` |
| `cloud_server_key` | publishable/anon key (public by design) |
| `cloud_server_panel` | panel base URL for the QR and "open panel" |

Rules:

- `https` only for the **API** URL (`http` only for loopback during development); the **panel** and
  the **discovery** address may be plain `http` on any host, because a panel is a link/QR target
  and a LAN deployment (`http://transmission/iptvs`) is normal — the API URL the well-known file
  returns still has to be https. Normalization strips a trailing slash/query/fragment and
  lower-cases the host.
- A JWT-looking key is decoded and **rejected when `role == service_role`**; the publishable
  (`sb_publishable_…`) and legacy anon forms are accepted.
- The stored value wins over the compile-time default. A build that still has the defines
  (personal builds, older installs) migrates that default into the keychain at boot, so an
  ordinary update does not lose it.

## Boot

1. Read the stored endpoint; fall back to `CloudConfig` defaults.
2. Persist the default when it came from the build (migration).
3. If there is an endpoint, `Supabase.initialize` with it (session storage unchanged).
4. If there is none, do not initialize Supabase at all: no anonymous user, no traffic.
5. Nothing in the boot path performs a network request; the keychain read is enough.

## Well-known file (optional but recommended)

To make TV setup realistic (a remote should not type a 200-character key), the server may
publish:

`GET https://cloud.example.com/.well-known/iptvs-cloud.json`

```json
{
  "version": 1,
  "url": "https://cloud.example.com",
  "anonKey": "sb_publishable_…",
  "panelUrl": "https://cloud.example.com/"
}
```

The client fetches it with a short timeout and a response-size cap, requires `https`, and applies
the same key validation (a `service_role` key is refused). `url` may be omitted, in which case the
entered domain is used. `panelUrl` defaults to the entered domain. If the file is missing, the
manual URL + key path is the fallback (desktop/phone).

For the managed project the file can be served as a static file on the panel domain; for a
self-hosted stack Caddy generates it from the container environment.

The panel's Vite config already does this: every configured panel build emits
`.well-known/iptvs-cloud.json` (and a plain `cloud-config.json` plus a `_redirects` rewrite for
Cloudflare Pages) from `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY`. So the panel's origin —
`panel.iptvs.click`, the LAN copy, or a self-hosted one — is a valid one-field setup target for
the app, and `check-bundle` refuses a build whose discovery document does not match its bundle.

## Panel

`panel/` reads `window.__IPTVS_CLOUD__` from `/config.js` (loaded before the bundle) and falls
back to the build-time `VITE_SUPABASE_*` values. The public deploy ships an empty `config.js`; a
self-hosted stack replaces it, so one built `dist/` works against any server without a rebuild.

## Screen

`CloudSyncScreen` gains a server section:

- **Not configured**: title + one-line explanation, domain field, "Check" (fetch well-known),
  "Save"; an "Enter URL and key manually" expansion for desktop/phone.
- **Configured**: a compact `Server: cloud.example.com` row with "Change" and "Forget".
- **Change/Forget** clears only cloud identity and asks for a restart. Local sources, favorites,
  watch state and app settings are untouched.
- On a first-time save (nothing was configured at boot) the client can be initialized in-process,
  so the pairing UI appears immediately; changing an already-active server needs the restart
  because `Supabase.initialize` is process-global and sessions are per-server.

## What is cleared when the server changes

- the persisted Supabase session (`SecureLocalStorage`);
- `cloud_source_ids`, `cloud_profile_id`, `cloud_device_priv_key`, `cloud_device_pub_key`,
  `cloud_e2ee_marks` (all owned by `CloudSync`).

Not cleared: `app_database` (sources, favorites, watch state, positions), settings, other
providers. Saving the same URL again does not sign the device out.

## Tests

Pure: URL normalization/validation, `service_role` rejection, well-known parsing (valid, garbage,
oversized, wrong scheme, redirect), resolution precedence (stored > build default > none), and
"same URL does not wipe cloud keys".

Widget: empty state performs no network call; saving a manually entered endpoint calls
`CloudRuntime.initialize`; change/forget clears exactly the cloud keys.

Manual end-to-end: connect a self-hosted server, pair, push/pull, install the next GitHub release
over the device, confirm the server and pairing survive.
