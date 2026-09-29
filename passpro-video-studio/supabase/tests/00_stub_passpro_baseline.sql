-- ============================================================================
-- LOCAL TEST ONLY. Minimal stand-in for the parts of the live PassPro /
-- Supabase database that the Video Studio migrations depend on, so the
-- migrations can be created and recreated from scratch on a throwaway
-- Postgres. Never run this against a real Supabase project.
-- ============================================================================

create extension if not exists pgcrypto;

do $$ begin
  create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin
  create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- auth ----------------------------------------------------------------------
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- PassPro objects the migrations reference (subset of real columns) --------
create table public.profiles (
  id uuid primary key references auth.users,
  role text not null default 'learner' check (role in ('learner', 'coach', 'admin'))
);

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create table public.exams (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name_es text,
  jurisdiction text,
  scored_questions integer,
  pretest_questions integer,
  time_minutes integer,
  pass_score integer
);

create table public.exam_blueprints (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid references public.exams,
  version text,
  effective_date date,
  source text,
  is_current boolean
);

create table public.videos (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid,
  lang text,
  provider text,
  url text,
  title text,
  duration_seconds integer
);

-- Same values as the live row inspected read-only on 2026-09-29.
insert into public.exams (code, name_es, jurisdiction, scored_questions, pretest_questions, time_minutes, pass_score)
values ('FL-2-14', 'Florida Agente de Vida (incluye Anualidad Variable) — 2-14', 'FL', 85, 10, 120, 70);
insert into public.exam_blueprints (exam_id, version, effective_date, source, is_current)
select id, '2026', date '2026-01-01',
       'Pearson VUE FL Life & Annuity (incl. Variable Contracts) 0214 content outline, 2026', true
from public.exams where code = 'FL-2-14';

-- storage -------------------------------------------------------------------
create schema storage;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (id text primary key, name text, public boolean default false);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;

-- test users ------------------------------------------------------------------
insert into auth.users values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000b', 'learner@test.local');
insert into public.profiles values
  ('00000000-0000-0000-0000-00000000000a', 'admin'),
  ('00000000-0000-0000-0000-00000000000b', 'learner');
