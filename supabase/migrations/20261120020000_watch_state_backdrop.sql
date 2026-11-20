-- Watch state: keep the backdrop too.
--
-- The panel renders history thumbnails in **landscape** (16:9), which is what
-- the app's own landscape cards use, and a 2:3 poster cropped to 16:9 loses
-- most of the picture. The catalogue usually has both images: 119 of the 121
-- titles in the reference library carry a backdrop, so the row stores both and
-- the panel prefers the backdrop, falling back to the poster when a provider
-- has none.
--
-- Same rules as the other snapshot fields: bounded, http(s)-only, and
-- field-preserving on push (empty means "this device does not know", never
-- "clear what is stored").

alter table public.watch_state
  add column if not exists backdrop text not null default '';

do $$
begin
  if exists (
    select 1 from pg_constraint
     where conname = 'watch_state_meta_check'
       and conrelid = 'public.watch_state'::regclass
  ) then
    alter table public.watch_state drop constraint watch_state_meta_check;
  end if;

  alter table public.watch_state
    add constraint watch_state_meta_check
    check (
      length(title) between 0 and 512
      and length(year) between 0 and 32
      and length(poster) between 0 and 2048
      and (poster = '' or poster ~* '^https?://')
      and length(backdrop) between 0 and 2048
      and (backdrop = '' or backdrop ~* '^https?://')
    );
end $$;

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
        or length(coalesce(e ->> 'backdrop', '')) > 2048
        or (coalesce(e ->> 'poster', '') <> ''
            and (e ->> 'poster') !~* '^https?://')
        or (coalesce(e ->> 'backdrop', '') <> ''
            and (e ->> 'backdrop') !~* '^https?://')
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
     watched, updated_at, title, year, poster, backdrop)
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
         coalesce(e ->> 'poster', ''),
         coalesce(e ->> 'backdrop', '')
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
            title = case when excluded.title <> ''
                         then excluded.title else public.watch_state.title end,
            year = case when excluded.year <> ''
                        then excluded.year else public.watch_state.year end,
            poster = case when excluded.poster <> ''
                          then excluded.poster else public.watch_state.poster end,
            backdrop = case when excluded.backdrop <> ''
                            then excluded.backdrop else public.watch_state.backdrop end
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
