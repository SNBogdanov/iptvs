-- Pairing a device from another **paired device** (a phone authorises a TV).
--
-- Until now the only way to turn a device's pairing code into a `devices` row
-- was `claim_pairing`, which requires `is_real_user()` — i.e. a signed-in web
-- panel. The scenario this adds: the phone is already paired (it has a
-- `devices` row binding its anonymous uid to the account), the TV is freshly
-- installed and shows a code, and the phone approves that code from inside the
-- app. No panel session on the phone, nothing typed into a browser.
--
-- It is the same authority `claim_pairing` gives a panel account, scoped to the
-- account this device already belongs to:
--   * the claimer is the caller's account (`current_device_owner()`), so a
--     device can only ever add devices to its own account;
--   * the pairings row keeps its single-use/expiry semantics — the
--     `pairings_validate` trigger only permits the `claimed_by` write, exactly
--     as `claim_pairing` performs it;
--   * a device cannot claim its own code (the TV's poll would then report a
--     pairing that never happened).
--
-- Note the deliberate absence of a per-device capability flag: any paired
-- device can add devices to its account, which is what "my phone authorises my
-- TV" means. The panel can revoke any device (deleting the row), and an
-- unwanted pairing is visible there as a new device.

create or replace function public.claim_pairing_as_device(p_code text)
returns void
language plpgsql
security definer
set search_path = public
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

revoke all on function public.claim_pairing_as_device(text) from public;
grant execute on function public.claim_pairing_as_device(text) to authenticated;
