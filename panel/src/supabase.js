import { createClient } from '@supabase/supabase-js';

// The anon/publishable key is safe in client code: access is gated by the
// row-level security in supabase/migrations. Never put the service_role key here.
//
// Two ways to point the panel at a server:
//  * `VITE_*` at build time — what the public deploy uses;
//  * `window.__IPTVS_CLOUD__` at run time — a self-hosted stack can serve one
//    built `dist/` for any server by writing a tiny `/config.js` that sets
//    `{ url, anonKey, panelUrl }` before this module runs (`cloud/` does that).
// The runtime value wins, so one artifact is not tied to one deployment.
const runtime =
  (typeof window !== 'undefined' && window.__IPTVS_CLOUD__) || {};
const url = runtime.url || import.meta.env.VITE_SUPABASE_URL;
const key = runtime.anonKey || import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
  document.getElementById('app').innerHTML =
    '<p class="config-msg">Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see panel/.env.example).</p>';
  throw new Error('Missing Supabase config');
}

export const supabase = createClient(url, key);

// Field shapes mirror lib/sources/source_config.dart so the panel and app
// agree. The canonical definition (plus validation limits) lives in
// validate.js — a dependency-free module so it's testable without
// supabase-js — and is re-exported here for callers importing from this file.
export { KIND_FIELDS } from './validate.js';
