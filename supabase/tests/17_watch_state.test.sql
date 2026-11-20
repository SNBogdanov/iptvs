-- push_watch_delta: the per-title delta behind automatic VOD progress sync.
--
-- The properties that matter:
--   1. a title carries one state, and a later push replaces it (position →
--      position, position → watched, anything → cleared);
--   2. "cleared" is a real value that deletes the row — absence cannot express
--      it, exactly like favorites' add/remove;
--   3. an entry naming a source that is not in this profile is skipped, not an
--      error: a device that was offline when the panel removed the source must
--      not have all of its progress sync fail until the next pull;
--   4. the panel owner can read the rows, another account cannot;
--   5. deleting the source cascades its progress away (ids are provider-scoped,
--      so they could never match a re-added source).

begin;

select plan(17);

set local role authenticated;

-- ── guards (before pairing) ────────────────────────────────────────────────

select throws_ok(
  format('select public.push_watch_delta(%L::jsonb, %L::uuid)',
         '[]'::jsonb, gen_random_uuid()),
  null, null,
  'an unpaired caller cannot push watch state'
);

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');
select test.jwt(:'device_a'::uuid, true);
select public.set_device_profile(:'profile_a_id'::uuid);

-- The source has to exist in the profile: `watch_state` is keyed by
-- (source_id, owner) with a composite FK, unlike favorites' free-form array.
select gen_random_uuid() as source_a_id \gset
select public.push_sources(
  jsonb_build_array(jsonb_build_object(
    'id', :'source_a_id'::uuid,
    'kind', 'm3u',
    'label', 'watch state',
    'fields', jsonb_build_object(),
    'settings', jsonb_build_object(),
    'position', 0
  )),
  :'profile_a_id'::uuid
);

-- ── guards ─────────────────────────────────────────────────────────────────

select throws_ok(
  format('select public.push_watch_delta(%L::jsonb, %L::uuid)',
         jsonb_build_array(jsonb_build_object(
           'source_id', :'source_a_id'::uuid,
           'kind', 'live', 'item_id', 'ch1',
           'position_ms', 1000, 'duration_ms', 2000, 'watched', false
         )),
         :'profile_a_id'::uuid),
  null, 'iptvs: watch state kind invalid',
  'a kind without a timeline (live) is rejected'
);

select throws_ok(
  format('select public.push_watch_delta(%L::jsonb, %L::uuid)',
         jsonb_build_array(jsonb_build_object(
           'source_id', 'not-a-uuid',
           'kind', 'movie', 'item_id', 'm1',
           'position_ms', 1000, 'duration_ms', 2000, 'watched', false
         )),
         :'profile_a_id'::uuid),
  null, 'iptvs: watch state source id must be a UUID',
  'a non-UUID source id is rejected before any cast'
);

-- ── one state per title ────────────────────────────────────────────────────

select lives_ok(
  format('select public.push_watch_delta(%L::jsonb, %L::uuid)',
         jsonb_build_array(jsonb_build_object(
           'source_id', :'source_a_id'::uuid,
           'kind', 'movie', 'item_id', 'm1',
           'position_ms', 60000, 'duration_ms', 3600000, 'watched', false
         )),
         :'profile_a_id'::uuid),
  'a paired device can push an in-progress entry'
);

select ok(
  exists (
    select 1 from public.watch_state
     where profile_id = :'profile_a_id'::uuid
       and source_id = :'source_a_id'::uuid
       and kind = 'movie' and item_id = 'm1'
       and position_ms = 60000 and duration_ms = 3600000 and watched = false
  ),
  'the position landed under the profile'
);

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'm1',
    'position_ms', 90000, 'duration_ms', 3600000, 'watched', false
  )),
  :'profile_a_id'::uuid
);

select is(
  (select position_ms from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'm1'),
  90000::bigint,
  'a later position replaces the earlier one (last write wins)'
);

select is(
  (select count(*)::int from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'm1'),
  1,
  'repeated pushes still leave exactly one row per title'
);

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'm1',
    'position_ms', 0, 'duration_ms', 0, 'watched', true
  )),
  :'profile_a_id'::uuid
);

select is(
  (select watched::text || ':' || position_ms::text from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'm1'),
  'true:0',
  'finishing a title replaces the resume point with the watched mark'
);

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'm1',
    'position_ms', 0, 'duration_ms', 0, 'watched', false
  )),
  :'profile_a_id'::uuid
);

