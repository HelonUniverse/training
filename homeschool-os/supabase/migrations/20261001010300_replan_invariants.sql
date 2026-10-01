-- =============================================================================
-- 0122  STEP 8 PHASE 3 invariants - the loop stays one-directional
-- =============================================================================
-- Same redefinition discipline every invariants file in this project has
-- used: the WHOLE cumulative body, not a diff.
--
-- WHAT THIS ADDS, and nothing else:
--   - the replan functions join the standards / grade-age / profile-write /
--     computed-state-naming checks already applied to every other layer
--   - request_replan_evaluation is checked by name: it reaches the path only
--     through regenerate_learning_path, never by writing learning_paths or
--     learning_path_nodes itself, and only when it holds learning_plan:create
--   - the same-skill helpers are checked by name never to read student_skills
--     directly - they consume app.path_skill_context, which already consumed
--     the profile upstream
--   - the new table's guard, constraint and enum shapes are checked by name
--   - app.replan_note is checked for the vocabulary it must never use
-- =============================================================================

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
                       'diagnostic_routing_decisions',
                       'learning_paths', 'learning_path_nodes', 'learning_path_events')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('score', 'mastery_level', 'percent', 'percentage', 'grade_level');
  if v_bad is not null then
    raise exception
      'a child is not a percentage and an absence of evidence is not a verdict; % must not exist',
      v_bad;
  end if;

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
       and a.attname ~ '\m(ability|proficiency_score|overall_score|global_score)'
  ) x;
  if v_bad is not null then
    raise exception 'a child does not have an ability number; % must not exist', v_bad;
  end if;

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

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('path_branch', 'path_skill_context', 'path_characterized',
                       'path_well_characterized', 'path_human_confirmed_secure',
                       'path_diagnostic_frontier', 'path_named_by_a_person',
                       'path_resource_for', 'path_candidates', 'path_readiness',
                       'path_unmet_prerequisites', 'path_order_warnings',
                       'generate_learning_path', 'approve_learning_path',
                       'reject_learning_path', 'pause_learning_path',
                       'resume_learning_path', 'archive_learning_path',
                       'add_path_node', 'remove_path_node', 'reorder_path_node',
                       'complete_path_node', 'regenerate_learning_path',
                       'explain_learning_path')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions|resource_standards)\M';
  if v_bad is not null then
    raise exception
      'the learning path reads the standards catalogue: %. Standards annotate a skill; they never choose what a child does next', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('path_branch', 'path_skill_context', 'path_characterized',
                       'path_well_characterized', 'path_human_confirmed_secure',
                       'path_diagnostic_frontier', 'path_named_by_a_person',
                       'path_resource_for', 'path_candidates', 'path_readiness',
                       'path_unmet_prerequisites', 'path_order_warnings',
                       'generate_learning_path', 'approve_learning_path',
                       'reject_learning_path', 'pause_learning_path',
                       'resume_learning_path', 'archive_learning_path',
                       'add_path_node', 'remove_path_node', 'reorder_path_node',
                       'complete_path_node', 'regenerate_learning_path',
                       'explain_learning_path')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the learning path routes on grade or age: %. What comes next follows from what this child has shown, not from her birthday', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('path_branch', 'path_skill_context', 'path_characterized',
                       'path_well_characterized', 'path_human_confirmed_secure',
                       'path_diagnostic_frontier', 'path_named_by_a_person',
                       'path_resource_for', 'path_candidates', 'path_readiness',
                       'path_unmet_prerequisites', 'path_order_warnings',
                       'generate_learning_path', 'approve_learning_path',
                       'reject_learning_path', 'pause_learning_path',
                       'resume_learning_path', 'archive_learning_path',
                       'add_path_node', 'remove_path_node', 'reorder_path_node',
                       'complete_path_node', 'regenerate_learning_path',
                       'explain_learning_path')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides|diagnostic_observations)\M';
  if v_bad is not null then
    raise exception
      'the learning path writes to the profile: %. Being on a path is not evidence, and finishing one is not mastery', v_bad;
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_constraint k
    join pg_catalog.pg_class c on c.oid = k.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral unnest(k.conkey) as ck(attnum)
    join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = ck.attnum
   where n.nspname = 'public' and k.contype = 'f'
     and c.relname in ('student_skills', 'student_skill_events', 'student_skill_overrides',
                       'diagnostic_observations')
     and k.confrelid::regclass::text in ('learning_paths', 'learning_path_nodes',
                                         'public.learning_paths', 'public.learning_path_nodes');
  if v_bad is not null then
    raise exception
      'evidence now points at a learning path: %. Path membership is not evidence and may not become a column that implies it', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('learning_paths_one_live_idx'),
                 ('learning_paths_approval_names_its_actor_ck'),
                 ('learning_paths_horizon_is_small_ck')) as x(want)
   where not exists (select 1 from pg_catalog.pg_constraint k
                      where k.conname = x.want and k.conrelid = 'public.learning_paths'::regclass)
     and not exists (select 1 from pg_catalog.pg_class ci
                      join pg_catalog.pg_namespace ni on ni.oid = ci.relnamespace
                     where ci.relname = x.want and ni.nspname = 'public' and ci.relkind = 'i');
  if v_bad is not null then
    raise exception
      'an approved path may now be overwritten, unbounded or unattributed: % is missing', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_paths'::regclass, 'learning_paths_no_silent_rewrite'),
                 ('public.learning_path_nodes'::regclass, 'lpn_reason_is_not_rewritten')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_trigger t
      where t.tgrelid = x.rel and t.tgname = x.want and not t.tgisinternal
        and t.tgenabled <> 'D');
  if v_bad is not null then
    raise exception
      'the record of what was proposed and approved is no longer protected: % is missing or disabled', v_bad;
  end if;

  -- ===========================================================================
  -- STEP 8 PHASE 1
  -- ===========================================================================

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('learning_activity_rule_version', 'learning_activity_candidates',
                       'learning_activity_supply', 'learning_activity_select_resource',
                       'learning_activity_node_is_actionable',
                       'learning_activity_revisit_is_invited',
                       'learning_activity_resource_snapshot',
                       'learning_activity_next_states',
                       'learning_activity_transition_allowed',
                       'learning_activity_transition_refusal',
                       'learning_activity_note', 'learning_activity_transition',
                       'select_activity_for_node', 'choose_activity_resource',
                       'create_custom_activity', 'replace_activity_resource',
                       'start_activity', 'complete_activity', 'skip_activity',
                       'not_today_activity', 'archive_activity', 'reopen_activity',
                       'explain_activity')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions|resource_standards)\M';
  if v_bad is not null then
    raise exception
      'the activity layer reads the standards catalogue: %. Standards annotate a skill; they never choose what a child does', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('learning_activity_rule_version', 'learning_activity_candidates',
                       'learning_activity_supply', 'learning_activity_select_resource',
                       'learning_activity_node_is_actionable',
                       'learning_activity_revisit_is_invited',
                       'learning_activity_resource_snapshot',
                       'learning_activity_next_states',
                       'learning_activity_transition_allowed',
                       'learning_activity_transition_refusal',
                       'learning_activity_note', 'learning_activity_transition',
                       'select_activity_for_node', 'choose_activity_resource',
                       'create_custom_activity', 'replace_activity_resource',
                       'start_activity', 'complete_activity', 'skip_activity',
                       'not_today_activity', 'archive_activity', 'reopen_activity',
                       'explain_activity')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the activity layer routes on grade or age: %. A resource is chosen from what a person confirmed it teaches, never from a birthday', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('learning_activity_rule_version', 'learning_activity_candidates',
                       'learning_activity_supply', 'learning_activity_select_resource',
                       'learning_activity_node_is_actionable',
                       'learning_activity_revisit_is_invited',
                       'learning_activity_resource_snapshot',
                       'learning_activity_next_states',
                       'learning_activity_transition_allowed',
                       'learning_activity_transition_refusal',
                       'learning_activity_note', 'learning_activity_transition',
                       'select_activity_for_node', 'choose_activity_resource',
                       'create_custom_activity', 'replace_activity_resource',
                       'start_activity', 'complete_activity', 'skip_activity',
                       'not_today_activity', 'archive_activity', 'reopen_activity',
                       'explain_activity')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides|diagnostic_observations)\M';
  if v_bad is not null then
    raise exception
      'the activity layer writes to the profile: %. Doing a worksheet is not evidence and finishing it is not mastery', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('learning_activity_candidates', 'learning_activity_supply',
                       'learning_activity_select_resource', 'learning_activity_transition',
                       'learning_activity_resource_snapshot',
                       'select_activity_for_node', 'choose_activity_resource',
                       'create_custom_activity', 'replace_activity_resource',
                       'complete_activity', 'skip_activity', 'not_today_activity',
                       'reopen_activity', 'explain_activity')
     and p.prosrc ~ '\m(skill_state|computed_state|effective_state)\M';
  if v_bad is not null then
    raise exception
      'the activity layer names a child''s computed state: %. Completion is a fact about a morning and may not touch what Nestra believes about her', v_bad;
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_constraint k
    join pg_catalog.pg_class c on c.oid = k.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral unnest(k.conkey) as ck(attnum)
    join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = ck.attnum
   where n.nspname = 'public' and k.contype = 'f'
     and c.relname in ('student_skills', 'student_skill_events', 'student_skill_overrides',
                       'diagnostic_observations')
     and k.confrelid::regclass::text in ('learning_activities', 'public.learning_activities',
                                         'learning_activity_events',
                                         'public.learning_activity_events');
  if v_bad is not null then
    raise exception
      'evidence now points at an activity: %. Being given a worksheet is not evidence and may not become a column that implies it', v_bad;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'learning_activity_candidates'
       and p.prosrc ~ 'and rs\.confirmed') then
    raise exception
      'app.learning_activity_candidates no longer requires a confirmed mapping. An unreviewed guess about what a worksheet teaches may not decide what a child receives';
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('learning_activity_candidates', 'learning_activity_supply',
                       'learning_activity_select_resource', 'learning_activity_transition',
                       'learning_activity_resource_snapshot',
                       'select_activity_for_node', 'choose_activity_resource',
                       'create_custom_activity', 'replace_activity_resource',
                       'start_activity', 'complete_activity', 'skip_activity',
                       'not_today_activity', 'archive_activity', 'reopen_activity',
                       'explain_activity')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(learning_paths|learning_path_nodes|learning_path_events)\M';
  if v_bad is not null then
    raise exception
      'the activity layer rewrites the learning path: %. The pedagogical model does not bend around what happens to be in the catalogue', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('path_branch', 'path_skill_context', 'path_characterized',
                       'path_well_characterized', 'path_human_confirmed_secure',
                       'path_diagnostic_frontier', 'path_named_by_a_person',
                       'path_resource_for', 'path_candidates', 'path_readiness',
                       'path_unmet_prerequisites', 'path_order_warnings',
                       'generate_learning_path', 'regenerate_learning_path')
     and p.prosrc ~ '\m(availability|requires_subscription|provider_disconnected)\M';
  if v_bad is not null then
    raise exception
      'the learning path reads resource availability: %. What a family explores next is not decided by what a subscription happens to cover', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_activities'::regclass, 'la_no_goal_target_autoselection'),
                 ('public.learning_activities'::regclass, 'la_target_is_not_rewritten'),
                 ('public.learning_activities'::regclass, 'la_history_is_not_rewritten'),
                 ('public.learning_activity_events'::regclass, 'learning_activity_events_append_only'))
         as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_trigger t
      where t.tgrelid = x.rel and t.tgname = x.want and not t.tgisinternal
        and t.tgenabled <> 'D');
  if v_bad is not null then
    raise exception
      'the activity guards are missing or disabled: %', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('la_provenance_matches_origin_ck'),
                 ('la_selection_names_its_actor_ck'),
                 ('la_human_selected_names_its_resource_ck'),
                 ('la_authored_activity_is_not_a_selection_ck'),
                 ('la_lifecycle_is_attributed_ck')) as x(want)
   where not exists (select 1 from pg_catalog.pg_constraint k
                      where k.conname = x.want
                        and k.conrelid = 'public.learning_activities'::regclass);
  if v_bad is not null then
    raise exception
      'an activity may now misdescribe where it came from: % is missing', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('la_one_live_per_node_idx')) as x(want)
   where not exists (select 1 from pg_catalog.pg_class ci
                      join pg_catalog.pg_namespace ni on ni.oid = ci.relnamespace
                     where ci.relname = x.want and ni.nspname = 'public' and ci.relkind = 'i');
  if v_bad is not null then
    raise exception 'two live activities may now sit on one step: % is missing', v_bad;
  end if;

  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'learning_activity_status';
  if v_bad is distinct from
     'proposed, selected, available, started, completed, skipped, not_today, replaced, archived' then
    raise exception
      'app.learning_activity_status must be exactly proposed, selected, available, started, completed, skipped, not_today, replaced, archived - found: %',
      coalesce(v_bad, '(missing)');
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('learning_activities', 'learning_activity_events')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('failed', 'failure', 'missed', 'overdue', 'late',
                       'compliance_status', 'required');
  if v_bad is not null then
    raise exception
      'a skipped morning is not a failure; % must not exist', v_bad;
  end if;

  if app.learning_activity_transition_allowed('completed', 'started')
     or app.learning_activity_transition_allowed('completed', 'not_today')
     or app.learning_activity_transition_allowed('replaced', 'started')
     or app.learning_activity_transition_allowed('archived', 'started')
     or coalesce(array_length(app.learning_activity_next_states('replaced'), 1), 0) <> 0
     or coalesce(array_length(app.learning_activity_next_states('archived'), 1), 0) <> 0
     or app.learning_activity_next_states('completed')
        is distinct from array['archived']::app.learning_activity_status[] then
    raise exception
      'the activity lifecycle now allows history to be rewritten. Completed, replaced and archived are endings: doing something again is a new activity with lineage, never an edit to one that already happened';
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('path_resource_for', 'learning_activity_candidates')
     and p.prosrc ~ '\mstudent_course_enrollments\M'
     and p.prosrc !~ 'status\s*=\s*''active''';
  if v_bad is not null then
    raise exception
      'a resource selector prefers enrolment without requiring it to be active: %. A course the family finished is not the curriculum they are using, and two functions answering that differently is a defect', v_bad;
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('learning_activities', 'learning_activity_events')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('score', 'mastery_level', 'percent', 'percentage', 'grade_level');
  if v_bad is not null then
    raise exception
      'a child is not a percentage; % must not exist', v_bad;
  end if;

  -- ===========================================================================
  -- STEP 8 PHASE 2
  -- ===========================================================================

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_rule_version', 'today_items', 'today_card',
                       'today_decide', 'learning_activity_launch',
                       'today', 'explain_today_item', 'pin_for_today',
                       'hide_for_today', 'choose_for_today', 'clear_today_decision',
                       'start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'open_activity_resource', 'attach_activity_artifact',
                       'offer_activity_evidence', 'accept_evidence_proposal',
                       'decline_evidence_proposal', 'activity_history',
                       'request_different_activity', 'withdraw_activity_change_request',
                       'approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions|resource_standards)\M';
  if v_bad is not null then
    raise exception
      'the experience layer reads the standards catalogue: %. A child does not need a benchmark code to do some fractions with measuring cups', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_rule_version', 'today_items', 'today_card',
                       'today_decide', 'learning_activity_launch',
                       'today', 'explain_today_item', 'pin_for_today',
                       'hide_for_today', 'choose_for_today', 'clear_today_decision',
                       'start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'open_activity_resource', 'attach_activity_artifact',
                       'offer_activity_evidence', 'accept_evidence_proposal',
                       'decline_evidence_proposal', 'activity_history',
                       'request_different_activity', 'withdraw_activity_change_request',
                       'approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the experience layer routes on grade or age: %. The same evidence and the same approved path give the same Today at nine and at fourteen', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_rule_version', 'today_items', 'today_card',
                       'today_decide', 'learning_activity_launch',
                       'today', 'explain_today_item', 'pin_for_today',
                       'hide_for_today', 'choose_for_today', 'clear_today_decision',
                       'start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'open_activity_resource', 'attach_activity_artifact',
                       'offer_activity_evidence', 'accept_evidence_proposal',
                       'decline_evidence_proposal', 'activity_history',
                       'request_different_activity', 'withdraw_activity_change_request',
                       'approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides|diagnostic_observations)\M';
  if v_bad is not null then
    raise exception
      'the experience layer writes to the profile: %. Finishing a worksheet is not learning a skill, and the gap between them is a person', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_items', 'today_card', 'today_decide',
                       'learning_activity_launch', 'today', 'explain_today_item',
                       'start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'open_activity_resource', 'attach_activity_artifact',
                       'offer_activity_evidence', 'accept_evidence_proposal',
                       'decline_evidence_proposal', 'activity_history',
                       'request_different_activity', 'withdraw_activity_change_request',
                       'approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc ~ '\m(skill_state|computed_state|effective_state|evidence_sufficiency)\M';
  if v_bad is not null then
    raise exception
      'the experience layer names a child''s computed state: %. A morning is a fact about a morning', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_items', 'today_card', 'today_decide',
                       'learning_activity_launch', 'today', 'explain_today_item',
                       'pin_for_today', 'hide_for_today', 'choose_for_today',
                       'clear_today_decision', 'start_learning_session',
                       'pause_learning_session', 'end_learning_session',
                       'add_session_note', 'open_activity_resource',
                       'attach_activity_artifact', 'offer_activity_evidence',
                       'accept_evidence_proposal', 'decline_evidence_proposal',
                       'activity_history',
                       'request_different_activity', 'withdraw_activity_change_request',
                       'approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(learning_paths|learning_path_nodes|learning_path_events)\M';
  if v_bad is not null then
    raise exception
      'the experience layer rewrites the learning path: %. Today reads the plan; it does not edit it', v_bad;
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_constraint k
    join pg_catalog.pg_class c on c.oid = k.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral unnest(k.conkey) as ck(attnum)
    join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = ck.attnum
   where n.nspname = 'public' and k.contype = 'f'
     and c.relname in ('student_skills', 'student_skill_events', 'student_skill_overrides',
                       'diagnostic_observations')
     and k.confrelid::regclass::text in (
       'today_decisions', 'public.today_decisions',
       'learning_activity_sessions', 'public.learning_activity_sessions',
       'learning_activity_artifacts', 'public.learning_activity_artifacts',
       'learning_evidence_proposals', 'public.learning_evidence_proposals',
       'learning_activity_change_requests', 'public.learning_activity_change_requests');
  if v_bad is not null then
    raise exception
      'evidence now points at something from the experience layer: %. Being in Today, or having finished something, or having asked to change it, is not a reason to believe anything about a child', v_bad;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'accept_evidence_proposal'
       and p.prosrc ~ '\mconfirm_skill_evidence\M') then
    raise exception
      'accept_evidence_proposal no longer goes through public.confirm_skill_evidence. The evidence bridge must use the architecture that already exists, not a second copy of it';
  end if;
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('accept_evidence_proposal', 'decline_evidence_proposal',
                       'offer_activity_evidence', 'end_learning_session',
                       'attach_activity_artifact', 'add_session_note')
     and p.prosrc ~* 'insert\s+into\s+(public\.)?learning_evidence\M';
  if v_bad is not null then
    raise exception
      'the experience layer writes learning_evidence directly: %. It goes through confirm_skill_evidence, which is where the confirmation rules live', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'today_items', 'today_card', 'activity_history')
     and p.prosrc ~* '(epoch|justify_interval|\mage\s*\()';
  if v_bad is not null then
    raise exception
      'a session duration is being computed from the clock: %. Duration is only what somebody reported; null means nobody knows, which is the ordinary case', v_bad;
  end if;

  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'learning_session_outcome';
  if v_bad is distinct from 'completed, partially_completed, explored, stopped' then
    raise exception
      'app.learning_session_outcome must be exactly completed, partially_completed, explored, stopped - found: %. '
      'A wish about next time (wanting more, wanting to come back later) is not an outcome and belongs in '
      'learning_activity_sessions.wants_more / .revisit_later instead', coalesce(v_bad, '(missing)');
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'learning_activity_sessions'
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('wants_more', 'revisit_later')
     and a.atttypid <> 'boolean'::regtype;
  if v_bad is not null then
    raise exception
      'a follow-up flag is no longer a plain boolean: %. Wanting more or wanting to come back later is a yes-or-no wish, not a vocabulary that can grow a failure label', v_bad;
  end if;

  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('today_decisions', 'learning_activity_sessions',
                       'learning_activity_artifacts', 'learning_evidence_proposals',
                       'learning_activity_change_requests')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('failed', 'failure', 'missed', 'overdue', 'late', 'due_at',
                       'due_on', 'required', 'score', 'mastery_level', 'percent',
                       'percentage', 'grade_level');
  if v_bad is not null then
    raise exception
      'a morning is not a deadline and a child is not a percentage; % must not exist', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_activity_sessions'::regclass, 'las_occasions_are_not_rewritten'),
                 ('public.learning_evidence_proposals'::regclass, 'lep_answers_are_not_rewritten'),
                 ('public.learning_activity_artifacts'::regclass, 'laa_artifacts_are_append_only'),
                 ('public.learning_activity_change_requests'::regclass, 'lacr_transitions_are_guarded'))
         as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_trigger t
      where t.tgrelid = x.rel and t.tgname = x.want and not t.tgisinternal
        and t.tgenabled <> 'D');
  if v_bad is not null then
    raise exception
      'the experience guards are missing or disabled: %', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_activity_sessions'::regclass, 'las_ended_session_is_complete_ck'),
                 ('public.learning_evidence_proposals'::regclass, 'lep_only_acceptance_produces_evidence_ck'),
                 ('public.learning_evidence_proposals'::regclass, 'lep_decision_names_its_actor_ck'),
                 ('public.learning_activity_artifacts'::regclass, 'laa_points_at_something_ck'),
                 ('public.learning_activity_change_requests'::regclass, 'lacr_decision_names_its_actor_ck'),
                 ('public.learning_activity_change_requests'::regclass, 'lacr_result_only_on_approval_ck'))
         as x(rel, want)
   where not exists (select 1 from pg_catalog.pg_constraint k
                      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception
      'an occasion, an evidence answer or a change request may now be recorded incompletely: % is missing', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('path_resource_for', 'learning_activity_candidates')
     and p.prosrc ~ '\mstudent_course_enrollments\M'
     and p.prosrc !~ 'status\s*=\s*''active''';
  if v_bad is not null then
    raise exception
      'a resource selector prefers enrolment without requiring it to be active: %. A course the family finished is not the curriculum they are using, and two functions answering that differently is a defect', v_bad;
  end if;

  -- ===========================================================================
  -- STEP 8 PHASE 2 CORRECTION - the request model
  -- ===========================================================================

  if exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'child_choose_alternative_activity') then
    raise exception
      'child_choose_alternative_activity has been retired and must not be redefined. A child may not directly replace her own activity - only request that an adult do so, through request_different_activity';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'approve_activity_change_request'
       and p.prosrc ~ '\mreplace_activity_resource\M') then
    raise exception
      'approve_activity_change_request no longer goes through replace_activity_resource. Approval must use the one existing explicit-replacement mechanism, not a second copy of it';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'request_different_activity'
       and p.prosrc ~ '\mlearning_activity_candidates\M') then
    raise exception
      'request_different_activity no longer restricts itself to that skill''s confirmed candidates. A child could then ask for a resource confirmed for a different skill, or one never meant to be hers to pick';
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('request_different_activity', 'withdraw_activity_change_request')
     and p.prosrc ~* '(update|insert\s+into)\s+(public\.)?learning_activities\M';
  if v_bad is not null then
    raise exception
      'a child-facing request function writes directly to learning_activities: %. Requesting something different, or taking the request back, must never itself replace the activity - only approve_activity_change_request may do that, and only through replace_activity_resource', v_bad;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('approve_activity_change_request', 'decline_activity_change_request')
     and p.prosrc !~ '''learning_activity''.{0,20}''approve''';
  if v_bad is not null then
    raise exception
      'a change-request decision function no longer checks the `approve` capability by name: %. Deciding a request to change a child''s activity is not this account''s decision to make unless it holds `approve`', v_bad;
  end if;

  select string_agg(c.action::text, ', ' order by c.action::text) into v_bad
    from app.capabilities c
   where c.relationship = 'student_self' and c.resource = 'learning_activity'
     and c.action in ('create', 'delete', 'approve');
  if v_bad is not null then
    raise exception
      'a child may now % her own learning activities. Running a morning and choosing a curriculum are different powers, and deciding what counts as evidence about a child - or granting her own request to change what she is working on - is not hers to make', v_bad;
  end if;

  -- ===========================================================================
  -- STEP 8 PHASE 3 - adaptive replanning
  -- ===========================================================================

  -- (1) The replan layer may not reach the standards catalogue.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('replan_rule_version', 'same_skill_recommendation',
                       'find_live_path_for_skill', 'classify_replan_outcome',
                       'suggest_same_skill_alternative', 'request_replan_evaluation',
                       'replan_note', 'explain_replan_recommendation')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions|resource_standards)\M';
  if v_bad is not null then
    raise exception
      'the replan layer reads the standards catalogue: %. Standards annotate a skill; they never decide whether a plan should change', v_bad;
  end if;

  -- (2) Nor grade or age. The same evidence and the same approved path produce
  -- the same replan recommendation at nine and at fourteen.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('replan_rule_version', 'same_skill_recommendation',
                       'find_live_path_for_skill', 'classify_replan_outcome',
                       'suggest_same_skill_alternative', 'request_replan_evaluation',
                       'replan_note', 'explain_replan_recommendation')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the replan layer routes on grade or age: %. Whether to reconsider a plan follows from evidence and intent, never from a birthday', v_bad;
  end if;

  -- (3) THE PROFILE-FIRST RULE. Nothing here writes to the profile - a replan
  -- reads what evidence already changed; it never changes evidence itself.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('same_skill_recommendation', 'find_live_path_for_skill',
                       'classify_replan_outcome', 'suggest_same_skill_alternative',
                       'request_replan_evaluation', 'explain_replan_recommendation')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides|diagnostic_observations)\M';
  if v_bad is not null then
    raise exception
      'the replan layer writes to the profile: %. A replan consumes what the profile already says; it may never be the thing that changes it', v_bad;
  end if;

  -- and the SAME functions may not read those tables directly either. The
  -- profile was already consulted upstream, by app.path_skill_context and by
  -- the engine functions STEP 7 Phase 6 already built - reading student_skills
  -- a second time here would be a second opinion running beside the first.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('same_skill_recommendation', 'find_live_path_for_skill',
                       'classify_replan_outcome', 'suggest_same_skill_alternative',
                       'request_replan_evaluation')
     and p.prosrc ~ '\m(student_skills|student_skill_events|student_skill_overrides)\M';
  if v_bad is not null then
    raise exception
      'the replan layer reads the profile directly: %. It consumes app.path_skill_context and app.path_candidates, which already consulted the profile - it does not calculate a skill''s state a second time', v_bad;
  end if;

  -- and may not name the computed-state columns either.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('same_skill_recommendation', 'classify_replan_outcome',
                       'suggest_same_skill_alternative', 'request_replan_evaluation',
                       'explain_replan_recommendation')
     and p.prosrc ~ '\m(skill_state|computed_state|effective_state)\M';
  if v_bad is not null then
    raise exception
      'the replan layer names a child''s computed state directly: %. It is a planning decision about a plan, not a second opinion about a child', v_bad;
  end if;

  -- (4) The loop that must not exist. If evidence could point at a replan
  -- recommendation, "Nestra once suggested this" would become a reason to
  -- believe something about a child.
  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_constraint k
    join pg_catalog.pg_class c on c.oid = k.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral unnest(k.conkey) as ck(attnum)
    join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = ck.attnum
   where n.nspname = 'public' and k.contype = 'f'
     and c.relname in ('student_skills', 'student_skill_events', 'student_skill_overrides',
                       'diagnostic_observations')
     and k.confrelid::regclass::text in ('learning_path_replan_recommendations',
                                         'public.learning_path_replan_recommendations');
  if v_bad is not null then
    raise exception
      'evidence now points at a replan recommendation: %. A suggestion is not evidence and may not become a column that implies it', v_bad;
  end if;

  -- (5) The engine REUSES generate/regenerate_learning_path rather than
  -- reimplementing replacement, the same guarantee STEP 8 Phase 2's
  -- correction already enforces for approve_activity_change_request.
  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'request_replan_evaluation'
       and p.prosrc ~ '\mregenerate_learning_path\M') then
    raise exception
      'request_replan_evaluation no longer goes through regenerate_learning_path. A path-level recommendation must use the one existing proposal mechanism, not a second copy of it';
  end if;

  -- and it may never write learning_paths or learning_path_nodes directly -
  -- the only door onto a new version is the call above.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('request_replan_evaluation', 'suggest_same_skill_alternative')
     and p.prosrc ~* '(update|insert\s+into)\s+(public\.)?(learning_paths|learning_path_nodes)\M';
  if v_bad is not null then
    raise exception
      'a replan function writes directly to the learning path: %. Only regenerate_learning_path may create a new version', v_bad;
  end if;

  -- (6) A path-level trigger is gated on learning_plan:create by name - the
  -- same capability regenerate_learning_path has always required, and one a
  -- child never holds.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'request_replan_evaluation'
     and p.prosrc !~ '''learning_plan''.{0,20}''create''';
  if v_bad is not null then
    raise exception
      'request_replan_evaluation no longer checks learning_plan:create by name before a path-level trigger: %. A replan that could change what a child is asked to do next is not a decision a child may make for herself', v_bad;
  end if;

  -- (7) The outcome and trigger vocabularies are exactly what the gate
  -- approved - nine planning decisions, eight legitimate reasons, and none of
  -- either list is a verdict about a child.
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'replan_outcome';
  if v_bad is distinct from
     'no_change, continue_current_skill, offer_alternative_resource, offer_alternative_modality, revisit_later, refresh_current_path, advance_to_connected_skill, return_to_prerequisite, await_human_review' then
    raise exception
      'app.replan_outcome no longer matches the approved vocabulary - found: %', coalesce(v_bad, '(missing)');
  end if;

  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'replan_trigger_reason';
  if v_bad is distinct from
     'confirmed_evidence_changed_profile, human_confirmed_secure, parent_goal_changed, approved_revisit, resource_unavailable, child_change_request_approved, active_enrollment_changed, diagnostic_frontier_changed' then
    raise exception
      'app.replan_trigger_reason no longer matches the approved vocabulary - found: %', coalesce(v_bad, '(missing)');
  end if;

  -- nor may a punitive word arrive as a column on the recommendation table.
  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'learning_path_replan_recommendations'
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('failed', 'failure', 'behind', 'deficient', 'remediation',
                       'catch_up', 'score', 'mastery_level', 'percent', 'percentage',
                       'grade_level');
  if v_bad is not null then
    raise exception
      'a replan recommendation is not a verdict about a child; % must not exist', v_bad;
  end if;

  -- (8) Every row recorded here is still waiting on the same approval every
  -- other path change already requires - checked both as a constraint and,
  -- separately, by name, because a dropped CHECK and a quietly-added "safe
  -- automatic" branch would look identical from the outside.
  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_path_replan_recommendations'::regclass,
                  'lprr_requires_review_ck')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_constraint k
      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception
      'a path-level replan recommendation may now skip human review: % is missing', v_bad;
  end if;

  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_path_replan_recommendations'::regclass,
                  'lprr_append_only')) as x(rel, want)
   where not exists (
     select 1 from pg_catalog.pg_trigger t
      where t.tgrelid = x.rel and t.tgname = x.want and not t.tgisinternal
        and t.tgenabled <> 'D');
  if v_bad is not null then
    raise exception
      'the record of why a replan was recommended is no longer protected: % is missing or disabled', v_bad;
  end if;

  -- (9) The fixed sentences explain_replan_recommendation shows a family may
  -- never say a child failed, is behind, or should already know something -
  -- checked against the function's own source, not trusted to review.
  if exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'replan_note'
       and p.prosrc ~* '\m(fail|failed|failure|behind|deficient|remediation|catch.?up|should already know)\M') then
    raise exception
      'app.replan_note contains language this product has always refused: a plan changing is not a child failing';
  end if;

  -- (10) A child may ask, may see a same-skill suggestion, and may never
  -- approve or decline a path-level recommendation for herself - the same
  -- line Phase 2''s correction already drew for her own change requests.
  select string_agg(c.action::text, ', ' order by c.action::text) into v_bad
    from app.capabilities c
   where c.relationship = 'student_self' and c.resource = 'learning_plan'
     and c.action in ('create', 'approve');
  if v_bad is not null then
    raise exception
      'a child may now % her own learning plan. Asking whether something else might work is hers; deciding whether the plan itself changes direction is not', v_bad;
  end if;

end;
$fn$;

select app.assert_schema_invariants();
