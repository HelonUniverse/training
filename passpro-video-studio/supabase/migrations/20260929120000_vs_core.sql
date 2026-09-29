-- ============================================================================
-- Video Studio CORE schema (provider- and subject-independent)
--
-- Additive only. Creates vs_* objects; never alters existing PassPro tables.
-- Requires (already present in PassPro): auth.users, public.is_admin().
--
-- Tables (8):
--   vs_settings          budgets, provider pricing, kill switch (key → jsonb)
--   vs_series            series bible
--   vs_characters        persistent characters (voice + visual identity)
--   vs_assets            reusable assets: locations, props, reference images,
--                        voice samples (files live in Storage)
--   vs_episodes          script, plan hash, approval, timeline, render settings
--   vs_scenes            scene list per episode
--   vs_clips             clips; dialogue / continuity / versions as jsonb
--   vs_generation_jobs   async jobs: clip generation, voice, render
--   vs_cost_ledger       append-only money log (authorizations, reservations,
--                        actuals, releases)
--
-- Money-moving functions are SECURITY DEFINER and granted only to
-- service_role (the server). Approval is granted to authenticated admins,
-- because approval must carry a real human identity (auth.uid()).
-- ============================================================================

-- ---------------------------------------------------------------- helpers

create or replace function public.vs_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------- settings

create table public.vs_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users on delete set null
);

comment on table public.vs_settings is
  'Global Video Studio configuration. Keys: budget (limits), provider_pricing (price table), generation (kill switch, concurrency).';

create trigger vs_settings_touch before update on public.vs_settings
  for each row execute function public.vs_touch_updated_at();

-- Development safety defaults. Paid generation is OFF until explicitly enabled.
insert into public.vs_settings (key, value) values
  ('budget', jsonb_build_object(
      'max_cost_per_clip_usd', 3,
      'max_cost_per_episode_usd', 30,
      'max_daily_spend_usd', 40,
      'max_retry_budget_per_episode_usd', 5,
      'timezone', 'America/New_York')),
  ('generation', jsonb_build_object(
      'enabled', true,
      'paid_providers_enabled', false,
      'max_concurrent_jobs', 2)),
  ('provider_pricing', jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object(
        'provider', 'mock', 'model', 'mock-video-1', 'resolution', '*',
        'unit', 'per_output_second', 'price_usd', 0.10, 'verified', true,
        'simulated', true, 'source_url', null,
        'notes', 'Simulated price so the mock workflow exercises budgets and the ledger. No money is spent.'),
      jsonb_build_object(
        'provider', 'minimax', 'model', 'MiniMax-H3', 'resolution', '2K',
        'unit', 'per_output_second', 'price_usd', null, 'verified', false,
        'simulated', false,
        'source_url', 'https://platform.minimax.io/docs/guides/pricing-paygo',
        'notes', 'NOT CONFIRMED. Fill price_usd and set verified=true only after checking the official page.'))))
on conflict (key) do nothing;

-- ---------------------------------------------------------------- series

