# Run your own cloud sync (managed Supabase + static panel)

This is the supported, step-by-step way for **anyone** to get a working cloud sync setup that
belongs to them: their own Supabase project and their own panel host. It does **not** use the
author's Supabase project, panel or LAN server, and the published app contains no endpoint.

- The **backend** is a Supabase project you create (free tier is enough for a household).
- The **panel** is a static site built from `panel/` and hosted wherever you like (Cloudflare Pages,
  GitHub Pages, nginx, Apache, a NAS).
- The **app** stores the server per device; you point it at your panel's domain once.
- You do **not** need a VPS, a custom app server, or to build the Flutter app.

> A **fully self-hosted backend** (Postgres + GoTrue + PostgREST in Docker, no Supabase Cloud) is
> described in [`README.md`](README.md) but is **not implemented yet**. Follow this guide if you want
> a working setup today.

## 1. Create the Supabase project

1. Sign in at <https://supabase.com> and create a project (any region close to you).
2. From **Project Settings → API** (or **Connect**), note:
   - **Project URL** — `https://<project-ref>.supabase.co`
   - **publishable / anon key** — the public client key. **Never** use or copy the
     `service_role` key into the app, the panel, or git.
3. Your project starts empty; the next step creates the schema and its security rules.

## 2. Apply the database migrations

The whole backend is `supabase/migrations/*.sql`: tables, row-level security, pairing and push
functions. Apply **all files in filename order**; they are idempotent, so a retry is safe.

Pick one method:

**A. SQL editor (simplest, no tools).** In the Supabase dashboard open **SQL Editor** and run each
file from `supabase/migrations/` in filename order. There are about two dozen; the first one is the
security boundary and must be first.

**B. `psql` (macOS/Linux/WSL).** Copy the *Session pooler* connection string from
**Connect** in the dashboard, then:

```bash
git clone https://github.com/SNBogdanov/iptvs.git
cd iptvs
export DATABASE_URL='postgresql://postgres.<project-ref>:<password>@<host>:5432/postgres'
for f in $(find supabase/migrations -maxdepth 1 -name '*.sql' | sort); do
  echo "applying $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1
done
```

Percent-encode special characters in the password. `ON_ERROR_STOP=1` is important: a half-applied
security migration is worse than a stopped one.

**C. Supabase CLI.** If you use it:

```bash
supabase link --project-ref <project-ref>
supabase db push
```

