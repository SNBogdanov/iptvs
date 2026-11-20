-- Watch state: a display snapshot of the title (name, year, poster).
--
-- Why denormalise
-- ---------------
-- The cloud holds no catalogue. `watch_state.item_id` is the provider's own id
-- inside a source (an Xtream `stream_id`, a Stalker `cmd`, an M3U locator hash),
-- and the human-readable side of it lives in the device's SQLite mirror
-- (`media_items`) — a 2000-page catalogue that is not synchronised, and should
-- not be. So a row out of context is "73776, 20.8 %": enough for another
-- device, which has its own catalogue and can resolve the id, but not enough for
-- the web panel, which has none.
--
-- These three columns are a *snapshot*, not a source of truth: the device sends
-- what its catalogue knows at push time and the panel renders that. A renamed
-- title, a new poster or a corrected year arrives with the next push of that
-- title's state. No joins, no catalogue mirror, nothing to keep in step.
--
-- Bounds are the same shape the rest of the schema uses, and `poster` must be
-- http(s): the panel puts it in an `<img src>`, and a snapshot column is not a
-- place to accept arbitrary schemes.
--
-- **A push never blanks what it does not know.** Title/year/poster are preserved
-- field-wise when the incoming value is empty, exactly like
-- `merge_preserving_nonempty` on `sources.fields`. Two reasons: a device that
-- was offline when the catalogue refreshed may no longer resolve an id, and an
-- older app build (which sends no metadata at all) must not erase what a newer
-- one stored.

alter table public.watch_state
  add column if not exists title  text not null default '',
  add column if not exists year   text not null default '',
  add column if not exists poster text not null default '';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'watch_state_meta_check'
       and conrelid = 'public.watch_state'::regclass
  ) then
    alter table public.watch_state
      add constraint watch_state_meta_check
      check (
        length(title) between 0 and 512
        and length(year) between 0 and 32
        and length(poster) between 0 and 2048
        and (poster = '' or poster ~* '^https?://')
      );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- push_watch_delta: same signature, same delta semantics; each entry may now
-- carry `title`/`year`/`poster`.
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
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where length(coalesce(e ->> 'title', '')) > 512
        or length(coalesce(e ->> 'year', '')) > 32
        or length(coalesce(e ->> 'poster', '')) > 2048
        or (coalesce(e ->> 'poster', '') <> ''
            and (e ->> 'poster') !~* '^https?://')
  ) then
    raise exception 'iptvs: watch state metadata invalid'
      using errcode = 'check_violation';
  end if;

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
     watched, updated_at, title, year, poster)
  select p_profile_id,
         o,
         s.id,
         e ->> 'kind',
         e ->> 'item_id',
         coalesce(nullif(e ->> 'position_ms', ''), '0')::bigint,
         coalesce(nullif(e ->> 'duration_ms', ''), '0')::bigint,
         coalesce((e ->> 'watched')::boolean, false),
         now(),
         coalesce(e ->> 'title', ''),
         coalesce(e ->> 'year', ''),
         coalesce(e ->> 'poster', '')
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
            updated_at = now(),
            -- Field-preserving, like sources.fields: an empty value means "this
            -- device does not know", never "clear what is stored".
            title = case when excluded.title <> ''
                         then excluded.title else public.watch_state.title end,
            year = case when excluded.year <> ''
                        then excluded.year else public.watch_state.year end,
            poster = case when excluded.poster <> ''
                          then excluded.poster else public.watch_state.poster end
      where public.watch_state.owner = o
        and public.watch_state.profile_id = p_profile_id;

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