select ok(
  not exists (
    select 1 from public.watch_state
     where profile_id = :'profile_a_id'::uuid and item_id = 'm1'
  ),
  'a cleared entry deletes the row — absence cannot express a removal'
);

-- ── a source that is not in this profile ───────────────────────────────────

select lives_ok(
  format('select public.push_watch_delta(%L::jsonb, %L::uuid)',
         jsonb_build_array(jsonb_build_object(
           'source_id', gen_random_uuid(),
           'kind', 'movie', 'item_id', 'stray',
           'position_ms', 1000, 'duration_ms', 2000, 'watched', false
         )),
         :'profile_a_id'::uuid),
  'an entry for an unknown source is skipped, not an error'
);

select ok(
  not exists (
    select 1 from public.watch_state
     where profile_id = :'profile_a_id'::uuid and item_id = 'stray'
  ),
  'the skipped entry stored nothing'
);

-- A row for the read checks below (the previous one was cleared).
select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'episode', 'item_id', 'e1',
    'position_ms', 120000, 'duration_ms', 1800000, 'watched', false
  )),
  :'profile_a_id'::uuid
);

-- ── the display snapshot ───────────────────────────────────────────────────
--
-- The cloud has no catalogue, so title/year/artwork travel with the state. The
-- property that matters is field-preserving: a push that does not know a value
-- (an older build, or one whose catalogue no longer holds the id) must not
-- blank what another device stored.

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'meta1',
    'position_ms', 1000, 'duration_ms', 2000, 'watched', false,
    'title', 'Probe title', 'year', '2026',
    'poster', 'https://example.com/p.jpg',
    'backdrop', 'https://example.com/w.jpg'
  )),
  :'profile_a_id'::uuid
);
select is(
  (select title || '|' || year || '|' || poster || '|' || backdrop from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'meta1'),
  'Probe title|2026|https://example.com/p.jpg|https://example.com/w.jpg',
  'a push can carry the display snapshot'
);

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'meta1',
    'position_ms', 2000, 'duration_ms', 2000, 'watched', false
  )),
  :'profile_a_id'::uuid
);
select is(
  (select title || '|' || year || '|' || poster || '|' || backdrop from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'meta1'),
  'Probe title|2026|https://example.com/p.jpg|https://example.com/w.jpg',
  'a push without metadata preserves the stored snapshot'
);

select public.push_watch_delta(
  jsonb_build_array(jsonb_build_object(
    'source_id', :'source_a_id'::uuid,
    'kind', 'movie', 'item_id', 'meta1',
    'position_ms', 2000, 'duration_ms', 2000, 'watched', false,
    'title', 'Renamed', 'year', '', 'poster', '', 'backdrop', ''
  )),
  :'profile_a_id'::uuid
);
select is(
  (select title || '|' || year || '|' || poster || '|' || backdrop from public.watch_state
    where profile_id = :'profile_a_id'::uuid and item_id = 'meta1'),
  'Renamed|2026|https://example.com/p.jpg|https://example.com/w.jpg',
  'a new title wins while an unknown year/poster keep the stored values'
);

-- ── reads ──────────────────────────────────────────────────────────────────

select test.jwt(:'owner_a'::uuid, false);
select ok(
  exists (
    select 1 from public.watch_state
     where profile_id = :'profile_a_id'::uuid and item_id = 'e1'
  ),
  'the account that owns the profile can read its watch state'
);

select test.login_user() as owner_b \gset
select test.jwt(:'owner_b'::uuid, false);
select is(
  (select count(*)::int from public.watch_state
    where profile_id = :'profile_a_id'::uuid),
  0,
  'another account reads none of it'
);

-- ── cascade ────────────────────────────────────────────────────────────────

select test.jwt(:'device_a'::uuid, true);
-- A whole-set source push without the source deletes it, which is what a panel
-- removal looks like to the device.
select public.push_sources('[]'::jsonb, :'profile_a_id'::uuid);
select is(
  (select count(*)::int from public.watch_state
    where profile_id = :'profile_a_id'::uuid),
  0,
  'deleting the source cascades its watch state away'
);

select * from finish();
rollback;
