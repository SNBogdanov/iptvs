# iptvs web panel

A tiny static SPA (Vite + `@supabase/supabase-js`, no framework) for managing your
IPTV source list from a real keyboard. Devices pull the list down with no on-device
login (and can push their own list back up) — see `supabase/README.md` for the backend
and `CLAUDE.md` for the big picture.

## Develop

```bash
cd panel
cp .env.example .env.local   # fill in your Supabase URL + anon key
npm install
npm run dev
```

## Build

```bash
npm run build   # outputs panel/dist/, base path '/iptvs/' (PANEL_BASE to override)
npm test        # node:test over src/validate.js (validation + error scrubbing)
```

Input validation and error display live in `src/validate.js` — a dependency-free
module (`validateSource` scheme/length checks mirroring the server-side limits,
`scrubUrls` credential stripping, `friendlyError` safe error mapping; raw errors
go to `console.error` only, and Postgres `details`/`hint` are never rendered).

**No inline styles.** The built panel ships `style-src 'self'` (see
`vite.config.js`), so an inline `style="..."` attribute is stripped in production —
the dev server has no CSP, which is why this only shows up once deployed. A width
that rode in one falls back to `auto`: that is how every History progress bar came
out full while the numbers were right. Dynamic geometry uses a native
`<progress value=… max=…>` (or a class), never an inline style.

GitHub Actions deploys `dist/` to Cloudflare Pages on push to `main`
(`.github/workflows/pages.yml`). Supabase values come from repo
**Variables** `SUPABASE_URL` / `SUPABASE_ANON_KEY` (anon/publishable only). For a full
“host your own cloud” walkthrough, see [`../cloud/SELF-HOSTING.md`](../cloud/SELF-HOSTING.md).

### Private LAN deployment

The owner's own copy is static files behind the `transmission` container's Apache, at
`http://transmission/iptvs/` (and `https://transmission/iptvs/`). Build on the PC and copy
`dist/` — no Node on the server:

```bash
tar -C dist -czf /tmp/panel-dist.tar.gz .
scp /tmp/panel-dist.tar.gz transmission:/tmp/
ssh transmission 'rm -rf /var/www/html/iptvs && mkdir -p /var/www/html/iptvs \
  && tar -C /var/www/html/iptvs -xzf /tmp/panel-dist.tar.gz \
  && chmod -R a+rX /var/www/html/iptvs'
```

That origin is in the Supabase redirect allow-list, and the local `dart_define*.json` files set
`PANEL_URL` to it (Windows and Android alike). `_headers` only matters on Cloudflare; on Apache the
CSP comes from the meta tag inside `index.html`.

## What it does

- **Login** — magic-link email only (no passwords, no OAuth).
- **Profiles** — an account holds multiple named profiles, each its own source list,
  metadata, and favorites. A selector in the header chooses the working profile;
  the **Profiles** tab adds / renames / deletes / reorders them. A `Default` profile
  is created automatically. Sources and metadata are scoped to the selected profile.
- **Sources** — CRUD over the selected profile's `sources` rows; field shapes mirror
  `lib/sources/source_config.dart` per kind (Stalker / Xtream / M3U / Demo).
  Reorder with ↑/↓ — devices show sources in this order.
- **Metadata** - the selected profile's TMDB/TVDB/MDBList keys + auto-enrich toggle.
- **History** - read-only watch state reported by the app: resume points with a
  progress bar and finished titles, each with the title/year/artwork snapshot the
  device sent alongside its position. The device owns the data; the panel only
  reads it, and rows are never edited here.
- **Devices** — pair by entering a device's code (`claim_pairing` RPC) with an
  optional name (leave it blank and the device's own suggestion — "Android TV",
  "Windows PC" — is used), rename, revoke;
  each device shows which profile it's syncing. Devices choose their profile on-device.
