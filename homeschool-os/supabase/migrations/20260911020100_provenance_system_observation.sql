-- =============================================================================
-- 0097  Saying where diagnostic evidence actually came from
-- =============================================================================
-- 0096 added `human_confirmed_system_observation`. This is everything that reads
-- or writes it, in its own transaction because PostgreSQL will not let a
-- transaction use an enum value it just created.
--
-- FOUR CHANGES, and the third is the one that would have gone wrong quietly.
--
--   1. `confirm_diagnostic_observation` writes the new label.
--   2. `app.compute_skill_state` counts it as a human-origin observation, which
--      it is. WITHOUT THIS THE PATCH WOULD SILENTLY BREAK THE PROFILE: that
--      count is the `corroborated` threshold, so relabelling the evidence and
--      forgetting the counter would make a parent's confirmed diagnostic
--      evidence stop counting as hers, and a child's sufficiency would quietly
--      fall from `corroborated` to `supported` with nothing to explain why.
--   3. Existing rows are relabelled, with the append-only trigger suspended for
--      exactly that statement and its restoration verified.
--   4. A check constraint and two invariants make the old label unreachable for
--      diagnostic evidence rather than merely unwritten.
--
-- THE RULE VERSION DOES NOT MOVE. `app.recompute_rule_version()` stays at
-- 2026-09-09.2 on purpose. No child's state is computed differently by any of
-- this: the relabelled rows were already `usable` (0085 classifies only
-- `ai_proposed_unreviewed` as unreviewed) and were already counted as
-- human-origin, and change 2 keeps them counted. The migration proves that
-- rather than asserting it - it recomputes every affected pair before and after
-- and refuses to finish if any state, sufficiency or evidence count moved.
-- Bumping the version would claim a child's history had been recomputed when it
-- had not.
-- =============================================================================

-- --- 1. the evidence a parent confirms is a system observation ---------------

