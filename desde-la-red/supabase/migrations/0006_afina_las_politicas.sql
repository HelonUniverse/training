-- ============================================================================
-- Afinado de las políticas. No cambia quién puede hacer qué: cambia cuánto
-- trabajo le cuesta a Postgres comprobarlo. Tres cosas que señaló su linter:
--
-- 1. `auth.uid()` dentro de una política se volvía a calcular por cada fila.
--    Envuelto en (select ...), Postgres lo resuelve una sola vez por consulta.
--
-- 2. Las políticas `for all` de las tablas de contenido también cubrían la
--    lectura, así que cada SELECT evaluaba dos políticas: la abierta y la de
--    administradoras. Se parten en insertar / editar / borrar, y la lectura
--    se queda con una sola.
--
-- 3. Las claves foráneas no tenían índice. Borrar una guía o un servicio
--    obligaba a recorrer las tablas que lo apuntan.
-- ============================================================================

-- ------------------------------------------------------------------ perfiles
drop policy if exists "perfil propio visible" on public.profiles;
create policy "perfil propio visible" on public.profiles
  for select using ((select auth.uid()) = id or (select public.is_admin()));

drop policy if exists "perfil propio editable" on public.profiles;
create policy "perfil propio editable" on public.profiles
  for update using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ----------------------------------------------------------------- contenido
-- La lectura se queda sola en su política; escribir se parte en tres.
do $$
declare t text;
begin
  foreach t in array array['guides','teachings','services','circles','live_events','path_questions']
  loop
    execute format('drop policy if exists "solo admin escribe" on public.%I', t);

    execute format('drop policy if exists "solo admin inserta" on public.%I', t);
    execute format(
      'create policy "solo admin inserta" on public.%I for insert
         with check ((select public.is_admin()))', t);

    execute format('drop policy if exists "solo admin edita" on public.%I', t);
    execute format(
      'create policy "solo admin edita" on public.%I for update
         using ((select public.is_admin())) with check ((select public.is_admin()))', t);

    execute format('drop policy if exists "solo admin borra" on public.%I', t);
    execute format(
      'create policy "solo admin borra" on public.%I for delete
         using ((select public.is_admin()))', t);
  end loop;
end $$;

-- --------------------------------------------------------------------- voces
drop policy if exists "escribo mis voces" on public.posts;
create policy "escribo mis voces" on public.posts
  for insert with check ((select auth.uid()) = author_id);

drop policy if exists "edito mis voces" on public.posts;
create policy "edito mis voces" on public.posts
  for update using ((select auth.uid()) = author_id)
  with check ((select auth.uid()) = author_id);

drop policy if exists "borro mis voces" on public.posts;
create policy "borro mis voces" on public.posts
  for delete using ((select auth.uid()) = author_id or (select public.is_admin()));

-- ---------------------------------------------------------- tablas personales
-- Aquí `for all` es una sola política, así que no se solapa con nada.
do $$
declare t text;
begin
  foreach t in array array['saved_teachings','read_teachings','circle_members',
                           'post_resonances','path_answers']
  loop
    execute format('drop policy if exists "solo lo mio" on public.%I', t);
    execute format(
      'create policy "solo lo mio" on public.%I for all
         using ((select auth.uid()) = user_id)
         with check ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- ------------------------------------------------------------------ reservas
-- Eran dos políticas de lectura solapadas. Ahora es una que dice las dos cosas.
drop policy if exists "solo lo mio" on public.bookings;
drop policy if exists "las admins ven las reservas" on public.bookings;

create policy "veo mis reservas" on public.bookings
  for select using ((select auth.uid()) = user_id or (select public.is_admin()));

create policy "creo mis reservas" on public.bookings
  for insert with check ((select auth.uid()) = user_id);

create policy "edito mis reservas" on public.bookings
  for update using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "borro mis reservas" on public.bookings
  for delete using ((select auth.uid()) = user_id);

-- ------------------------------------------------------- índices que faltaban
create index if not exists bookings_guide_idx          on public.bookings (guide_id);
create index if not exists bookings_service_idx        on public.bookings (service_id);
create index if not exists circle_members_circle_idx   on public.circle_members (circle_id);
create index if not exists circles_guide_idx           on public.circles (guide_id);
create index if not exists live_events_guide_idx       on public.live_events (guide_id);
create index if not exists post_resonances_post_idx    on public.post_resonances (post_id);
create index if not exists posts_author_idx            on public.posts (author_id);
create index if not exists posts_circle_idx            on public.posts (circle_id);
create index if not exists read_teachings_teaching_idx on public.read_teachings (teaching_id);
create index if not exists saved_teachings_teaching_idx on public.saved_teachings (teaching_id);
