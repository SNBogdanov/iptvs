// Optional runtime cloud configuration for a self-hosted panel.
//
// The public build ships this file empty and uses the VITE_SUPABASE_* values
// baked in at build time. A self-hosted stack can replace it (same path) with:
//
//   window.__IPTVS_CLOUD__ = {
//     url: 'https://cloud.example.com',
//     anonKey: 'sb_publishable_…',
//     panelUrl: 'https://cloud.example.com/',
//   };
//
// The anon key is public by design; never put the service_role key here.
