-- The version handshake: the replay must leave exactly one row at the app's
-- expected version, and the RPC must be readable by the anonymous role (the
-- app asks before a session exists).

begin;

select plan(3);

select has_table('public', 'app_schema', 'app_schema exists');
select is(
  (select version from public.app_schema where id = 1),
  2026112801::bigint,
  'the replayed schema reports the app version'
);

set local role anon;
select is(
  public.get_schema_version(),
  2026112801::bigint,
  'anon can read the public schema version'
);

select * from finish();
rollback;
