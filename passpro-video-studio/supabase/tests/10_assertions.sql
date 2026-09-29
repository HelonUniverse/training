-- SQL assertions for the Video Studio schema. Each block raises on failure.
\set ON_ERROR_STOP 1

create or replace function pg_temp.expect_error(p_sql text, p_fragment text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'EXPECTED ERROR containing "%" but statement succeeded: %', p_fragment, p_sql;
exception when others then
  if position(p_fragment in sqlerrm) = 0 then
    raise exception 'expected error containing "%", got: %', p_fragment, sqlerrm;
  end if;
end $$;

-- ---------------------------------------------------------------- seeds
do $$ begin
  assert (select count(*) from vs_series) = 1, 'one series';
  assert (select count(*) from vs_characters) = 3, 'three characters';
  assert (select count(*) from vs_assets where kind = 'location') = 1, 'one location';
  assert (select count(*) from vs_assets where kind = 'prop') = 6, 'six props';
  assert (select count(*) from vs_content_locks) = 4, 'four locks';
  assert (select value_numeric from vs_content_locks where concept = 'exam.scored_questions') = 85, '85 scored';
  assert (select value_numeric from vs_content_locks where concept = 'exam.pretest_questions') = 10, '10 pretest';
  assert (select value_numeric from vs_content_locks where concept = 'exam.time_limit_minutes') = 120, '120 minutes';
  assert (select count(*) from vs_content_locks where verification_status = 'VERIFIED') = 3, 'three VERIFIED';
  assert (select verification_status from vs_content_locks where concept = 'exam.passing_score_percent') = 'UNVERIFIED',
    '70% must stay UNVERIFIED';
  assert (select (value->>'max_cost_per_clip_usd')::numeric from vs_settings where key = 'budget') = 3, 'clip cap';
  assert (select (value->>'max_cost_per_episode_usd')::numeric from vs_settings where key = 'budget') = 30, 'episode cap';
  assert (select (value->>'max_daily_spend_usd')::numeric from vs_settings where key = 'budget') = 40, 'daily cap';
  assert (select (value->>'max_retry_budget_per_episode_usd')::numeric from vs_settings where key = 'budget') = 5, 'retry cap';
  assert (select (value->>'paid_providers_enabled')::boolean from vs_settings where key = 'generation') = false,
    'paid providers must default OFF';
  assert exists (select 1 from storage.buckets where id = 'video-studio' and not public), 'private bucket';
end $$;

-- a VERIFIED lock without provenance is rejected
select pg_temp.expect_error(
  $q$insert into vs_content_locks (scope_key, concept, statement, value_numeric, verification_status)
     values ('X', 'x', 'x', 1, 'VERIFIED')$q$, 'vs_content_locks_check');

-- ---------------------------------------------------------------- fixture episode
insert into vs_episodes (id, series_id, number, title, script, plan_hash)
select '10000000-0000-0000-0000-000000000001', id, 0, 'Test episode', 'x', 'hash-1' from vs_series;
insert into vs_scenes (id, episode_id, ord, heading)
values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 1, 'EXT');
insert into vs_clips (id, episode_id, scene_id, ord, duration_estimate_s, estimated_cost_usd, issues)
values
 ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001', 1, 10, 1.00, '[]'),
 ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001', 2, 10, 1.00,
  '[{"code":"CONTENT_CONFLICT","severity":"conflict","message":"90 vs 85"}]');

-- ---------------------------------------------------------------- RLS
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';   -- learner
do $$ begin
  assert (select count(*) from vs_series) = 0, 'learner must not see series';
  assert (select count(*) from vs_content_locks) = 0, 'learner must not see locks';
  assert (select count(*) from vs_cost_ledger) = 0, 'learner must not see ledger';
end $$;
select pg_temp.expect_error($q$insert into vs_series (slug, name) values ('hack', 'hack')$q$, 'row-level security');
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 5, 0)$q$, 'VS_FORBIDDEN');

