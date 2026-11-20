-- Watch state: VOD/series resume points and watched marks, per profile.
--
-- Why a table rather than another array on `profiles`
-- ---------------------------------------------------
-- Favorites live in a `jsonb` column because the whole set is what a manual
-- push means, and a delta is a small add/remove list against it. Progress is
-- not that: it is one row per title, it moves every few seconds while something
-- plays, and a profile can accumulate thousands of rows. Rewriting a
-- thousands-element `jsonb` document on every position update — under the
-- profile's row lock, while the same row also carries the favorites array — is
-- a conflict amplifier for no benefit. A keyed table gets O(changed rows)
-- writes, per-row last-write-wins, and an index the panel can read later.
--
-- Why a delta, and why no tombstones
-- ----------------------------------
-- The same reasoning as `20260821000000_favorites_delta`: `(source_id, kind,
-- item_id)` is the identity, so an entry says outright what the title's state
-- now is — in progress at a position, finished, or *cleared* (neither). The
-- third case is why the payload cannot be "just the rows I have": removing an
-- entry from Continue watching has to reach the other devices, and an absence
-- cannot be told apart from "not sent". A cleared entry carries no state; the
-- server deletes the row.
--
-- Last write wins per title, by arrival order. Two devices watching the same
-- film on their own schedules therefore converge on whichever position was
-- pushed last — the only answer available without inventing a clock the clients
-- cannot agree on. Client clocks are deliberately not trusted: `updated_at` is
-- the server's `now()`.
--
-- Why entries for unknown sources are skipped rather than rejected
-- ----------------------------------------------------------------
-- A device's watch state is only meaningful for a source that exists in the
-- same profile. That can transiently fail to hold: the panel deletes a source
-- while the device is offline, so its next automatic watch push still names it.
-- Rejecting the batch would make *all* progress sync fail until the next pull
-- prunes the source list, and the client would retry a payload that can never
-- succeed. The insert joins `sources` on `(id, owner, profile_id)`, so a foreign
-- or vanished source simply contributes nothing — no data leaves the account,
-- and no error names a source id.
--
-- Compatibility
-- -------------
-- Purely additive. An older client never reads or writes `watch_state`; it
-- keeps its local progress exactly as before. `push_watch_delta` is a new name,
-- so no overload ambiguity with the existing push RPCs.
--
-- Sizing: one entry is ~120 bytes, a realistic profile holds hundreds to a few
-- thousand titles. The per-call ceiling (20000) exists to bound one request,
-- the per-profile ceiling (200000) to bound storage; both are far above real
-- use and mirror the favorites caps.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------

create table if not exists public.watch_state (
  profile_id  uuid    not null,
  owner       uuid    not null,
  source_id   uuid    not null,
  kind        text    not null,
  item_id     text    not null,
  position_ms bigint  not null default 0,
  duration_ms bigint  not null default 0,
  watched     boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (profile_id, source_id, kind, item_id)
);

