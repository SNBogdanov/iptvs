-- Schema version handshake.
--
-- The app has to know what the server supports. Before this table the only
-- signal was an RPC failing with "function does not exist", which the client
-- could turn into a silent no-op (device settings) but not into a clear state.
--
-- `app_schema` holds one row. Every forward migration ends with an update that
-- raises `version` to its own monotonic number; `get_schema_version()` is the
-- public, data-free read the app uses at startup / on the Cloud sync screen.
-- The app compares it with its own build constant and:
--   * server older  -> shows which features are unavailable, keeps the rest;
--   * server newer  -> tells the user to update the app;
--   * missing       -> treats it as 0 (a pre-versioning server).
--
-- The table is RPC-only: RLS is on with no policies and no table grants. The
-- version itself is not sensitive, so the function is executable by `anon` as
-- well as `authenticated`; the client can report the server version before a
-- session even exists.

create table if not exists public.app_schema (
  id         smallint primary key default 1 check (id = 1),
  version    bigint not null,
  updated_at timestamptz not null default now()
);

alter table public.app_schema enable row level security;
revoke all on table public.app_schema from public, anon, authenticated;

-- `greatest` keeps a replayed older migration from lowering a version that a
-- newer migration already raised.
insert into public.app_schema (id, version, updated_at)
values (1, 2026112801, now())
on conflict (id) do update
  set version = greatest(public.app_schema.version, excluded.version),
      updated_at = now();

create or replace function public.get_schema_version()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select version from public.app_schema where id = 1
$$;

revoke all on function public.get_schema_version() from public;
grant execute on function public.get_schema_version() to anon, authenticated;