create or replace function public.confirm_diagnostic_observation(
  p_observation uuid, p_skill_state text default null, p_note text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_o public.diagnostic_observations; v_ss uuid; v_ev uuid; v_org uuid; v_on date;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into v_o from public.diagnostic_observations o where o.id = p_observation;
  if not found or not app.can_student_action(v_o.student_id, 'skill', 'update') then
    raise exception 'not permitted' using errcode = 'insufficient_privilege';
  end if;
  if v_o.outcome <> 'demonstrated' then
    raise exception 'only an observation in which a child demonstrated something becomes evidence'
      using errcode = 'check_violation';
  end if;
  if v_o.review_status <> 'pending' then
    raise exception 'this observation has already been reviewed' using errcode = 'check_violation';
  end if;

  select st.primary_organization_id into v_org from public.students st where st.id = v_o.student_id;
  select ss.id into v_ss from public.student_skills ss
   where ss.student_id = v_o.student_id and ss.skill_id = v_o.skill_id;
  if v_ss is null then
    insert into public.student_skills (student_id, skill_id, organization_id, source_type,
             record_provenance, evidence_source, skill_state, created_by)
    values (v_o.student_id, v_o.skill_id, v_org, 'observation', 'human_entered',
            'diagnostic_session', 'unknown', auth.uid())
    returning id into v_ss;
  end if;

  v_on := v_o.observed_at::date;
  insert into public.student_skill_events (student_skill_id, student_id, skill_id, organization_id,
           occurred_on, evidence_note, skill_state, source_type, evidence_source,
           record_provenance, created_by)
  values (v_ss, v_o.student_id, v_o.skill_id, v_org, v_on, coalesce(p_note, v_o.note),
          nullif(p_skill_state, '')::app.skill_state, 'observation', 'diagnostic_session',
          'human_confirmed_system_observation', auth.uid())
  returning id into v_ev;

  update public.diagnostic_observations o
     set review_status = 'confirmed', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = p_note, promoted_event_id = v_ev
   where o.id = p_observation;

  return public.recompute_student_skill(v_o.student_id, v_o.skill_id)
         || jsonb_build_object('observation', p_observation, 'evidence_event', v_ev);
end $fn$;

-- --- 2. and it is still evidence a human stands behind ----------------------
-- The `corroborated` threshold asks for at least one observation a person
-- originated or confirmed. A diagnostic observation a parent reviewed is exactly
-- that, and it was being counted before this patch under the old label. Adding
-- the new label here is what keeps the answer identical.

create or replace function app.compute_skill_state(p_student uuid, p_skill uuid)
returns jsonb
language plpgsql stable security invoker set search_path = '' as $fn$
declare
  v_n int; v_occasions int; v_sources int; v_human int;
  v_unreviewed int; v_undecided int; v_rejected int; v_retracted int;
  v_asserting int; v_distinct int;
  v_suff app.evidence_sufficiency;
  v_cap app.skill_state; v_observed app.skill_state; v_computed app.skill_state;
  v_as_of date; v_ids uuid[] := '{}';
  v_reasons app.state_reason_code[] := '{}';
begin
  select
    count(*) filter (where c.klass = 'usable'),
    count(distinct c.occurred_on) filter (where c.klass = 'usable'),
    count(distinct c.source) filter (where c.klass = 'usable' and c.source <> 'unknown'),
    count(*) filter (where c.klass = 'usable'
                       and c.provenance in ('human_entered', 'human_confirmed_ai_proposal',
                                            'human_confirmed_system_observation')),
    count(*) filter (where c.klass = 'unreviewed'),
    count(*) filter (where c.klass = 'undecided'),
    count(*) filter (where c.klass = 'rejected'),
    count(*) filter (where c.klass = 'retracted'),
    count(*) filter (where c.klass = 'usable' and c.asserted is not null and c.asserted <> 'unknown'),
    count(distinct c.asserted) filter (where c.klass = 'usable' and c.asserted is not null and c.asserted <> 'unknown')
  into v_n, v_occasions, v_sources, v_human, v_unreviewed, v_undecided, v_rejected,
       v_retracted, v_asserting, v_distinct
  from app.classified_skill_evidence(p_student, p_skill) c;

  v_suff := case
    when v_n >= 3 and v_occasions >= 2 and v_sources >= 2 and v_human >= 1 then 'corroborated'
    when v_n >= 2 and v_occasions >= 2                                     then 'supported'
    when v_n >= 1                                                          then 'preliminary'
    else 'none' end::app.evidence_sufficiency;

  v_cap := case v_suff
    when 'none'         then 'unknown'
    when 'preliminary'  then 'emerging'
    when 'supported'    then 'developing'
    when 'corroborated' then 'developing'
    end::app.skill_state;

  select max(c.asserted) into v_observed
    from app.classified_skill_evidence(p_student, p_skill) c
   where c.klass = 'usable' and c.asserted is not null and c.asserted <> 'unknown';

  v_computed := case when v_observed is null then 'unknown'::app.skill_state
                     else least(v_observed, v_cap) end;

  -- Every usable observation that supports the answer or better, and the most
  -- recent of them. Ordered by id so two runs cite the same list in the same
  -- order and idempotence stays a comparison.
  if v_observed is not null then
    select max(c.occurred_on), array_agg(c.event_id order by c.event_id)
      into v_as_of, v_ids
      from app.classified_skill_evidence(p_student, p_skill) c
     where c.klass = 'usable' and c.asserted is not null and c.asserted <> 'unknown'
       and c.asserted >= v_computed;
  end if;

  if v_n = 0                       then v_reasons := v_reasons || 'no_usable_evidence'::app.state_reason_code; end if;
  if v_n > 0 and v_asserting = 0   then v_reasons := v_reasons || 'evidence_present_but_no_state_asserted'::app.state_reason_code; end if;
  if v_asserting > 0               then v_reasons := v_reasons || 'governed_by_strongest_observation'::app.state_reason_code; end if;
  if v_observed is not null and v_observed > v_cap
                                   then v_reasons := v_reasons || 'limited_by_sufficiency'::app.state_reason_code; end if;
  if v_observed = 'secure'         then v_reasons := v_reasons || 'machine_may_not_determine_secure'::app.state_reason_code; end if;
  if v_distinct > 1                then v_reasons := v_reasons || 'conflicting_assertions_present'::app.state_reason_code; end if;
  if v_unreviewed > 0              then v_reasons := v_reasons || 'excluded_unreviewed_ai_proposal'::app.state_reason_code; end if;
  if v_undecided > 0               then v_reasons := v_reasons || 'excluded_undecided_ai_proposal'::app.state_reason_code; end if;
  if v_rejected > 0                then v_reasons := v_reasons || 'excluded_rejected_ai_proposal'::app.state_reason_code; end if;
  if v_retracted > 0               then v_reasons := v_reasons || 'excluded_by_human_retraction'::app.state_reason_code; end if;

  return jsonb_build_object(
    'rule_version',          app.recompute_rule_version(),
    'computed_state',        v_computed::text,
    'evidence_sufficiency',  v_suff::text,
    'usable_evidence_count', v_n,
    'state_as_of',           v_as_of,
    'state_evidence_ids',    to_jsonb(coalesce(v_ids, '{}'::uuid[])),
    'state_reasons',         to_jsonb(array(select r from unnest(v_reasons) r order by r)),
    'sufficiency_inputs',    jsonb_build_object(
        'usable', v_n, 'occasions', v_occasions, 'distinct_sources', v_sources,
        'human_entered_or_confirmed', v_human, 'asserting', v_asserting,
        'distinct_assertions', v_distinct),
    'excluded',              jsonb_build_object(
        'unreviewed_ai', v_unreviewed, 'undecided_ai', v_undecided,
        'rejected_ai', v_rejected, 'human_retracted', v_retracted));
end $fn$;

revoke all on function app.compute_skill_state(uuid, uuid) from public, anon;
grant execute on function app.compute_skill_state(uuid, uuid) to authenticated, service_role;
revoke all on function public.confirm_diagnostic_observation(uuid, text, text) from public, anon;
grant execute on function public.confirm_diagnostic_observation(uuid, text, text) to authenticated, service_role;

-- --- 3. rows already written under the wrong label --------------------------
-- Both databases hold zero diagnostic evidence today - verified on managed
-- before this was written, and on local. That is exactly the condition under
-- which a backfill looks correct because it touches nothing, which is how 0081's
-- trigger bug survived until it was run over synthetic rows. So this is written
-- as if there were rows, and the migration regression harness seeds one.
--
-- The predicate is deliberately narrow. It relabels an event only when it came
-- from a diagnostic session, carries the AI-confirmed label, and names no AI
-- suggestion. A row that genuinely cites a suggestion is left alone, because
-- then the old label is the true one.

-- Not `on commit drop`: psql applies each statement in its own transaction, so
-- the table would be gone before the guard below could read it. It is dropped
-- explicitly instead, which behaves the same way under a single-transaction
-- apply and correctly under psql.
create temporary table p5_provenance_before as
select ss.student_id, ss.skill_id,
       (app.compute_skill_state(ss.student_id, ss.skill_id)) as state
  from public.student_skills ss
 where exists (
   select 1 from public.student_skill_events e
    where e.student_id = ss.student_id and e.skill_id = ss.skill_id
      and e.evidence_source = 'diagnostic_session'
      and e.record_provenance = 'human_confirmed_ai_proposal'
      and e.ai_suggestion_id is null);

alter table public.student_skill_events disable trigger student_skill_events_append_only;

update public.student_skill_events e
   set record_provenance = 'human_confirmed_system_observation'
 where e.evidence_source = 'diagnostic_session'
   and e.record_provenance = 'human_confirmed_ai_proposal'
   and e.ai_suggestion_id is null;

alter table public.student_skill_events enable trigger student_skill_events_append_only;

-- The restoration is a post-condition, not an assumption.
do $guard$
begin
  if not exists (
    select 1 from pg_catalog.pg_trigger
     where tgrelid = 'public.student_skill_events'::regclass
       and tgname = 'student_skill_events_append_only'
       and tgenabled <> 'D')
  then
    raise exception 'the append-only trigger on student_skill_events was left disabled';
  end if;
end $guard$;

-- Nothing a child holds may have moved. This is why the rule version stays put.
do $guard$
declare v_bad text;
begin
  select string_agg(b.student_id || '/' || b.skill_id, ', ') into v_bad
    from p5_provenance_before b
    cross join lateral (select app.compute_skill_state(b.student_id, b.skill_id) as state) a
   where (b.state->>'computed_state')        is distinct from (a.state->>'computed_state')
      or (b.state->>'evidence_sufficiency')  is distinct from (a.state->>'evidence_sufficiency')
      or (b.state->>'usable_evidence_count') is distinct from (a.state->>'usable_evidence_count');
  if v_bad is not null then
    raise exception
      'relabelling the provenance changed what Nestra says about a child: %. That is a recompute, and it would need a new rule version', v_bad;
  end if;
end $guard$;

drop table p5_provenance_before;

-- And no diagnostic evidence may be left carrying the old claim.
do $guard$
declare v_n int;
begin
  select count(*) into v_n from public.student_skill_events e
   where e.evidence_source = 'diagnostic_session'
     and e.record_provenance = 'human_confirmed_ai_proposal'
     and e.ai_suggestion_id is null;
  if v_n > 0 then
    raise exception '% diagnostic events still claim to be confirmed AI proposals', v_n;
  end if;
end $guard$;

-- --- 4. and the old label becomes unreachable, not merely unwritten ----------
-- A function can be rewritten by the next person in a hurry. A constraint
-- cannot be satisfied by mistake. The escape hatch is deliberate: if a model
-- ever does propose a diagnostic item, the row will name the suggestion it came
-- from, and then `human_confirmed_ai_proposal` is the true label and is allowed.

alter table public.student_skill_events
  add constraint sse_diagnostic_evidence_is_not_an_ai_proposal_ck check (
    evidence_source <> 'diagnostic_session'
    or record_provenance <> 'human_confirmed_ai_proposal'
    or ai_suggestion_id is not null);

comment on constraint sse_diagnostic_evidence_is_not_an_ai_proposal_ck
  on public.student_skill_events is
  'Phase 5 routing is deterministic. Evidence that came out of a diagnostic '
  'session may not claim a model proposed it unless it names the suggestion.';

create or replace function app.assert_schema_invariants()
returns void language plpgsql set search_path = '' as $fn$
declare v_bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then raise exception 'RLS not enabled on: %', v_bad; end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relispartition
     and not exists (select 1 from pg_catalog.pg_policy p where p.polrelid = c.oid)
     and c.relname not in ('job_queue');
  if v_bad is not null then raise exception 'tables with no policy: %', v_bad; end if;

  select string_agg(partition_name || ': ' || problem, '; ') into v_bad
    from app.assert_partition_security();
  if v_bad is not null then raise exception 'insecure partitions: %', v_bad; end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and (pg_catalog.has_function_privilege('public', p.oid, 'execute')
          or pg_catalog.has_function_privilege('anon', p.oid, 'execute'));
  if v_bad is not null then raise exception 'app functions public/anon executable: %', v_bad; end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app','public') and p.prokind = 'f'
     and coalesce(array_to_string(p.proconfig, ','), '') not like '%search_path=%';
  if v_bad is not null then raise exception 'functions without a pinned search_path: %', v_bad; end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'
     and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%'
     and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_barrier=true%';
  if v_bad is not null then
    raise exception 'definer views without security_barrier: %', v_bad;
  end if;

  select string_agg(c.relname || ' (' || ac.privilege_type || ' to ' || r.rolname || ')',
                    ', ' order by c.relname, ac.privilege_type, r.rolname) into v_bad
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) ac
    join pg_catalog.pg_roles r on r.oid = ac.grantee
   where n.nspname = 'public' and c.relkind = 'v'
     and r.rolname in ('anon', 'authenticated')
     and ac.privilege_type <> 'SELECT';
  if v_bad is not null then
    raise exception 'views writable by end users: %', v_bad;
  end if;

  -- STEP 6: no standards field may reappear ON public.skills. The crosswalk is
  -- the only place a framework code lives. This is deliberately a list of exact
  -- names rather than a pattern - it must catch the column coming back under its
  -- old name or an obvious synonym, without arguing about some future legitimate
  -- column that happens to contain the word.
  select string_agg(a.attname, ', ' order by a.attname) into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'skills'
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('framework', 'framework_ref', 'standard', 'standard_id',
                       'standard_ref', 'standard_code', 'standards_code');
  if v_bad is not null then
    raise exception 'a standard is not a skill''s identity; skills.% must live in skill_standards', v_bad;
  end if;

  select string_agg(distinct c.relationship::text, ', ') into v_bad
    from app.capabilities c
   where c.relationship::text not in (
     'student_self','guardian_full','guardian_standard','guardian_view_only',
     'staff_assigned_read','staff_assigned_write','class_staff','org_admin',
     'grant_evaluator','grant_provider','grant_review','grant_transfer','platform_support');
  if v_bad is not null then raise exception 'unreachable relationships in the matrix: %', v_bad; end if;

  select string_agg(distinct pol.polrelid::regclass::text, ', ') into v_bad
    from pg_catalog.pg_policy pol
   where pg_catalog.pg_get_expr(pol.polqual, pol.polrelid) like '%can_write_student%'
     and pol.polrelid::regclass::text not in ('ai_suggestions', 'public.ai_suggestions');
  if v_bad is not null then
    raise exception 'policies still gating on can_write_student: %', v_bad;
  end if;
  -- STEP 7: the retired mastery semantics may not reappear on the canonical
  -- profile tables. `score` was a 0-100 percentage on a child; `mastery_level`
  -- defaulted to a verdict; the rest are the synonyms it would come back as.
  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('student_skills', 'student_skill_events',
                       'student_skill_overrides', 'student_skill_refresh_decisions',
                       'diagnostic_items', 'diagnostic_sessions',
                       'diagnostic_session_items', 'diagnostic_observations',
                       'diagnostic_routing_decisions')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('score', 'mastery_level', 'percent', 'percentage', 'grade_level');
  if v_bad is not null then
    raise exception
      'a child is not a percentage and an absence of evidence is not a verdict; % must not exist',
      v_bad;
  end if;

  -- STEP 7: the state model is exactly four labels. This is what keeps
  -- refresh_suggested out of the state column: adding it to the enum fails here.
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'skill_state';
  if v_bad is distinct from 'unknown, emerging, developing, secure' then
    raise exception
      'app.skill_state must be exactly unknown, emerging, developing, secure - found: %',
      coalesce(v_bad, '(missing)');
  end if;

  -- STEP 7: evidence confidence is a strength scale and nothing else. If a
  -- source or a provenance word ever appears among its labels, the axes have
  -- been re-merged.
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'evidence_confidence';
  if v_bad is distinct from 'preliminary, supported, corroborated' then
    raise exception
      'app.evidence_confidence must be exactly preliminary, supported, corroborated - found: %',
      coalesce(v_bad, '(missing)');
  end if;

  -- STEP 7: the structural guarantee that an unreviewed AI proposal carries no
  -- state. The table constraints do the enforcing; this notices if one is
  -- dropped.
  -- Checked BY NAME. Matching any constraint whose text mentions
  -- ai_proposed_unreviewed was too loose: student_skills also carries
  -- student_skills_secure_requires_human_ck, which mentions it for a different
  -- reason, so dropping the real guarantee left the check satisfied by its
  -- neighbour. Found by the negative test that exists to drop it.
  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.student_skills'::regclass,
                  'student_skills_unreviewed_ai_has_no_state_ck'),
                 ('public.student_skill_events'::regclass,
                  'sse_unreviewed_ai_has_no_state_ck')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_constraint k
      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception 'unreviewed AI proposals are no longer barred from carrying a state: % is missing', v_bad;
  end if;
  -- STEP 7 PHASE 3, (1): the state path may not reach the reference catalogue.
  -- Standards annotate a profile; they never produce one. Checked against the
  -- function source rather than a dependency, because a join written inside
  -- plpgsql leaves no dependency to find.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('compute_skill_state', 'classified_skill_evidence',
                       'recompute_student_skill', 'explain_student_skill',
                       'set_skill_state_override', 'release_skill_state_override',
                       'exclude_skill_evidence', 'restore_skill_evidence')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions)\M';
  if v_bad is not null then
    raise exception
      'the skill-state path reads the standards catalogue: %. Standards annotate a profile; they never produce one', v_bad;
  end if;

  -- STEP 7 PHASE 3, (2): nothing here ranks one child against another.
  select string_agg(x.what, ', ' order by x.what) into v_bad from (
    select n.nspname || '.' || p.proname as what
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.proname ~ '(percentile|cohort|grade_equivalent|class_rank|peer_compar|on_track|behind_ahead)'
    union all
    select n.nspname || '.' || c.relname
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('app', 'public') and c.relkind in ('r', 'v', 'm')
       and c.relname ~ '(percentile|cohort|grade_equivalent|class_rank|peer_compar|on_track|behind_ahead)'
    union all
    select n.nspname || '.' || p.proname
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.proname in ('compute_skill_state', 'classified_skill_evidence',
                         'recompute_student_skill', 'explain_student_skill')
       and p.prosrc ~ '\m(percentile_cont|percentile_disc|cume_dist|ntile|dense_rank)\M'
  ) x;
  if v_bad is not null then
    raise exception 'a child is not ranked against other children; % must not exist', v_bad;
  end if;

  -- STEP 7 PHASE 3, (3): a machine may not compute `secure`, and a human
  -- decision is the state in force. Both are check constraints; this notices if
  -- either is dropped.
  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.student_skills'::regclass,
                  'student_skills_computed_state_never_secure_ck'),
                 ('public.student_skills'::regclass,
                  'student_skills_override_is_effective_ck')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_constraint k
      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception
      'a human decision no longer outranks a computed state, or a machine may now decide secure: % is missing', v_bad;
  end if;

  -- STEP 7 PHASE 4, (1): the refresh path may not write to the profile. A
  -- suggestion that can move a state is not a suggestion.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('refresh_advisory', 'skill_relevance_reasons',
                       'explain_skill_refresh', 'record_refresh_decision',
                       'dismiss_skill_refresh', 'request_skill_revisit',
                       'complete_skill_revisit')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides)\M';
  if v_bad is not null then
    raise exception
      'a refresh suggestion may not change what Nestra says about a child, and % writes to the profile', v_bad;
  end if;

  -- STEP 7 PHASE 4, (2): nor may it reach the reference catalogue. Relevance is
  -- what this family is doing, never what a child of this age is expected to do.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('refresh_advisory', 'skill_relevance_reasons',
                       'explain_skill_refresh', 'record_refresh_decision',
                       'dismiss_skill_refresh', 'request_skill_revisit',
                       'complete_skill_revisit', 'set_family_refresh_advisory')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions)\M';
  if v_bad is not null then
    raise exception
      'the refresh advisory reads the standards catalogue: %. Relevance is what this family is doing, not what a grade expects', v_bad;
  end if;

  -- STEP 7 PHASE 5, (1): the routing path may not reach the reference catalogue.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('diagnostic_branch', 'diagnostic_established',
                       'diagnostic_human_confirmed_secure',
                       'diagnostic_session_state', 'diagnostic_next',
                       'diagnostic_present', 'diagnostic_finish',
                       'start_diagnostic_session', 'record_diagnostic_observation',
                       'pause_diagnostic_session', 'resume_diagnostic_session',
                       'stop_diagnostic_session', 'explain_diagnostic_session')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions)\M';
  if v_bad is not null then
    raise exception
      'the diagnostic routes on the standards catalogue: %. A benchmark may annotate a skill; it may never choose the next question', v_bad;
  end if;

  -- STEP 7 PHASE 5, (2): nor may it read grade or age.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('diagnostic_branch', 'diagnostic_established',
                       'diagnostic_human_confirmed_secure',
                       'diagnostic_session_state', 'diagnostic_next',
                       'diagnostic_present', 'diagnostic_finish',
                       'start_diagnostic_session', 'record_diagnostic_observation',
                       'pause_diagnostic_session', 'resume_diagnostic_session',
                       'stop_diagnostic_session', 'explain_diagnostic_session')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the diagnostic routes on grade or age: %. A child is asked what comes next in her own work, not what her birthday implies', v_bad;
  end if;

  -- STEP 7 PHASE 5, (3): routing may not write to the profile. The single
  -- exception is confirm_diagnostic_observation, which is the human-review path
  -- and is deliberately absent from this list.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('diagnostic_branch', 'diagnostic_established',
                       'diagnostic_human_confirmed_secure',
                       'diagnostic_session_state', 'diagnostic_next',
                       'diagnostic_present', 'diagnostic_finish',
                       'start_diagnostic_session', 'record_diagnostic_observation',
                       'pause_diagnostic_session', 'resume_diagnostic_session',
                       'stop_diagnostic_session', 'explain_diagnostic_session')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides)\M';
  if v_bad is not null then
    raise exception
      'the diagnostic writes to the profile from its routing path: %. Observations become evidence only when a person says so', v_bad;
  end if;

  -- STEP 7 PHASE 5, (4): there is no such thing as how good at maths a child is.
  select string_agg(x.what, ', ' order by x.what) into v_bad from (
    select n.nspname || '.' || p.proname as what
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.proname ~ '(ability_score|overall_ability|global_ability|student_ability|proficiency_score|diagnostic_score)'
    union all
    select c.relname || '.' || a.attname
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class c on c.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped
       -- a leading word boundary, because `evaluator_profiles.availability`
       -- contains the letters and is an evaluator's calendar, not a child's
       -- ability. The first version of this check failed on exactly that.
       and a.attname ~ '\m(ability|proficiency_score|overall_score|global_score)'
  ) x;
  if v_bad is not null then
    raise exception 'a child does not have an ability number; % must not exist', v_bad;
  end if;

  -- STEP 7 PHASE 5, (5): four outcomes, so `skipped` and `not_today` cannot
  -- quietly acquire a failing sibling.
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'diagnostic_outcome';
  if v_bad is distinct from 'demonstrated, not_demonstrated, skipped, not_today' then
    raise exception
      'app.diagnostic_outcome must be exactly demonstrated, not_demonstrated, skipped, not_today - found: %',
      coalesce(v_bad, '(missing)');
  end if;

  -- STEP 7 PHASE 5, (6): a deterministic observation is not an AI proposal, and
  -- the review path may not say it was. Nothing in the Phase 5 engine consults a
  -- model, so writing `human_confirmed_ai_proposal` against diagnostic evidence
  -- is a false statement about where a child's evidence came from, made in the
  -- one column an evaluator would read to find out.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('confirm_diagnostic_observation', 'reject_diagnostic_observation',
                       'record_diagnostic_observation', 'diagnostic_present',
                       'diagnostic_finish', 'start_diagnostic_session')
     and p.prosrc ~ '\mhuman_confirmed_ai_proposal\M';
  if v_bad is not null then
    raise exception
      'the diagnostic path labels its evidence an AI proposal: %. Phase 5 routing is deterministic, and calling its evidence AI-generated is false provenance', v_bad;
  end if;

  -- and the table refuses such a row even if some future path tries to write it
  -- without going through those functions.
  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.student_skill_events'::regclass,
                  'sse_diagnostic_evidence_is_not_an_ai_proposal_ck')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_constraint k
      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception
      'diagnostic evidence may again be recorded as an AI proposal: % is missing', v_bad;
  end if;

end;
$fn$;

select app.assert_schema_invariants();
