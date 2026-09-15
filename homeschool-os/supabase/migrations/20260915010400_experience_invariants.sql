-- =============================================================================
-- 0113  The experience layer cannot become a gradebook
-- =============================================================================
-- Every phase has had one characteristic way of going wrong. Phase 6's was a
-- proposal turning into a verdict. Phase 1's was the catalogue starting to
-- decide. This one's is the quietest and the most tempting: a child does the
-- work, and somewhere between "she finished it" and "she can do it" a line gets
-- crossed that nobody notices, because crossing it feels like being helpful.
--
--   she finished the worksheet        -> she knows equivalent fractions
--   she uploaded a photo              -> that is evidence
--   the session lasted 40 minutes     -> she worked hard, so she must have learned
--   it was in Today and she did it    -> mark it off
--
-- Every one of those is refused here rather than in a review.
--
--   1.  The experience layer may not read the standards catalogue.
--   2.  It may not read grade or age.
--   3.  It may not write to the profile - no session, completion, note,
--       artifact or accepted proposal ever touches student_skills.
--   4.  It may not name a child's computed state at all.
--   5.  It may not write to the learning path.
--   6.  Evidence may not point back at a session, an artifact, a Today
--       decision or a proposal. Being in Today is not a reason to believe
--       anything, and the column that would make it one cannot exist.
--   7.  The evidence bridge goes through the STEP 5 function and nowhere else:
--       accept_evidence_proposal may not write learning_evidence itself.
--   8.  Duration is never derived from the clock. A session left open
--       overnight did not take fourteen hours.
--   9.  The outcome vocabulary is exactly six labels and none of them is a
--       failure, and no failure may arrive as a column instead.
--   10. Sessions and decisions are not rewritten after the fact.
-- =============================================================================

-- --- an occasion that happened is not edited afterwards ----------------------
-- A session is a record of a morning. Moving its start time, changing who
-- started it, or quietly turning `explored` into `completed` a week later would
-- make the record something a family cannot rely on - and the whole reason to
-- keep sessions separate from activities was so that history would survive.

create or replace function app.forbid_session_rewrite()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  if new.activity_id is distinct from old.activity_id
     or new.student_id is distinct from old.student_id
     or new.started_at is distinct from old.started_at
     or new.initiated_by is distinct from old.initiated_by then
    raise exception
      'when an occasion happened, and whose it was, are not editable';
  end if;
  if old.status = 'ended' then
    if new.status is distinct from old.status
       or new.outcome is distinct from old.outcome
       or new.ended_at is distinct from old.ended_at
       or new.ended_by is distinct from old.ended_by then
      raise exception
        'that morning is already on the record. Working on it again is a new '
        'session, not an edit to this one'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $fn$;

-- --- an answer is given once -------------------------------------------------
-- Re-deciding a proposal in place would erase the fact that a family was asked
-- and said no, which is exactly the information that stops them being asked
-- forever.

create or replace function app.forbid_proposal_rewrite()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  if new.activity_id is distinct from old.activity_id
     or new.student_id is distinct from old.student_id
     or new.skill_id is distinct from old.skill_id
     or new.offered_at is distinct from old.offered_at then
    raise exception 'what was offered, and about whom, are not editable';
  end if;
  if old.status <> 'offered' and new.status is distinct from old.status then
    raise exception
      'this has already been answered. Asking again is a new offer, not an edit '
      'to the answer that was given'
      using errcode = 'check_violation';
  end if;
  return new;
end $fn$;

revoke all on function app.forbid_session_rewrite() from public, anon, authenticated;
revoke all on function app.forbid_proposal_rewrite() from public, anon, authenticated;

create trigger las_occasions_are_not_rewritten
  before update on public.learning_activity_sessions
  for each row execute function app.forbid_session_rewrite();

create trigger lep_answers_are_not_rewritten
  before update on public.learning_evidence_proposals
  for each row execute function app.forbid_proposal_rewrite();