-- Composite parent keys, following `20260727000000_tenant_isolation`: a row's
-- owner is structurally forced to equal the profile's and the source's, so a
-- cross-tenant child is unrepresentable rather than merely unwritten by the
-- current call sites. `profiles (id, owner)` and `sources (id, owner)` are
-- unique there; the guards below keep this file re-runnable.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'watch_state_profile_owner_fkey'
       and conrelid = 'public.watch_state'::regclass
  ) then
    alter table public.watch_state
      add constraint watch_state_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;

  -- Deleting a source in the panel deletes the progress that only described
  -- it: the ids inside a source are provider-scoped, so the rows could never
  -- match a re-added source anyway.
  if not exists (
    select 1 from pg_constraint
     where conname = 'watch_state_source_owner_fkey'
       and conrelid = 'public.watch_state'::regclass
  ) then
    alter table public.watch_state
      add constraint watch_state_source_owner_fkey
      foreign key (source_id, owner) references public.sources(id, owner)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'watch_state_kind_check'
       and conrelid = 'public.watch_state'::regclass
  ) then
    -- Live has no timeline; seasons are containers. Only titles a player can
    -- resume carry state.
    alter table public.watch_state
      add constraint watch_state_kind_check
      check (kind in ('movie', 'series', 'episode'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'watch_state_metrics_check'
       and conrelid = 'public.watch_state'::regclass
  ) then
    alter table public.watch_state
      add constraint watch_state_metrics_check
      check (position_ms >= 0 and duration_ms >= 0 and length(item_id) between 1 and 512);
  end if;
end $$;

create index if not exists watch_state_profile_updated_idx
  on public.watch_state(profile_id, updated_at desc);

-- ---------------------------------------------------------------------------
-- 2. RLS — devices and the panel read; only the definer RPC writes.
-- ---------------------------------------------------------------------------

alter table public.watch_state enable row level security;

drop policy if exists watch_state_select on public.watch_state;
create policy watch_state_select on public.watch_state
  for select using (owner = auth.uid() or owner = public.current_device_owner());

-- No insert/update/delete policy on purpose: `push_watch_delta` is the single
-- write path (see the RPC below). Table privileges are trimmed to match, so an
-- accidental policy added later is not immediately exploitable — the same
-- two-layer posture as the five RPC-only tables in the tenant-isolation
-- migration.
revoke insert, update, delete, truncate, references, trigger
  on public.watch_state from anon, authenticated;
grant select on public.watch_state to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Delta push
-- ---------------------------------------------------------------------------

create or replace function public.push_watch_delta(
  p_entries jsonb,
  p_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  payload jsonb := coalesce(p_entries, '[]'::jsonb);
  -- One call carries the outbox, which the client chunks at 500; this ceiling
  -- only bounds a hand-made request.
  max_entries constant int := 20000;
  max_rows    constant int := 200000;
  stored_rows bigint;
begin
  if o is null then
    raise exception 'only a paired device can push watch state';
  end if;

  if jsonb_typeof(payload) <> 'array' then
    raise exception 'iptvs: watch state payload must be a JSON array'
      using errcode = 'check_violation';
  end if;
  if jsonb_array_length(payload) > max_entries then
    raise exception 'iptvs: watch state payload too large (max % entries)', max_entries
      using errcode = 'check_violation';
  end if;

  -- Shares the 'push' bucket with every other push, exactly like the favorites
  -- delta: auto-pushing must not buy a larger budget by sending smaller bodies.
  perform public.check_push_rate('push', 30, interval '1 minute');

  if not exists (
    select 1 from public.profiles p where p.id = p_profile_id and p.owner = o
  ) then
    raise exception 'profile not found for this account';
  end if;

  -- Shape validation, all before any cast: the statements below parse the same
  -- values, and a raw cast error would echo the offending row.
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where jsonb_typeof(e) <> 'object'
  ) then
    raise exception 'iptvs: each watch state entry must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'source_id') is null
        or (e ->> 'source_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then
    raise exception 'iptvs: watch state source id must be a UUID'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'kind') is null
        or (e ->> 'kind') not in ('movie', 'series', 'episode')
  ) then
    raise exception 'iptvs: watch state kind invalid'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'item_id') is null
        or length(e ->> 'item_id') not between 1 and 512
  ) then
    raise exception 'iptvs: watch state item id invalid'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'position_ms') is not null
       and (e ->> 'position_ms') !~ '^[0-9]{1,15}$'
  ) or exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'duration_ms') is not null
       and (e ->> 'duration_ms') !~ '^[0-9]{1,15}$'
  ) then
    raise exception 'iptvs: watch state position invalid'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e -> 'watched') is not null
       and jsonb_typeof(e -> 'watched') <> 'boolean'
  ) then
    raise exception 'iptvs: watch state watched flag invalid'
      using errcode = 'check_violation';
  end if;

  -- Cleared entries first: "no position and not watched" means the title has no
  -- state left. If a malformed payload ever carried both shapes for one key,
  -- the upsert below wins, which is the less destructive of the two readings.
  delete from public.watch_state w
   using jsonb_array_elements(payload) e
   where w.profile_id = p_profile_id
     and w.owner = o
     and w.source_id = (e ->> 'source_id')::uuid
     and w.kind = e ->> 'kind'
     and w.item_id = e ->> 'item_id'
     and e ->> 'kind' in ('movie', 'series', 'episode')
     and coalesce(e ->> 'watched', 'false')::boolean = false
     and coalesce(nullif(e ->> 'position_ms', ''), '0')::bigint <= 0;

  insert into public.watch_state
    (profile_id, owner, source_id, kind, item_id, position_ms, duration_ms,
     watched, updated_at)
  select p_profile_id,
         o,
         s.id,
         e ->> 'kind',
         e ->> 'item_id',
         coalesce(nullif(e ->> 'position_ms', ''), '0')::bigint,
         coalesce(nullif(e ->> 'duration_ms', ''), '0')::bigint,
         coalesce((e ->> 'watched')::boolean, false),
         now()
    from jsonb_array_elements(payload) e
    join public.sources s
      on s.id = (e ->> 'source_id')::uuid
     and s.owner = o
     and s.profile_id = p_profile_id
   where e ->> 'kind' in ('movie', 'series', 'episode')
     and (coalesce((e ->> 'watched')::boolean, false)
          or coalesce(nullif(e ->> 'position_ms', ''), '0')::bigint > 0)
  on conflict (profile_id, source_id, kind, item_id) do update
        set position_ms = excluded.position_ms,
            duration_ms = excluded.duration_ms,
            watched = excluded.watched,
            updated_at = now()
      where public.watch_state.owner = o
        and public.watch_state.profile_id = p_profile_id;

  -- Storage ceiling, checked after the write so it covers the whole profile
  -- rather than this batch. A raise rolls the statement back with it.
  select count(*) into stored_rows
    from public.watch_state w
   where w.profile_id = p_profile_id;
  if stored_rows > max_rows then
    raise exception 'iptvs: too much watch state (max % entries)', max_rows
      using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.push_watch_delta(jsonb, uuid) from public, anon;
grant execute on function public.push_watch_delta(jsonb, uuid) to authenticated;