set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';   -- admin
do $$ begin
  assert (select count(*) from vs_series) = 1, 'admin sees series';
  assert (select count(*) from vs_clips) = 2, 'admin sees clips';
end $$;
-- admins edit the bible directly…
update vs_characters set continuity_notes = continuity_notes where slug = 'dona-poliza';
-- …but cannot write production rows directly (no hand-written approvals,
-- no clearing of CONTENT CONFLICT issues). RLS silently filters UPDATE/DELETE:
update vs_episodes set approval = '{"plan_hash":"hash-1","authorized_max_usd":999}'::jsonb;
update vs_clips set issues = '[]'::jsonb;
select pg_temp.expect_error(
  $q$insert into vs_episodes (series_id, number, title) select id, 99, 'x' from vs_series$q$, 'row-level security');
reset role;
do $$ begin
  assert (select approval from vs_episodes where id = '10000000-0000-0000-0000-000000000001') is null, 'approval not writable by clients';
  assert (select jsonb_array_length(issues) from vs_clips where id = '30000000-0000-0000-0000-000000000002') = 1, 'issues not writable by clients';
end $$;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
-- admins cannot write money rows or reserve directly: only the server can
select pg_temp.expect_error(
  $q$insert into vs_cost_ledger (episode_id, entry_type, category, amount_usd)
     values ('10000000-0000-0000-0000-000000000001', 'actual', 'initial', 1)$q$, 'row-level security');
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'k0', false, true, '{}')$q$,
  'permission denied');

-- approval: blocked by the unresolved CONTENT CONFLICT on clip 2
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 5, 1)$q$, 'VS_CONTENT_BLOCKED');
reset role;
-- an acknowledged CONFLICT still blocks: conflicts must be fixed, not waved through
update vs_clips set issues = '[{"code":"CONTENT_CONFLICT","severity":"conflict","acknowledged":true}]'
 where id = '30000000-0000-0000-0000-000000000002';
set role authenticated;
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 5, 1)$q$, 'VS_CONTENT_BLOCKED');
reset role;
-- fixing the script clears the conflict; an acknowledged REVIEW item does not block
update vs_clips set issues = '[{"code":"UNLOCKED_NUMERIC_CLAIM","severity":"review","acknowledged":true}]'
 where id = '30000000-0000-0000-0000-000000000002';
set role authenticated;
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'stale-hash', 5, 1)$q$, 'VS_PLAN_CHANGED');
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 31, 1)$q$, 'per-episode limit');
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 5, 6)$q$, 'retry budget');
select pg_temp.expect_error(
  $q$select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 1, 1)$q$, 'below the estimate');
select vs_approve_episode('10000000-0000-0000-0000-000000000001', 'hash-1', 5, 1);
reset role;

do $$ begin
  assert (select status from vs_episodes where id = '10000000-0000-0000-0000-000000000001') = 'APPROVED', 'episode approved';
  assert (select count(*) from vs_clips where status = 'APPROVED') = 2, 'clips approved';
  assert (select count(*) from vs_cost_ledger where entry_type = 'authorization') = 2, 'two authorizations';
end $$;

-- ---------------------------------------------------------------- reservations (server)
set role service_role;
-- paid providers are disabled by default
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'minimax', 'MiniMax-H3', 1, 'paid-1', false, false, '{}')$q$,
  'VS_PAID_DISABLED');
-- per-clip cap
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 3.5, 'big-1', false, true, '{}')$q$,
  'VS_BUDGET_CLIP');

create temp table t_job as
select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'job-1', false, true, '{}') as id;
-- idempotent: same key → same job, no second reservation
do $$ declare j uuid; begin
  j := vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'job-1', false, true, '{}');
  assert j = (select id from t_job), 'same key returns same job';
  assert (select count(*) from vs_cost_ledger where entry_type = 'reservation') = 1, 'single reservation';
  assert (select status from vs_clips where id = '30000000-0000-0000-0000-000000000001') = 'GENERATING', 'generating';