-- An artifact association is a fact about what was attached and when. It is
-- removed by removing the document, through the machinery that already governs
-- a child's files.
create trigger laa_artifacts_are_append_only
  before update or delete on public.learning_activity_artifacts
  for each row execute function app.forbid_mutation();

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

  -- ===========================================================================
  -- STEP 8 PHASE 1
  -- ===========================================================================

  -- (1) The activity layer may not reach the reference catalogue. A parent who
  -- never opens a standards code must be able to use the whole thing, which is
  -- only true if the selector cannot see one.
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

  -- (2) Nor grade or age. What a child does next follows from what she has
  -- shown, not from her birthday and not from what a fourth grader is expected
  -- to have finished.
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

  -- (3) Selecting is not evidence, starting is not evidence, completing is not
  -- mastery. Nothing in this layer may write to the profile - not on selection,
  -- not on completion, and not on a skip.
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

  -- and the same functions may not name the computed-state columns at all, so
  -- that a future "completion nudges the state" cannot be written quietly.
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

  -- (4) The loop that must not exist. If evidence could name an activity, "it
  -- was on her list" would become a reason to believe she can do it.
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

  -- (5) Automatic selection reads CONFIRMED mappings only, and the predicate is
  -- checked by name rather than trusted. Dropping one word from this function
  -- would hand children material nobody had reviewed, silently and with no
  -- other symptom.
  if not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'learning_activity_candidates'
       and p.prosrc ~ 'and rs\.confirmed') then
    raise exception
      'app.learning_activity_candidates no longer requires a confirmed mapping. An unreviewed guess about what a worksheet teaches may not decide what a child receives';
  end if;

  -- (6) The activity layer may not write to the path. "There is nothing for
  -- this skill" is an answer, not a reason to move the child somewhere with
  -- better material.
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

  -- (7) And the arrow only goes one way: the PATH may not read availability. If
  -- it could, a lapsed subscription would quietly reorder what a family
  -- explores, which is a billing state deciding an education.
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

  -- (8) A goal target does not automatically become this week's work, and the
  -- trigger that makes that structural is checked by name.
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

  -- and the constraints that keep provenance honest.
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

  -- (9) The lifecycle is exactly nine labels, and not one of them is a failure.
  -- skipped and not_today are ordinary facts about a week; the day somebody
  -- adds 'failed' or 'missed' here is the day a parent starts lying to the app
  -- to keep her child's record clean.
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

  -- nor may a failure arrive as a column instead.
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

  -- (9b) and the three endings that must stay endings. A graph that lets
  -- `completed` go back to `started` is a graph that lets a family delete a
  -- morning from the record, and the whole reason for having one is that it
  -- does not.
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


  -- STEP 8 PHASE 1, alignment: one definition of "the curriculum this family is
  -- using". Both resource selectors prefer material from a course the child is
  -- enrolled in, and both must mean ACTIVELY enrolled. A course finished in May
  -- is a fact about last year, and a path that attached material from it while
  -- the activity engine offered something else would be Nestra giving a family
  -- two answers to one question.
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

  -- (10) and the retired numeric semantics stay retired here too.
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

  -- (1) The experience layer may not reach the reference catalogue.
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
                       'decline_evidence_proposal', 'activity_history')
     and p.prosrc ~ '\m(standards|skill_standards|standards_texts|standards_domains|standards_crosswalks|standards_framework_versions|resource_standards)\M';
  if v_bad is not null then
    raise exception
      'the experience layer reads the standards catalogue: %. A child does not need a benchmark code to do some fractions with measuring cups', v_bad;
  end if;

  -- (2) Nor grade or age. Today is what this family is doing, never what a
  -- child of this age is supposed to have finished by now.
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
                       'decline_evidence_proposal', 'activity_history')
     and p.prosrc ~ '\m(grade_level|grade_equivalent|grade_band|normalized_grade|date_of_birth|birthdate)\M';
  if v_bad is not null then
    raise exception
      'the experience layer routes on grade or age: %. The same evidence and the same approved path give the same Today at nine and at fourteen', v_bad;
  end if;

  -- (3) THE CENTRAL ONE. Nothing in this layer writes to the profile - not
  -- starting, not finishing, not a note, not a photo, and not accepting an
  -- evidence offer.
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
                       'decline_evidence_proposal', 'activity_history')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(student_skills|student_skill_events|student_skill_overrides|diagnostic_observations)\M';
  if v_bad is not null then
    raise exception
      'the experience layer writes to the profile: %. Finishing a worksheet is not learning a skill, and the gap between them is a person', v_bad;
  end if;

  -- and may not name the computed-state columns at all, so that a future
  -- "completing nudges the state" cannot be written quietly.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.proname in ('today_items', 'today_card', 'today_decide',
                       'learning_activity_launch', 'today', 'explain_today_item',
                       'start_learning_session', 'pause_learning_session',
                       'end_learning_session', 'add_session_note',
                       'open_activity_resource', 'attach_activity_artifact',
                       'offer_activity_evidence', 'accept_evidence_proposal',
                       'decline_evidence_proposal', 'activity_history')
     and p.prosrc ~ '\m(skill_state|computed_state|effective_state|evidence_sufficiency)\M';
  if v_bad is not null then
    raise exception
      'the experience layer names a child''s computed state: %. A morning is a fact about a morning', v_bad;
  end if;

  -- (5) Nor may it rewrite the learning path.
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
                       'activity_history')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?(learning_paths|learning_path_nodes|learning_path_events)\M';
  if v_bad is not null then
    raise exception
      'the experience layer rewrites the learning path: %. Today reads the plan; it does not edit it', v_bad;
  end if;

  -- (6) The loops that must not exist. If evidence could name a session, a
  -- Today decision, an artifact or a proposal, then "it was on her list and she
  -- did it" would become a reason to believe she can do it.
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
       'learning_evidence_proposals', 'public.learning_evidence_proposals');
  if v_bad is not null then
    raise exception
      'evidence now points at something from the experience layer: %. Being in Today, or having finished something, is not a reason to believe anything about a child', v_bad;
  end if;

  -- (7) The bridge goes through the STEP 5 function and nowhere else. Writing
  -- learning_evidence directly here would mean the confirmation rules that
  -- function enforces could be skipped by a caller who did not know they
  -- existed.
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

  -- (8) Duration is reported, never derived. A session left open overnight did
  -- not take fourteen hours, and a false number in a record a family may hand
  -- to an evaluator is worse than no number at all.
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

  -- (9) The outcome vocabulary is exactly six labels, and not one of them is a
  -- failure. The day somebody adds `failed` here is the day a family learns to
  -- stop telling the product the truth about a hard morning.
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_bad
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'app' and t.typname = 'learning_session_outcome';
  if v_bad is distinct from
     'completed, partially_completed, explored, stopped, child_wants_more, revisit_later' then
    raise exception
      'app.learning_session_outcome must be exactly completed, partially_completed, explored, stopped, child_wants_more, revisit_later - found: %',
      coalesce(v_bad, '(missing)');
  end if;

  -- nor may a failure, a deadline or a score arrive as a column instead.
  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_bad
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('today_decisions', 'learning_activity_sessions',
                       'learning_activity_artifacts', 'learning_evidence_proposals')
     and a.attnum > 0 and not a.attisdropped
     and a.attname in ('failed', 'failure', 'missed', 'overdue', 'late', 'due_at',
                       'due_on', 'required', 'score', 'mastery_level', 'percent',
                       'percentage', 'grade_level');
  if v_bad is not null then
    raise exception
      'a morning is not a deadline and a child is not a percentage; % must not exist', v_bad;
  end if;

  -- (10) and the guards that keep the record from being rewritten.
  select string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('public.learning_activity_sessions'::regclass, 'las_occasions_are_not_rewritten'),
                 ('public.learning_evidence_proposals'::regclass, 'lep_answers_are_not_rewritten'),
                 ('public.learning_activity_artifacts'::regclass, 'laa_artifacts_are_append_only'))
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
                 ('public.learning_activity_artifacts'::regclass, 'laa_points_at_something_ck'))
         as x(rel, want)
   where not exists (select 1 from pg_catalog.pg_constraint k
                      where k.conrelid = x.rel and k.contype = 'c' and k.conname = x.want);
  if v_bad is not null then
    raise exception
      'an occasion or an evidence answer may now be recorded incompletely: % is missing', v_bad;
  end if;

  -- (11) A child may run her own morning without running her own curriculum.
  -- If student_self ever gains `create` on learning_activity she is choosing her
  -- own material; if she gains `approve` she is deciding what counts as
  -- evidence about herself. Both are her mother's.
  select string_agg(c.action::text, ', ' order by c.action::text) into v_bad
    from app.capabilities c
   where c.relationship = 'student_self' and c.resource = 'learning_activity'
     and c.action in ('create', 'delete', 'approve');
  if v_bad is not null then
    raise exception
      'a child may now % her own learning activities. Running a morning and choosing a curriculum are different powers, and deciding what counts as evidence about a child is not hers to make', v_bad;
  end if;

end;
$fn$;

select app.assert_schema_invariants();
