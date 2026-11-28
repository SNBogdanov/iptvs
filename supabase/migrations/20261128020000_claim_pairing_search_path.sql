-- Hardening: pin `claim_pairing_as_device` to an empty `search_path`.
--
-- Why this migration exists
-- -------------------------
-- `20261125000000_claim_pairing_from_device.sql` declared the function with
-- `set search_path = public`, which is the one SECURITY DEFINER function in
-- `public` that pins something other than the empty path. The pgTAP suite has
-- been asserting that property since the secrets store landed
-- (`supabase/tests/01_hardening.test.sql`, "every SECURITY DEFINER function in
-- public pins search_path to empty"), so `Database tests` has been red on every
-- push since that migration — the assertion is the only failing check.
--
-- The body needs no other change: every reference it makes outside
-- `pg_catalog` is already schema-qualified (`public.current_device_owner()`,
-- `auth.uid()`, `public.pairings`, `public.devices`), and `upper()`/`now()`
-- live in `pg_catalog`, which is always searched implicitly. Behavior is
-- therefore byte-for-byte the same; only the session's `search_path` inside the
-- definer changes.
--
-- Deliberately **no** `app_schema.version` bump: this adds no capability a
-- client can observe, and raising the version would make every 1.0.4 build
-- report "the server is newer, update the app" for a security-only fix.

create or replace function public.claim_pairing_as_device(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimer uuid := public.current_device_owner();
  caller  uuid := auth.uid();
  dev     uuid;
begin
  if caller is null or claimer is null then
    raise exception 'only a paired device can claim a device';
  end if;

  select device_uid into dev
    from public.pairings
    where code = upper(p_code)
      and claimed_by is null
      and expires_at > now()
    for update;

  if dev is null then
    raise exception 'invalid or expired code';
  end if;

  if dev = caller then
    raise exception 'a device cannot claim its own code';
  end if;

  insert into public.devices (device_uid, owner)
    values (dev, claimer)
    on conflict (device_uid) do update set owner = excluded.owner;

  update public.pairings set claimed_by = claimer where code = upper(p_code);
end;
$$;

comment on function public.claim_pairing_as_device(text) is
  'Claims a pairing code on behalf of the calling device''s account, so a paired '
  'phone can authorise a TV without a panel session.';

-- `anon` is named explicitly: Supabase's default privileges in `public` grant
-- EXECUTE on every new function to `anon`/`authenticated`/`service_role`, and
-- revoking from `public` alone leaves that explicit grant in place. The
-- function already refuses a caller without a session (`auth.uid()` is null),
-- so this is least privilege rather than a live hole — the same pair of grants
-- `get_device_settings`/`push_device_settings` carry.
revoke all on function public.claim_pairing_as_device(text) from public, anon;
grant execute on function public.claim_pairing_as_device(text) to authenticated;
