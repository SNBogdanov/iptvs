import { defineConfig, loadEnv } from 'vite';

// Published to two hosts from one config, and the base path is what separates
// them: GitHub Pages serves a *project* page at https://<user>.github.io/iptvs/
// (base `/iptvs/`), Cloudflare Pages serves the apex custom domain (base `/`,
// via PANEL_BASE). Both stay live — shipped app builds carry the GitHub Pages
// URL in `CloudConfig.panelUrl`, and installs are arbitrarily old.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const supabaseUrl = (env.VITE_SUPABASE_URL || '').replace(/\/+$/, '');
  // The panel only ever connects to itself and to the project's Supabase origin
  // (PostgREST/auth over https; realtime wss is included for completeness even
  // though the panel doesn't subscribe to channels). Nothing third-party.
  const connectSrc = ["'self'", supabaseUrl, supabaseUrl.replace(/^https:/, 'wss:')]
    .filter(Boolean)
    .join(' ');

  // Strict CSP (adversarial amendment M3): default-deny, no inline scripts, no
  // third-party origins. Applied to the built output only — the dev server
  // (with its inline HMR client + websocket) is intentionally left
  // unconstrained. `vite preview` serves the built output, so it carries it.
  //
  // `img-src` is the one directive that cannot be a fixed origin list: the
  // History tab renders artwork URLs that come from the *data* (provider CDNs,
  // and LAN hosts like http://transmission/MediaCover for the reference
  // library), so it allows the two http(s) schemes and nothing else — no data:,
  // no blob:, no javascript:. Scripts, styles, connections and frames stay
  // locked to 'self' + the project's Supabase origin, which is where the
  // meaningful attack surface is.
  //
  // `style-src 'self'` also means **no inline `style="..."` attributes**: the
  // built panel strips them (the dev server has no CSP, so the difference shows
  // up only in production). An element whose width rode in an inline style then
  // falls back to `width: auto` — a History progress bar rendered full for every
  // row, which is exactly what happened. Dynamic geometry uses a native
  // `<progress value=… max=…>` (history.js) instead; keep it that way.
  const cspDirectives = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' https: http:",
    "font-src 'self'",
    `connect-src ${connectSrc}`,
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
  ];

  // The policy is delivered **twice, and deliberately not identically**.
  //
  // The `<meta http-equiv>` copy is the one GitHub Pages gets, because it
  // serves static files and cannot set response headers. `frame-ancestors` is
  // ignored by spec when delivered that way (browsers log a console warning and
  // enforce nothing), so listing it there would advertise clickjacking
  // protection the panel does not have — `src/framebust.js` is the real thing
  // on that host.
  //
  // The `_headers` copy is read by Cloudflare Pages, which *can* send real
  // response headers — so that one carries `frame-ancestors 'none'` and the
  // framebust script drops to defence in depth. Where both are present a
  // browser enforces the intersection, which is what we want: identical
  // directives, plus one the meta tag could never carry.
  const metaCsp = cspDirectives.join('; ');
  const headerCsp = [...cspDirectives, "frame-ancestors 'none'"].join('; ');

  // Emitted into every build. Inert on GitHub Pages (served as a plain file,
  // revealing nothing the meta tag doesn't already state), so the two deploy
  // targets can share one build config instead of drifting apart.
  //
  // HSTS is deliberately without `includeSubDomains`/`preload`: the apex is the
  // panel, but the domain's other names are mail infrastructure, and pinning
  // HTTPS across a whole zone from an unrelated static site is someone else's
  // outage later. Set it zone-wide in Cloudflare if that is ever wanted.
  const headersFile = [
    '/*',
    `  Content-Security-Policy: ${headerCsp}`,
    '  X-Frame-Options: DENY',
    '  X-Content-Type-Options: nosniff',
    '  Referrer-Policy: no-referrer',
    '  Strict-Transport-Security: max-age=31536000',
    '',
  ].join('\n');

  return {
    base: process.env.PANEL_BASE ?? '/iptvs/',
    plugins: [
      {
        name: 'iptvs-security-policy',
        apply: 'build',
        transformIndexHtml(html) {
          return html.replace(
            '</title>',
            `</title>\n    <meta http-equiv="Content-Security-Policy" content="${metaCsp}" />`,
          );
        },
        generateBundle() {
          this.emitFile({ type: 'asset', fileName: '_headers', source: headersFile });
        },
      },
    ],
  };
});