(It may ask you to initialise a project; point it at this repository's `supabase/` directory.)

Afterwards the database has 11 tables with deny-by-default RLS. Do not disable RLS and do not edit
the migrations by hand; that SQL *is* the security boundary.

## 3. Configure Auth

In **Authentication**:

1. **Providers → Email**: enabled. The panel uses **magic links only** (no password, no OAuth).
2. **Sign In / Up → Allow anonymous sign-ins**: **ON**. Devices pair as anonymous users; this is
   required.
3. **URL Configuration**:
   - **Site URL**: your panel origin, e.g. `https://panel.example.com/`
   - **Redirect URLs**: the same origin with a wildcard, e.g. `https://panel.example.com/**`
     (add `http://panel.local/**` too if you also serve the panel on a LAN host).
   The panel builds its redirect as `origin + base path`; if the panel lives under a subpath, the
   entry must include that subpath.
4. **Emails / SMTP**: the built-in mailer is rate-limited and meant for testing. For regular use add
   your own SMTP server (host, port, user, password, sender) under **Authentication → Emails**.

Once your own accounts exist you can turn **Allow new users to sign up** off (anonymous sign-ins
stay on). That prevents strangers from creating accounts on a panel reachable from the internet.

## 4. Build the panel

The panel is the browser UI that manages sources, profiles and pairing. It is a static bundle — no
Node is needed on the server.

```bash
cd panel
npm ci
VITE_SUPABASE_URL='https://<project-ref>.supabase.co' \
VITE_SUPABASE_ANON_KEY='sb_publishable_…' \
PANEL_BASE='/' \
npm run build
```

- `PANEL_BASE=/` is correct for a dedicated domain. Use `/iptvs/` (the default) if the panel lives
  under a subpath; then the address you later type in the app includes that subpath.
- `npm run verify-build` does the same plus a bundle check; it also refuses a build whose discovery
  file does not match the configured endpoint.
- The build writes `dist/.well-known/iptvs-cloud.json`, `dist/cloud-config.json` and
  `dist/_redirects`. The first is what the app reads; keep them next to the panel.

You can use a `.env.local` file (`panel/.env.example`) instead of inline variables.

## 5. Host the panel

Any static host with HTTPS works. The discovery file is the only special requirement:

| Host | What to do |
|---|---|
| **Cloudflare Pages** | `npx wrangler pages deploy dist --project-name <name>`. The emitted `_redirects` serves `/.well-known/iptvs-cloud.json` even if the host ignores dot-directories. |
| **nginx** | `root /var/www/iptvs-panel;` with an SPA fallback (`try_files $uri $uri/ /index.html;`). Dot-directories are served by default. |
| **Apache / NAS** | Point a vhost at the directory; `.well-known` is served by default. An SPA fallback to `index.html` is needed for deep links. |
| **GitHub Pages** | Deploy `dist/` as the Pages artifact (Actions or `gh-pages`). Dotfiles are included in the artifact; do not run it through Jekyll, or add `.well-known` to Jekyll's `include`. |
| **LAN only** | `http://panel.local/` is fine. Plain HTTP is accepted for the **panel/discovery** address (the API itself must stay HTTPS); add that origin to the redirect list. |

TLS: Cloudflare Pages gives it for free; on your own host use Caddy or certbot. A panel on plain
HTTP is acceptable only inside a trusted LAN.

Verify the discovery document before touching the app:

```bash
curl -s https://panel.example.com/.well-known/iptvs-cloud.json
# {"version":1,"url":"https://<ref>.supabase.co","anonKey":"sb_publishable_…"}
```

If that URL 404s, fix the base path or the dot-directory handling first; nothing else will work.

## 6. Point the app at your server

The published app is shipped **without** a cloud endpoint (from 1.0.4 onward), so this is the
normal first-run state.

1. In the app: avatar → **Profile settings** → **Cloud sync**.
2. In **Connect a cloud server**, enter the panel address only, e.g.
   `https://panel.example.com` (or `http://panel.local`).
3. **Check server** → it shows `Found: …` → **Save server**.
   The key comes from the well-known file; nothing secret is typed.
4. If the discovery file cannot be hosted, use **Enter the URL and key manually**:
   - server address: your `https://<ref>.supabase.co`
   - publishable key
   - panel address: your panel origin
5. The first save starts the cloud client immediately. **Changing** to a different server later
   requires a restart (the app offers one) because the auth session is per server.

## 7. Create a profile and pair a device

1. Open the panel and sign in with a magic link.
2. Create a **profile** (or use the default one) and add sources / metadata keys there.
3. Open the app's Cloud sync screen; it shows an eight-character code and a QR.
4. In the panel enter that code under **Devices** (or scan the QR). The device is now paired.
5. Choose the profile the device should sync, then **Pull now** in the app. **Push** sends the
   device's local set back; favorites and watch progress sync on their own.

Pairing does not create a login on the TV; the device stays an anonymous user whose read/write
access is granted only by the pairing row and the owner-scoped RPCs.

## Security checklist

- `service_role` **never** appears in the app, the panel, this repository, or chat. Only the
  publishable/anon key ships; RLS is what protects the data.
- Keep RLS enabled and apply the migrations unmodified. The first migration is the security
  boundary; read its header before changing anything.
- The panel is an authenticated UI: treat its origin like any admin page (HTTPS, no shared
  hosting with unrelated content). Magic-link sign-up means anyone who can reach the panel and
  create an account can use that account — turn **Allow new users to sign up** off after creating
  yours.
- Configure SMTP before relying on magic links; the default mailer is rate-limited.
- Back up your project (Dashboard → Database → Backups, or `pg_dump`) if the source list and watch
  history matter.
- E2EE (optional, enabled per profile in the panel) is end-to-end: losing the passphrase means the
  panel cannot recover the content key. The server stores ciphertext either way.

## Updating

- **App**: install the next GitHub release normally; the server choice lives in the OS keychain and
  survives the update.
- **Backend**: pull the repository and apply any new `supabase/migrations/*.sql` in order.
- **Panel**: rerun the build with the same `VITE_*` values and redeploy `dist/`; the discovery file
  is regenerated with it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App: “No IPTVS cloud configuration at that address” | The address must be the **panel** (and its subpath if any), not the Supabase API. Check `curl …/.well-known/iptvs-cloud.json`. |
| That curl returns 404 | Panel built under `/iptvs/` but you entered the bare host (or vice versa); or the host does not serve dot-directories (use the `_redirects` copy / nginx). |
| Panel shows “Set VITE_SUPABASE_URL…” | Built without the environment variables. Rebuild with both values. |
| Magic link lands on the wrong page | Add the exact panel origin to **Site URL** and **Redirect URLs**. |
| App: anonymous sign-in error | **Allow anonymous sign-ins** is off in Auth. |
| Pairing code rejected | Codes expire; generate a new one in the app and enter it promptly. |
| `permission denied for function …` | The migrations were not applied in order (or not at all). Re-apply from the first file. |
| App shows the connect form after reinstalling | Settings live in the OS keychain; a full uninstall/clear removes them. Connect again. |
| Changes to the server need a restart | Expected when switching an already-configured device; the keychain is read at boot. |

## What this does and does not include

- **Included**: a real, working cloud backend (Supabase), the panel, pairing, profile sync,
  favorites/watch progress, optional E2EE.
- **Not included**: any dependency on the author's Supabase project, panel domain or LAN server —
  those are not part of this guide. The published app has no endpoint compiled in.
- **Not ready yet**: the fully self-hosted backend stack (no Supabase Cloud). Its plan and
  deployment notes are in [`README.md`](README.md); until it is implemented, the managed Supabase
  path above is the supported one.
