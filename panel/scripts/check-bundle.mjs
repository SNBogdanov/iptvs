// Asserts a *configured* build actually ships the Supabase client.
//
// `supabase.js` throws at module top-level when neither the `VITE_*` variables
// nor a runtime `window.__IPTVS_CLOUD__` config is present, before
// `createClient(url, key)` is reached. Since runtime configuration exists, a
// build with no `VITE_*` values may still keep `@supabase/supabase-js` (it
// cannot know what `config.js` will set), so this script skips when the env is
// absent rather than guessing from a bundle it cannot judge.
//
// What it does catch, on a build that IS configured: the client silently
// vanishing from the output. `npm test` cannot see that — the panel's suite
// exercises `validate.js`, which is deliberately dependency-free and never
// imports `supabase.js` — and a bundler can drop working code without failing.
// The artifact needs its own smoke test; this is it.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dist = join(import.meta.dirname, '..', 'dist');
const assets = join(dist, 'assets');

// A floor, not a target: a configured bundle is ~265 kB. Kept well under that
// so an ordinary dependency trim doesn't trip it, and well over the ~10 kB an
// unconfigured build produces.
const MIN_ENTRY_BYTES = 120_000;

function fail(message) {
  console.error(`check-bundle: ${message}`);
  process.exit(1);
}

// Mirrors what `vite build` itself reads, including a `.env` file if present.
const configured =
  (process.env.VITE_SUPABASE_URL ?? '') !== '' &&
  (process.env.VITE_SUPABASE_ANON_KEY ?? '') !== '';

if (!configured) {
  // Not a failure. An unconfigured build legitimately has no client in it, and
  // developers build the panel this way all the time.
  console.log(
    'check-bundle: skipped — VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY are not set, ' +
      'so this build has no Supabase client to look for.',
  );
  process.exit(0);
}

let entries;
try {
  entries = readdirSync(assets).filter((f) => f.endsWith('.js'));
} catch {
  fail(`no ${assets} — run \`npm run build\` first`);
}

if (entries.length === 0) fail('no JS emitted into dist/assets');

const sizes = entries.map((f) => ({ f, bytes: statSync(join(assets, f)).size }));
const entry = sizes.reduce((a, b) => (b.bytes > a.bytes ? b : a));
const source = readFileSync(join(assets, entry.f), 'utf8');

// `createClient` survives minification: it is a named import off a bare
// specifier, so the bundler keeps the identifier in the module factory even
// when local bindings are renamed. Its absence in a configured build means the
// module was dropped.
if (!source.includes('createClient')) {
  fail(
    `${entry.f} does not contain the Supabase client, even though this build ` +
      'is configured. `@supabase/supabase-js` was dropped from the bundle.',
  );
}

if (entry.bytes < MIN_ENTRY_BYTES) {
  fail(
    `${entry.f} is ${entry.bytes} bytes, below the ${MIN_ENTRY_BYTES} floor for ` +
      'a configured build. A dependency was almost certainly tree-shaken out.',
  );
}

// The panel is also the cloud's discovery document: the app's domain-only setup
// reads `/.well-known/iptvs-cloud.json` from whichever host serves this bundle.
// Cloudflare Pages gets it through the `_redirects` rewrite, other hosts read
// the dot path directly; both must carry exactly the configured endpoint.
const expectedUrl = (process.env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
const expectedKey = process.env.VITE_SUPABASE_ANON_KEY ?? '';
try {
  const wellKnown = JSON.parse(
    readFileSync(join(dist, '.well-known', 'iptvs-cloud.json'), 'utf8'),
  );
  if (wellKnown.version !== 1 || wellKnown.url !== expectedUrl || wellKnown.anonKey !== expectedKey) {
    fail('dist/.well-known/iptvs-cloud.json does not match the configured endpoint.');
  }
  const copy = JSON.parse(readFileSync(join(dist, 'cloud-config.json'), 'utf8'));
  if (copy.url !== expectedUrl || copy.anonKey !== expectedKey) {
    fail('dist/cloud-config.json does not match the configured endpoint.');
  }
  const redirects = readFileSync(join(dist, '_redirects'), 'utf8');
  if (!redirects.includes('/.well-known/iptvs-cloud.json  /cloud-config.json  200')) {
    fail('dist/_redirects is missing the well-known rewrite.');
  }
} catch (error) {
  fail(`the well-known configuration is missing or invalid: ${error.message}`);
}

console.log(`check-bundle: ok — ${entry.f}, ${entry.bytes} bytes, Supabase client present`);
