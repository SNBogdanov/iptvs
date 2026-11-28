-- Per-device app settings backup.
--
-- Why this table exists
-- ---------------------
-- A device's sources/profile data already sync through `sources`, `favorites`
-- and `watch_state`. Its **app preferences** (player controls, seek step,
-- clock, auto-play, volume, proxy, window placement, ...) live only in the
-- device keychain, so reinstalling the app loses them even after the device is
-- paired again. This table stores that key/value map against a stable
-- hardware-derived key, so the same physical device can fetch it back.
--
-- Why a separate table and not `devices.settings`
-- -----------------------------------------------
-- `devices.device_uid` is the anonymous auth user id. A reinstall creates a
-- new anonymous user and therefore a new `devices` row; a settings column
-- there would be unreachable. The key here is supplied by the client and is
-- derived from a stable platform id (Android `ANDROID_ID`, Windows
-- `MachineGuid`), never the raw id: the client sends a SHA-256 hex digest.
--
-- Ownership and access
-- --------------------
-- `owner` is the account the device is paired to (`current_device_owner()`),
-- so a device can only read/write its own account's backups. The table has
-- RLS enabled with **no policies** and no table grants; the two RPCs below are
-- the only path. The key is a 64-character lowercase hex digest; settings must
-- be a JSON object and are capped at 64 KiB (a full preference map is a few
-- hundred bytes).
--
-- Compatibility: purely additive. Older clients never call these RPCs and keep
-- their local settings exactly as before.

create table if not exists public.device_settings (
  owner      uuid not null references auth.users(id) on delete cascade,
  device_key text not null,
  settings   jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner, device_key),
  constraint device_settings_key_format check (device_key ~ '^[0-9a-f]{64}$'),
  constraint device_settings_object check (jsonb_typeof(settings) = 'object')
);

alter table public.device_settings enable row level security;

-- Only the SECURITY DEFINER functions below may touch it.
revoke all on table public.device_settings from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Read: the caller's account + hardware key. Returns null when this device has
-- never saved settings.
-- ---------------------------------------------------------------------------

create or replace function public.get_device_settings(p_device_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can read device settings';
  end if;
  if p_device_key is null or p_device_key !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid device key';
  end if;

  return (
    select jsonb_build_object(
             'settings', ds.settings,
             'updated_at', ds.updated_at
           )
      from public.device_settings ds
     where ds.owner = o
       and ds.device_key = p_device_key
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Write: upsert the whole map, last write wins by server `now()`.
-- ---------------------------------------------------------------------------

create or replace function public.push_device_settings(
  p_device_key text,
  p_settings jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  clean jsonb := coalesce(p_settings, '{}'::jsonb);
begin
  if o is null then
    raise exception 'only a paired device can save device settings';
  end if;
  if p_device_key is null or p_device_key !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid device key';
  end if;
  if jsonb_typeof(clean) <> 'object' then
    raise exception 'device settings must be a JSON object';
  end if;
  if octet_length(clean::text) > 65536 then
    raise exception 'device settings are too large';
  end if;

  insert into public.device_settings (owner, device_key, settings, updated_at)
  values (o, p_device_key, clean, now())
  on conflict (owner, device_key) do update
    set settings = excluded.settings,
        updated_at = now();
end;
$$;

revoke all on function public.get_device_settings(text) from public, anon;
revoke all on function public.push_device_settings(text, jsonb) from public, anon;
grant execute on function public.get_device_settings(text) to authenticated;
grant execute on function public.push_device_settings(text, jsonb) to authenticated;