create table public.vs_series (
  id              uuid primary key default gen_random_uuid(),
  slug            text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  name            text not null,
  language        text not null default 'es',
  target_audience text not null default '',
  visual_style    text not null default '',
  -- generation_rules[], continuity_rules[], negative_prompt, defaults
  -- {provider, model, resolution, ratio}, content_lock_scopes[] (layer hook)
  bible           jsonb not null default '{}'::jsonb,
  created_by      uuid references auth.users on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger vs_series_touch before update on public.vs_series
  for each row execute function public.vs_touch_updated_at();

-- ---------------------------------------------------------------- characters

create table public.vs_characters (
  id                 uuid primary key default gen_random_uuid(),
  series_id          uuid not null references public.vs_series on delete cascade,
  slug               text not null check (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  name               text not null,
  aliases            text[] not null default '{}',
  age                integer check (age is null or age between 0 and 130),
  description        text not null default '',
  personality        text[] not null default '{}',
  wardrobe           text not null default '',
  visual_prompt      text not null default '',
  negative_prompt    text not null default '',
  continuity_notes   text not null default '',
  rules              text[] not null default '{}',
  voice_only         boolean not null default false,
  -- {provider, voice_id, settings{}, description, master_sample_asset_id}
  voice              jsonb not null default '{}'::jsonb,
  -- primary reference image; more images are vs_assets rows with character_id
  primary_reference_asset_id uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (series_id, slug)
);

create trigger vs_characters_touch before update on public.vs_characters
  for each row execute function public.vs_touch_updated_at();

-- ---------------------------------------------------------------- assets

create table public.vs_assets (
  id               uuid primary key default gen_random_uuid(),
  series_id        uuid not null references public.vs_series on delete cascade,
  kind             text not null check (kind in
                     ('location', 'prop', 'reference_image', 'voice_sample', 'style_reference')),
  slug             text not null check (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  name             text not null,
  aliases          text[] not null default '{}',
  description      text not null default '',
  visual_prompt    text not null default '',
  negative_prompt  text not null default '',
  continuity_notes text not null default '',
  -- owner: a reference image / voice sample belongs to a character or to
  -- another asset (e.g. a location's reference image)
  character_id     uuid references public.vs_characters on delete cascade,
  parent_asset_id  uuid references public.vs_assets on delete cascade,
  -- file in the private 'video-studio' bucket; null for pure definitions
  storage_path     text,
  mime_type        text,
  status           text not null default 'ready'
                     check (status in ('pending_upload', 'ready', 'retired')),
  metadata         jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (series_id, slug),
  check (kind not in ('reference_image', 'voice_sample')
         or character_id is not null or parent_asset_id is not null),
  check (status <> 'ready' or kind in ('location', 'prop') or storage_path is not null)
);

create index vs_assets_character_idx on public.vs_assets (character_id);
create index vs_assets_parent_idx on public.vs_assets (parent_asset_id);

create trigger vs_assets_touch before update on public.vs_assets
  for each row execute function public.vs_touch_updated_at();

alter table public.vs_characters
  add constraint vs_characters_primary_ref_fk
  foreign key (primary_reference_asset_id) references public.vs_assets on delete set null;

-- ---------------------------------------------------------------- episodes

create table public.vs_episodes (
  id                uuid primary key default gen_random_uuid(),
  series_id         uuid not null references public.vs_series on delete restrict,
  number            integer not null check (number >= 0),
  title             text not null,
  language          text not null default 'es',
  target_duration_s integer check (target_duration_s is null or target_duration_s > 0),
  script            text not null default '',
  script_sha256     text,
  status            text not null default 'DRAFT' check (status in
                      ('DRAFT', 'ANALYZED', 'CONTENT_CONFLICT', 'APPROVED',
                       'GENERATING', 'IN_REVIEW', 'RENDERING', 'RENDERED', 'PUBLISHED')),
  plan_version      integer not null default 0,
  -- sha256 of the editable plan; approval is bound to it
  plan_hash         text,
  -- planner output: warnings, validation issues, estimate summary
  analysis          jsonb not null default '{}'::jsonb,
  -- current approval {plan_hash, approved_by, approved_at, authorized_max_usd,
  -- retry_budget_usd, estimated_total_usd}; full history lives in the ledger
  approval          jsonb,
  -- ordered [{clip_id, version, enabled, transition}]
  timeline          jsonb not null default '[]'::jsonb,
  render_settings   jsonb not null default '{"captions": true, "caption_language": "es"}'::jsonb,
  -- set only when a final render is published into PassPro's public.videos
  published_video_id uuid,
  created_by        uuid references auth.users on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (series_id, number)
);

create trigger vs_episodes_touch before update on public.vs_episodes
  for each row execute function public.vs_touch_updated_at();

-- ---------------------------------------------------------------- scenes

create table public.vs_scenes (
  id                uuid primary key default gen_random_uuid(),
  episode_id        uuid not null references public.vs_episodes on delete cascade,
  ord               integer not null check (ord >= 1),
  heading           text not null default '',
  location_asset_id uuid references public.vs_assets on delete set null,
  summary           text not null default '',
  created_at        timestamptz not null default now(),
  unique (episode_id, ord)
);

-- ---------------------------------------------------------------- clips

create table public.vs_clips (
  id                  uuid primary key default gen_random_uuid(),
  episode_id          uuid not null references public.vs_episodes on delete cascade,
  scene_id            uuid not null references public.vs_scenes on delete cascade,
  ord                 integer not null check (ord >= 1),
  duration_estimate_s numeric(6,2) not null check (duration_estimate_s > 0),
  location_asset_id   uuid references public.vs_assets on delete set null,
  character_ids       uuid[] not null default '{}',
  -- [{speaker_character_id, speaker_label, text, source_line, est_start_s, est_end_s, delivery}]
  dialogue            jsonb not null default '[]'::jsonb,
  action              text not null default '',
  camera_direction    text not null default '',
  visual_prompt       text not null default '',
  -- {mode: native|dub, notes[]}
  audio_requirements  jsonb not null default '{"mode": "native"}'::jsonb,
  reference_asset_ids uuid[] not null default '{}',
  -- {from_previous, into_next}
  continuity          jsonb not null default '{}'::jsonb,
  estimated_cost_usd  numeric(10,4),
  pricing_verified    boolean not null default false,
  status              text not null default 'PLANNED' check (status in
                        ('PLANNED', 'APPROVED', 'GENERATING', 'COMPLETE',
                         'FAILED', 'NEEDS_REVIEW', 'LOCKED')),
  -- validation issues from all layers (content locks, fidelity, pricing)
  issues              jsonb not null default '[]'::jsonb,
  -- never overwritten: [{version, job_id, provider, model, prompt,
  --   reference_asset_ids, settings, cost_usd, storage_path, duration_s,
  --   created_at, deleted_at}]
  versions            jsonb not null default '[]'::jsonb,
  selected_version    integer,
  edited_by_human     boolean not null default false,
  updated_at          timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  unique (episode_id, ord) deferrable initially immediate
);

create index vs_clips_scene_idx on public.vs_clips (scene_id);

create trigger vs_clips_touch before update on public.vs_clips
  for each row execute function public.vs_touch_updated_at();

-- ---------------------------------------------------------------- jobs

create table public.vs_generation_jobs (
  id                  uuid primary key default gen_random_uuid(),
  job_type            text not null check (job_type in ('clip', 'voice', 'render')),
  episode_id          uuid not null references public.vs_episodes on delete cascade,
  clip_id             uuid references public.vs_clips on delete set null,
  provider            text not null,
  provider_model      text,
  provider_job_id     text,
  -- a submission is never repeated for the same key (no double billing)
  idempotency_key     text not null unique,
  status              text not null default 'RESERVED' check (status in
                        ('RESERVED', 'SUBMITTED', 'QUEUED', 'RUNNING', 'SUCCEEDED',
                         'FAILED', 'CANCELLED', 'NEEDS_REVIEW')),
  is_regeneration     boolean not null default false,
  -- compiled prompt, reference asset ids, settings, render timeline snapshot
  request             jsonb not null default '{}'::jsonb,
  cost_estimate_usd   numeric(10,4) not null default 0,
  actual_cost_usd     numeric(10,4),
  usage               jsonb,
  error               jsonb,
  output_url          text,
  output_storage_path text,
  attempts            integer not null default 0,
  claimed_by          text,
  claimed_at          timestamptz,
  submitted_at        timestamptz,
  completed_at        timestamptz,
  created_by          uuid references auth.users on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (job_type <> 'clip' or clip_id is not null)
);

create index vs_jobs_episode_idx on public.vs_generation_jobs (episode_id);
create index vs_jobs_open_idx on public.vs_generation_jobs (status)
  where status in ('RESERVED', 'SUBMITTED', 'QUEUED', 'RUNNING');
create unique index vs_jobs_provider_job_idx
  on public.vs_generation_jobs (provider, provider_job_id) where provider_job_id is not null;

create trigger vs_jobs_touch before update on public.vs_generation_jobs
  for each row execute function public.vs_touch_updated_at();

-- ---------------------------------------------------------------- ledger

create table public.vs_cost_ledger (
  id          bigint generated always as identity primary key,
  episode_id  uuid not null references public.vs_episodes on delete restrict,
  scene_id    uuid,
  clip_id     uuid,
  job_id      uuid references public.vs_generation_jobs on delete restrict,
  entry_type  text not null check (entry_type in
                ('authorization', 'reservation', 'actual', 'release', 'adjustment')),
  category    text not null check (category in
                ('initial', 'regeneration', 'voice', 'planner', 'render', 'retry_budget')),
  provider    text,
  amount_usd  numeric(12,4) not null check (amount_usd >= 0),
  simulated   boolean not null default false,
  metadata    jsonb not null default '{}'::jsonb,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create index vs_ledger_episode_idx on public.vs_cost_ledger (episode_id);
create index vs_ledger_created_idx on public.vs_cost_ledger (created_at);

comment on table public.vs_cost_ledger is
  'Append-only. committed spend = reservations - releases + actuals. Authorizations are caps, not spend.';

create or replace function public.vs_ledger_is_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'vs_cost_ledger is append-only; write an adjustment entry instead';
end;
$$;

create trigger vs_ledger_no_update before update or delete on public.vs_cost_ledger
  for each row execute function public.vs_ledger_is_append_only();

-- ---------------------------------------------------------------- views

-- Spend per episode / scene / clip / provider / category.
create view public.vs_cost_summary with (security_invoker = true) as
select
  episode_id, scene_id, clip_id, provider, category, simulated,
  sum(case entry_type when 'actual' then amount_usd else 0 end)           as actual_usd,
  sum(case entry_type when 'reservation' then amount_usd
                      when 'release' then -amount_usd else 0 end)         as open_reservations_usd,
  sum(case entry_type when 'authorization' then amount_usd else 0 end)    as authorized_usd
from public.vs_cost_ledger
group by episode_id, scene_id, clip_id, provider, category, simulated;

-- ---------------------------------------------------------------- RLS

alter table public.vs_settings        enable row level security;
alter table public.vs_series          enable row level security;
alter table public.vs_characters      enable row level security;
alter table public.vs_assets          enable row level security;
alter table public.vs_episodes        enable row level security;
alter table public.vs_scenes          enable row level security;
alter table public.vs_clips           enable row level security;
alter table public.vs_generation_jobs enable row level security;
alter table public.vs_cost_ledger     enable row level security;

-- Admins edit the series bible (series, characters, assets) directly.
create policy vs_series_admin     on public.vs_series     for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy vs_characters_admin on public.vs_characters for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy vs_assets_admin     on public.vs_assets     for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Episodes, scenes and clips are READ-ONLY to clients. Every write goes
-- through the server (which re-validates content, recomputes the plan hash
-- and estimates) or through vs_approve_episode. Otherwise a client could
-- hand-write an approval or clear a CONTENT CONFLICT and skip the guards.
create policy vs_episodes_read on public.vs_episodes for select to authenticated using (public.is_admin());
create policy vs_scenes_read   on public.vs_scenes   for select to authenticated using (public.is_admin());
create policy vs_clips_read    on public.vs_clips    for select to authenticated using (public.is_admin());

-- Money and jobs: admins may READ; only the server (service_role, which
-- bypasses RLS) and the SECURITY DEFINER functions below may WRITE.
create policy vs_settings_read on public.vs_settings        for select to authenticated using (public.is_admin());
create policy vs_jobs_read     on public.vs_generation_jobs for select to authenticated using (public.is_admin());
create policy vs_ledger_read   on public.vs_cost_ledger     for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------- money functions

-- Committed spend for an episode: open reservations + actuals. Authorizations
-- are caps, not spend. Simulated (mock) money counts, so the mock workflow
-- exercises exactly the same limits as paid mode.
create or replace function public.vs_committed(p_episode_id uuid, p_categories text[] default null)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case entry_type
                        when 'reservation' then amount_usd
                        when 'release'     then -amount_usd
                        when 'actual'      then amount_usd
                        else 0 end), 0)
  from vs_cost_ledger
  where episode_id = p_episode_id
    and (p_categories is null or category = any (p_categories))
    and category not in ('retry_budget')
$$;

create or replace function public.vs_committed_today()
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case entry_type
                        when 'reservation' then amount_usd
                        when 'release'     then -amount_usd
                        when 'actual'      then amount_usd
                        else 0 end), 0)
  from vs_cost_ledger
  where (created_at at time zone coalesce(
           (select value->>'timezone' from vs_settings where key = 'budget'), 'UTC'))::date
      = (now() at time zone coalesce(
           (select value->>'timezone' from vs_settings where key = 'budget'), 'UTC'))::date
$$;

-- Human approval of an episode plan. Binds the approval to the exact plan
-- hash, records the authorized cap in the ledger, and approves PLANNED clips.
create or replace function public.vs_approve_episode(
  p_episode_id uuid,
  p_plan_hash text,
  p_authorized_max_usd numeric,
  p_retry_budget_usd numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ep      vs_episodes;
  v_budget  jsonb;
  v_estimate numeric;
  v_blocking integer;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'VS_FORBIDDEN: only an admin user can approve generation';
  end if;

  select * into v_ep from vs_episodes where id = p_episode_id for update;
  if not found then raise exception 'VS_NOT_FOUND: episode %', p_episode_id; end if;
  if v_ep.plan_hash is null or v_ep.plan_hash <> p_plan_hash then
    raise exception 'VS_PLAN_CHANGED: the plan changed since it was reviewed; reload and review again';
  end if;

  -- a CONTENT CONFLICT can never be acknowledged away: fix the script or the lock
  select count(*) into v_blocking
  from vs_clips c, jsonb_array_elements(c.issues) i
  where c.episode_id = p_episode_id
    and (i->>'severity' = 'conflict'
         or (i->>'severity' = 'review' and coalesce((i->>'acknowledged')::boolean, false) = false));
  if v_blocking > 0 then
    raise exception 'VS_CONTENT_BLOCKED: % unresolved issue(s) (CONTENT CONFLICT or review) block approval', v_blocking;
  end if;

  if exists (select 1 from vs_clips where episode_id = p_episode_id and estimated_cost_usd is null) then
    raise exception 'VS_NO_ESTIMATE: every clip needs a cost estimate from confirmed pricing';
  end if;

  select value into v_budget from vs_settings where key = 'budget';
  -- total the approval must cover: initial spend already committed + what remains
  select coalesce(sum(estimated_cost_usd), 0) + vs_committed(p_episode_id, array['initial'])
    into v_estimate
  from vs_clips where episode_id = p_episode_id and status in ('PLANNED', 'APPROVED');

  if p_authorized_max_usd < v_estimate then
    raise exception 'VS_BUDGET: authorized max % is below the estimate %', p_authorized_max_usd, v_estimate;
  end if;
  if p_authorized_max_usd > (v_budget->>'max_cost_per_episode_usd')::numeric then
    raise exception 'VS_BUDGET: authorized max % exceeds the per-episode limit %',
      p_authorized_max_usd, v_budget->>'max_cost_per_episode_usd';
  end if;
  if p_retry_budget_usd < 0 or p_retry_budget_usd > (v_budget->>'max_retry_budget_per_episode_usd')::numeric then
    raise exception 'VS_BUDGET: retry budget % exceeds the limit %',
      p_retry_budget_usd, v_budget->>'max_retry_budget_per_episode_usd';
  end if;
  if exists (select 1 from vs_clips where episode_id = p_episode_id
             and estimated_cost_usd > (v_budget->>'max_cost_per_clip_usd')::numeric) then
    raise exception 'VS_BUDGET: at least one clip exceeds the per-clip limit %', v_budget->>'max_cost_per_clip_usd';
  end if;

  insert into vs_cost_ledger (episode_id, entry_type, category, amount_usd, metadata, created_by)
  values (p_episode_id, 'authorization', 'initial', p_authorized_max_usd,
          jsonb_build_object('plan_hash', p_plan_hash, 'estimated_total_usd', v_estimate), auth.uid());
  if p_retry_budget_usd > 0 then
    insert into vs_cost_ledger (episode_id, entry_type, category, amount_usd, metadata, created_by)
    values (p_episode_id, 'authorization', 'retry_budget', p_retry_budget_usd,
            jsonb_build_object('plan_hash', p_plan_hash), auth.uid());
  end if;

  update vs_clips set status = 'APPROVED' where episode_id = p_episode_id and status = 'PLANNED';
  update vs_episodes set
    status = 'APPROVED',
    approval = jsonb_build_object(
      'plan_hash', p_plan_hash, 'approved_by', auth.uid(), 'approved_at', now(),
      'authorized_max_usd', p_authorized_max_usd, 'retry_budget_usd', p_retry_budget_usd,
      'estimated_total_usd', v_estimate)
  where id = p_episode_id;

  return jsonb_build_object('estimated_total_usd', v_estimate, 'authorized_max_usd', p_authorized_max_usd,
                            'retry_budget_usd', p_retry_budget_usd);
end;
$$;

-- Explicit extra authorization for regenerating ONE clip (beyond the retry budget).
create or replace function public.vs_authorize_regeneration(p_clip_id uuid, p_max_usd numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_clip vs_clips; v_budget jsonb;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'VS_FORBIDDEN: only an admin user can authorize a regeneration';
  end if;
  select * into v_clip from vs_clips where id = p_clip_id;
  if not found then raise exception 'VS_NOT_FOUND: clip %', p_clip_id; end if;
  select value into v_budget from vs_settings where key = 'budget';
  if p_max_usd <= 0 or p_max_usd > (v_budget->>'max_cost_per_clip_usd')::numeric then
    raise exception 'VS_BUDGET: regeneration authorization must be > 0 and <= per-clip limit';
  end if;
  insert into vs_cost_ledger (episode_id, scene_id, clip_id, entry_type, category, amount_usd, created_by, metadata)
  values (v_clip.episode_id, v_clip.scene_id, v_clip.id, 'authorization', 'regeneration', p_max_usd, auth.uid(),
          jsonb_build_object('scope', 'single_clip'));
end;
$$;

-- The ONLY path to a provider submission. Atomically checks every limit,
-- creates the job row and a ledger reservation. Idempotent per key: the same
-- key never reserves (or bills) twice. Server-only.
create or replace function public.vs_reserve_generation(
  p_clip_id uuid,
  p_provider text,
  p_model text,
  p_estimate_usd numeric,
  p_idempotency_key text,
  p_is_regeneration boolean,
  p_simulated boolean,
  p_request jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_existing  uuid;
  v_clip      vs_clips;
  v_ep        vs_episodes;
  v_budget    jsonb;
  v_gen       jsonb;
  v_job_id    uuid;
  v_category  text;
  v_authorized numeric;
  v_regen_cap numeric;
  v_regen_used numeric;
begin
  select id into v_existing from vs_generation_jobs where idempotency_key = p_idempotency_key;
  if found then return v_existing; end if;

  -- serialize all reservations so daily/episode totals cannot race
  perform pg_advisory_xact_lock(hashtext('vs_budget'));

  select value into v_gen from vs_settings where key = 'generation';
  if not coalesce((v_gen->>'enabled')::boolean, false) then
    raise exception 'VS_DISABLED: generation kill switch is off';
  end if;
  if not p_simulated and not coalesce((v_gen->>'paid_providers_enabled')::boolean, false) then
    raise exception 'VS_PAID_DISABLED: paid providers are disabled in vs_settings.generation';
  end if;

  select * into v_clip from vs_clips where id = p_clip_id for update;
  if not found then raise exception 'VS_NOT_FOUND: clip %', p_clip_id; end if;
  select * into v_ep from vs_episodes where id = v_clip.episode_id;

  if v_ep.approval is null or v_ep.approval->>'plan_hash' is distinct from v_ep.plan_hash then
    raise exception 'VS_NOT_APPROVED: episode plan is not approved (or changed after approval)';
  end if;
  if exists (select 1 from jsonb_array_elements(v_clip.issues) i
             where i->>'severity' = 'conflict'
                or (i->>'severity' = 'review' and coalesce((i->>'acknowledged')::boolean, false) = false)) then
    raise exception 'VS_CONTENT_BLOCKED: clip has an unresolved CONTENT CONFLICT / review issue';
  end if;
  if v_clip.status = 'LOCKED' then
    raise exception 'VS_LOCKED: clip is locked';
  end if;
  if not p_is_regeneration and v_clip.status <> 'APPROVED' then
    raise exception 'VS_NOT_APPROVED: clip status is %', v_clip.status;
  end if;
  if p_is_regeneration and v_clip.status not in ('COMPLETE', 'FAILED', 'NEEDS_REVIEW') then
    raise exception 'VS_STATE: clip in status % cannot be regenerated', v_clip.status;
  end if;

  select value into v_budget from vs_settings where key = 'budget';
  if p_estimate_usd > (v_budget->>'max_cost_per_clip_usd')::numeric then
    raise exception 'VS_BUDGET_CLIP: estimate % exceeds per-clip limit %', p_estimate_usd, v_budget->>'max_cost_per_clip_usd';
  end if;

  v_authorized := (v_ep.approval->>'authorized_max_usd')::numeric;
  if vs_committed(v_ep.id, array['initial', 'regeneration']) + p_estimate_usd
       > least(v_authorized + coalesce((v_ep.approval->>'retry_budget_usd')::numeric, 0)
               + coalesce((select sum(amount_usd) from vs_cost_ledger
                           where episode_id = v_ep.id and entry_type = 'authorization'
                             and category = 'regeneration'), 0),
               (v_budget->>'max_cost_per_episode_usd')::numeric) then
    raise exception 'VS_BUDGET_EPISODE: would exceed the authorized / per-episode maximum';
  end if;

  if vs_committed_today() + p_estimate_usd > (v_budget->>'max_daily_spend_usd')::numeric then
    raise exception 'VS_BUDGET_DAILY: would exceed the daily limit %', v_budget->>'max_daily_spend_usd';
  end if;

  if p_is_regeneration then
    v_category := 'regeneration';
    select coalesce((v_ep.approval->>'retry_budget_usd')::numeric, 0)
         + coalesce(sum(amount_usd), 0)
      into v_regen_cap
      from vs_cost_ledger
     where episode_id = v_ep.id and entry_type = 'authorization' and category = 'regeneration';
    v_regen_used := vs_committed(v_ep.id, array['regeneration']);
    if v_regen_used + p_estimate_usd > v_regen_cap then
      raise exception 'VS_NEEDS_AUTHORIZATION: regeneration needs approval (retry budget % used of %)',
        v_regen_used, v_regen_cap;
    end if;
  else
    v_category := 'initial';
    if v_authorized is null or vs_committed(v_ep.id, array['initial']) + p_estimate_usd > v_authorized then
      raise exception 'VS_BUDGET_EPISODE: would exceed the approved maximum %', v_authorized;
    end if;
  end if;

  insert into vs_generation_jobs (job_type, episode_id, clip_id, provider, provider_model,
                                  idempotency_key, status, is_regeneration, request,
                                  cost_estimate_usd)
  values ('clip', v_ep.id, v_clip.id, p_provider, p_model, p_idempotency_key, 'RESERVED',
          p_is_regeneration, coalesce(p_request, '{}'::jsonb), p_estimate_usd)
  returning id into v_job_id;

  insert into vs_cost_ledger (episode_id, scene_id, clip_id, job_id, entry_type, category,
                              provider, amount_usd, simulated)
  values (v_ep.id, v_clip.scene_id, v_clip.id, v_job_id, 'reservation', v_category,
          p_provider, p_estimate_usd, p_simulated);

  update vs_clips set status = 'GENERATING' where id = v_clip.id;
  return v_job_id;
end;
$$;

-- Close a job's money: release its reservation and record the actual cost.
create or replace function public.vs_settle_job(
  p_job_id uuid,
  p_status text,
  p_actual_cost_usd numeric,
  p_usage jsonb default null,
  p_error jsonb default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_job vs_generation_jobs; v_res numeric; v_sim boolean; v_cat text;
begin
  if p_status not in ('SUCCEEDED', 'FAILED', 'CANCELLED', 'NEEDS_REVIEW') then
    raise exception 'VS_STATE: % is not a terminal status', p_status;
  end if;
  select * into v_job from vs_generation_jobs where id = p_job_id for update;
  if not found then raise exception 'VS_NOT_FOUND: job %', p_job_id; end if;
  if v_job.completed_at is not null then return; end if;   -- already settled

  select coalesce(sum(case entry_type when 'reservation' then amount_usd
                                      when 'release' then -amount_usd else 0 end), 0),
         bool_or(simulated), min(category)
    into v_res, v_sim, v_cat
    from vs_cost_ledger where job_id = p_job_id;

  if v_res > 0 then
    insert into vs_cost_ledger (episode_id, clip_id, job_id, entry_type, category, provider, amount_usd, simulated)
    select episode_id, clip_id, job_id, 'release', category, provider, v_res, simulated
      from vs_cost_ledger where job_id = p_job_id and entry_type = 'reservation' limit 1;
  end if;
  if coalesce(p_actual_cost_usd, 0) > 0 then
    insert into vs_cost_ledger (episode_id, scene_id, clip_id, job_id, entry_type, category, provider, amount_usd, simulated, metadata)
    select episode_id, scene_id, clip_id, job_id, 'actual', category, provider, p_actual_cost_usd, simulated,
           jsonb_build_object('usage', p_usage)
      from vs_cost_ledger where job_id = p_job_id and entry_type = 'reservation' limit 1;
  end if;

  update vs_generation_jobs
     set status = p_status, actual_cost_usd = coalesce(p_actual_cost_usd, 0),
         usage = p_usage, error = p_error, completed_at = now()
   where id = p_job_id;
end;
$$;

-- Render worker: claim one queued render job (FOR UPDATE SKIP LOCKED).
create or replace function public.vs_claim_render_job(p_worker text)
returns public.vs_generation_jobs
language plpgsql security definer set search_path = public as $$
declare v_job vs_generation_jobs;
begin
  select * into v_job from vs_generation_jobs
   where job_type = 'render' and status = 'QUEUED'
   order by created_at
   for update skip locked
   limit 1;
  if not found then return null; end if;
  update vs_generation_jobs
     set status = 'RUNNING', claimed_by = p_worker, claimed_at = now(), attempts = attempts + 1
   where id = v_job.id
  returning * into v_job;
  return v_job;
end;
$$;

create or replace function public.vs_complete_render_job(
  p_job_id uuid, p_ok boolean, p_output_storage_path text, p_error jsonb default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  update vs_generation_jobs
     set status = case when p_ok then 'SUCCEEDED' else 'FAILED' end,
         output_storage_path = p_output_storage_path, error = p_error, completed_at = now()
   where id = p_job_id and job_type = 'render' and status = 'RUNNING';
  if not found then raise exception 'VS_STATE: render job % is not running', p_job_id; end if;
  update vs_episodes set status = case when p_ok then 'RENDERED' else 'IN_REVIEW' end
   where id = (select episode_id from vs_generation_jobs where id = p_job_id);
end;
$$;

revoke all on function public.vs_committed(uuid, text[])              from public, anon, authenticated;
revoke all on function public.vs_committed_today()                    from public, anon, authenticated;
revoke all on function public.vs_reserve_generation(uuid, text, text, numeric, text, boolean, boolean, jsonb) from public, anon, authenticated;
revoke all on function public.vs_settle_job(uuid, text, numeric, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.vs_claim_render_job(text)               from public, anon, authenticated;
revoke all on function public.vs_complete_render_job(uuid, boolean, text, jsonb) from public, anon, authenticated;
revoke all on function public.vs_approve_episode(uuid, text, numeric, numeric) from public, anon;
revoke all on function public.vs_authorize_regeneration(uuid, numeric) from public, anon;

grant execute on function public.vs_approve_episode(uuid, text, numeric, numeric) to authenticated;
grant execute on function public.vs_authorize_regeneration(uuid, numeric)          to authenticated;
grant execute on function public.vs_committed(uuid, text[])                         to service_role;
grant execute on function public.vs_committed_today()                               to service_role;
grant execute on function public.vs_reserve_generation(uuid, text, text, numeric, text, boolean, boolean, jsonb) to service_role;
grant execute on function public.vs_settle_job(uuid, text, numeric, jsonb, jsonb)   to service_role;
grant execute on function public.vs_claim_render_job(text)                          to service_role;
grant execute on function public.vs_complete_render_job(uuid, boolean, text, jsonb) to service_role;

-- ---------------------------------------------------------------- storage

insert into storage.buckets (id, name, public)
values ('video-studio', 'video-studio', false)
on conflict (id) do nothing;

create policy vs_storage_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'video-studio' and public.is_admin());
create policy vs_storage_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'video-studio' and public.is_admin());
create policy vs_storage_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'video-studio' and public.is_admin());