end $$;

select vs_settle_job((select id from t_job), 'SUCCEEDED', 0.8, '{"output_seconds": 8}');
select vs_settle_job((select id from t_job), 'SUCCEEDED', 0.8, '{"output_seconds": 8}');  -- no double settle
do $$ begin
  assert vs_committed('10000000-0000-0000-0000-000000000001') = 0.8, 'committed = actual after settle';
  assert (select count(*) from vs_cost_ledger where entry_type = 'actual') = 1, 'one actual';
end $$;

-- ledger is append-only
reset role;
select pg_temp.expect_error($q$update vs_cost_ledger set amount_usd = 0$q$, 'append-only');
select pg_temp.expect_error($q$delete from vs_cost_ledger$q$, 'append-only');
update vs_clips set status = 'COMPLETE' where id = '30000000-0000-0000-0000-000000000001';
set role service_role;

-- regeneration: first one fits the $1 retry budget; the second needs authorization
create temp table t_regen as
select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'regen-1', true, true, '{}') as id;
select vs_settle_job((select id from t_regen), 'SUCCEEDED', 1, null);
reset role;
update vs_clips set status = 'COMPLETE' where id = '30000000-0000-0000-0000-000000000001';
set role service_role;
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'regen-2', true, true, '{}')$q$,
  'VS_NEEDS_AUTHORIZATION');
reset role;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select vs_authorize_regeneration('30000000-0000-0000-0000-000000000001', 1);
reset role;
set role service_role;
select vs_reserve_generation('30000000-0000-0000-0000-000000000001', 'mock', 'm', 1, 'regen-2', true, true, '{}');

-- daily limit
reset role;
update vs_settings set value = jsonb_set(value, '{max_daily_spend_usd}', '3.5') where key = 'budget';
set role service_role;
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000002', 'mock', 'm', 1, 'daily-1', false, true, '{}')$q$,
  'VS_BUDGET_DAILY');
reset role;
update vs_settings set value = jsonb_set(value, '{max_daily_spend_usd}', '40') where key = 'budget';

-- editing the plan after approval voids it
update vs_episodes set plan_hash = 'hash-2' where id = '10000000-0000-0000-0000-000000000001';
set role service_role;
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000002', 'mock', 'm', 1, 'after-edit', false, true, '{}')$q$,
  'VS_NOT_APPROVED');

-- kill switch
reset role;
update vs_episodes set plan_hash = 'hash-1' where id = '10000000-0000-0000-0000-000000000001';
update vs_settings set value = jsonb_set(value, '{enabled}', 'false') where key = 'generation';
set role service_role;
select pg_temp.expect_error(
  $q$select vs_reserve_generation('30000000-0000-0000-0000-000000000002', 'mock', 'm', 1, 'killed', false, true, '{}')$q$,
  'VS_DISABLED');
reset role;
update vs_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'generation';

-- ---------------------------------------------------------------- render queue
insert into vs_generation_jobs (id, job_type, episode_id, provider, idempotency_key, status)
values ('40000000-0000-0000-0000-000000000001', 'render', '10000000-0000-0000-0000-000000000001',
        'ffmpeg', 'render-1', 'QUEUED');
set role service_role;
do $$ declare j vs_generation_jobs; k vs_generation_jobs; begin
  j := vs_claim_render_job('worker-a');
  assert j.id = '40000000-0000-0000-0000-000000000001' and j.status = 'RUNNING', 'claimed';
  k := vs_claim_render_job('worker-b');
  assert k.id is null, 'nothing left to claim';
end $$;
select vs_complete_render_job('40000000-0000-0000-0000-000000000001', true, 'renders/x.mp4');
reset role;
do $$ begin
  assert (select status from vs_episodes where id = '10000000-0000-0000-0000-000000000001') = 'RENDERED', 'rendered';
  -- existing PassPro tables untouched
  assert (select count(*) from public.videos) = 0, 'videos untouched';
end $$;

select 'all assertions passed' as result;
