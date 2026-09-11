-- =============================================================================
-- 0102  The Learning Path cannot become a curriculum
-- =============================================================================
-- Every way this feature goes wrong is a way of turning a proposal into a
-- verdict. It happens when the path starts reading the benchmark catalogue and
-- quietly becomes a grade sequence; when it reads a birthday and becomes a
-- placement; when finishing a node writes to the profile and a plan becomes a
-- transcript; or when a new suggestion overwrites the one a parent approved and
-- she can no longer tell what she agreed to.
--
-- So each of those is refused at the source rather than in a review.
--
--   1. The path may not read the reference catalogue.
--   2. The path may not read grade or age.
--   3. The path may not write to the profile. There is no exception here at
--      all - unlike Phase 5, which has exactly one, the human-review promotion.
--      Nothing about a path ever becomes evidence.
--   4. Evidence may not point back at a path. The column that would make "it
--      was on her plan" into a reason to believe something cannot exist.
--   5. An approved path is not rewritten in place, and the triggers and
--      constraints that guarantee it are checked by name.
--   6. The retired numeric semantics may not appear on the path tables either -
--      the sweep now covers all twelve profile, diagnostic and path tables.
-- =============================================================================

-- --- what an approved path is allowed to change ------------------------------
-- A parent editing her plan changes positions and statuses. She does not change
-- what Nestra proposed or why, because that record is the thing she is deciding
-- ABOUT, and a record that moves under the decision is not a record.

create or replace function app.forbid_approved_path_rewrite()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  if new.student_id is distinct from old.student_id then
    raise exception 'a path belongs to the child it was made for';
  end if;
  if old.status in ('approved', 'paused', 'rejected', 'archived') then
    if new.version              is distinct from old.version
       or new.supersedes_id     is distinct from old.supersedes_id
       or new.rule_version      is distinct from old.rule_version
       or new.node_horizon      is distinct from old.node_horizon
       or new.generation_inputs is distinct from old.generation_inputs
       or new.branch_root_skill_id is distinct from old.branch_root_skill_id then
      raise exception
        'this path has already been decided on; a new suggestion is a new version, not an edit to this one';
    end if;
    if new.status = 'proposed' then
      raise exception 'a path that has been decided on does not go back to being a proposal';
    end if;
  end if;
  return new;
end $fn$;

create or replace function app.forbid_path_reason_rewrite()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  if new.path_id is distinct from old.path_id
     or new.student_id is distinct from old.student_id
     or new.skill_id is distinct from old.skill_id
     or new.reason_code is distinct from old.reason_code
     or new.reason_detail is distinct from old.reason_detail
     or new.readiness_reasons is distinct from old.readiness_reasons
     or new.evidence_context is distinct from old.evidence_context then
    raise exception
      'why a skill was proposed, and what was known when it was, are not editable';
  end if;
  return new;
end $fn$;

revoke all on function app.forbid_approved_path_rewrite() from public, anon, authenticated;
revoke all on function app.forbid_path_reason_rewrite() from public, anon, authenticated;

create trigger learning_paths_no_silent_rewrite
  before update on public.learning_paths
  for each row execute function app.forbid_approved_path_rewrite();

create trigger lpn_reason_is_not_rewritten
  before update on public.learning_path_nodes
  for each row execute function app.forbid_path_reason_rewrite();

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
                       'diagnostic_routing_decisions',
                       'learning_paths', 'learning_path_nodes', 'learning_path_events')
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

  -- STEP 7 PHASE 6, (1): the path may not reach the reference catalogue. A
  -- parent who never opens a standards code must be able to use the whole
  -- Learning Path, which is only true if the engine cannot see one.
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

  -- STEP 7 PHASE 6, (2): nor grade or age.
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

  -- STEP 7 PHASE 6, (3): proposing is not deciding. Nothing in the path engine
  -- may write to the profile - not on generation, not on approval, and not when
  -- a family finishes a step.
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

  -- STEP 7 PHASE 6, (4): the loop that must not exist. Evidence may never point
  -- at a path. If student_skill_events could name a path node, "it was on her
  -- plan" would become a reason to believe she can do it.
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

  -- STEP 7 PHASE 6, (5): an approved path is not rewritten in place, and the
  -- guards that make that true are checked by name.
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

end;
$fn$;

select app.assert_schema_invariants();
