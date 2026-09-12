-- ============================================================================
-- DESDE LA RED — instalación completa, de una sola vez.
--
-- Pega este archivo entero en el SQL Editor de Supabase y dale a RUN. Trae
-- dentro las migraciones en orden, y se puede correr dos veces sin romper
-- nada ni duplicar contenido.
--
-- Al terminar tendrás: las tablas, los permisos por fila, el contenido
-- inicial de la Red, y el disparador que crea el perfil de cada persona al
-- registrarse.
--
-- Generado por scripts/build-install-sql.js — no lo edites a mano.
-- ============================================================================


-- ======================= 0001_schema.sql =======================

-- ============================================================================
-- Desde la Red — esquema inicial
--
-- Dos familias de tablas:
--   · Contenido  (guías, enseñanzas, servicios, círculos, eventos, voces)
--     lo lee cualquiera; solo las administradoras lo escriben.
--   · Personal   (guardadas, leídas, círculos, resonancias, camino, reservas)
--     cada persona solo ve y toca lo suyo.
-- ============================================================================

-- ---------------------------------------------------------------- perfiles
-- Se crea solo al registrarse (ver el trigger al final).
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text not null default '',
  email       text,
  role        text not null default 'member' check (role in ('member', 'admin')),
  created_at  timestamptz not null default now()
);

comment on column public.profiles.role is
  'member = persona que usa la app. admin = administradora: puede publicar contenido.';

-- ¿Quien pide es administradora? Se usa en las políticas de abajo.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ---------------------------------------------------------------- contenido

create table if not exists public.guides (
  id           text primary key,
  name         text not null,
  title        text not null default '',
  location     text default '',
  initials     text not null default '',
  accent       text not null default 'cyan' check (accent in ('cyan', 'glow', 'electric')),
  years        integer not null default 0,
  circle_count integer not null default 0,
  rating       numeric(2,1) not null default 5.0,
  bio          text default '',
  approach     text[] not null default '{}',
  languages    text[] not null default '{}',
  verified     boolean not null default false,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);

create table if not exists public.teachings (
  id             text primary key,
  title          text not null,
  subtitle       text default '',
  theme          text not null,
  image_key      text not null,
  author_id      text references public.guides(id) on delete set null,
  read_minutes   integer not null default 5,
  listen_minutes integer not null default 6,
  published_on   text default '',
  excerpt        text default '',
  body           jsonb not null default '[]'::jsonb,
  tags           text[] not null default '{}',
  featured       boolean not null default false,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now()
);

create index if not exists teachings_author_idx on public.teachings (author_id);
create index if not exists teachings_featured_idx on public.teachings (featured) where featured;

create table if not exists public.services (
  id               text primary key,
  guide_id         text not null references public.guides(id) on delete cascade,
  name             text not null,
  format           text not null check (format in ('Individual', 'Círculo', 'Intensivo')),
  modality         text not null check (modality in ('En línea', 'Presencial')),
  duration_minutes integer not null default 60,
  price            numeric(10,2) not null default 0,
  currency         text not null default 'USD',
  description      text default '',
  includes         text[] not null default '{}',
  sort_order       integer not null default 0
);

create index if not exists services_guide_idx on public.services (guide_id);

create table if not exists public.circles (
  id         text primary key,
  name       text not null,
  image_key  text not null,
  guide_id   text references public.guides(id) on delete set null,
  members    integer not null default 0,
  cadence    text default '',
  intention  text default '',
  topics     text[] not null default '{}',
  sort_order integer not null default 0
);

create table if not exists public.live_events (
  id               text primary key,
  title            text not null,
  guide_id         text references public.guides(id) on delete set null,
  image_key        text not null,
  starts_label     text not null default '',
  starts_at        timestamptz,
  duration_minutes integer not null default 60,
  attendees        integer not null default 0,
  status           text not null default 'scheduled' check (status in ('live', 'soon', 'scheduled')),
  description      text default '',
  sort_order       integer not null default 0
);

-- Voces de La Red. author_id apunta al perfil cuando la escribe alguien de
-- la app; author_name cubre el contenido sembrado por la Red.
create table if not exists public.posts (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid references public.profiles(id) on delete set null,
  author_name  text not null default '',
  author_role  text not null default 'Caminante',
  accent       text not null default 'cyan' check (accent in ('cyan', 'glow', 'electric')),
  text         text not null,
  circle_id    text references public.circles(id) on delete set null,
  replies      integer not null default 0,
  -- Las resonancias reales viven en post_resonances. Esto es el número con el
  -- que arranca una voz sembrada, para que no empiece en cero.
  base_resonances integer not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts (created_at desc);

-- Las preguntas de Mi Camino también son contenido editable.
create table if not exists public.path_questions (
  id         text primary key,
  prompt     text not null,
  helper     text default '',
  multiple   boolean not null default false,
  options    jsonb not null default '[]'::jsonb,
  sort_order integer not null default 0
);

-- ----------------------------------------------------------------- personal

create table if not exists public.saved_teachings (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  teaching_id text not null references public.teachings(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, teaching_id)
);

create table if not exists public.read_teachings (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  teaching_id text not null references public.teachings(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, teaching_id)
);

create table if not exists public.circle_members (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  circle_id  text not null references public.circles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, circle_id)
);

create table if not exists public.post_resonances (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  post_id    uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

create table if not exists public.path_answers (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  question_id text not null,
  option_ids  text[] not null default '{}',
  updated_at  timestamptz not null default now(),
  primary key (user_id, question_id)
);

create table if not exists public.bookings (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  service_id text not null references public.services(id) on delete cascade,
  guide_id   text references public.guides(id) on delete set null,
  date_label text not null,
  time_label text not null,
  note       text,
  status     text not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled')),
  created_at timestamptz not null default now()
);

create index if not exists bookings_user_idx on public.bookings (user_id, created_at desc);

-- ========================================================== seguridad (RLS)
-- Sin esto, cualquiera con la clave pública podría leer y escribir todo.

alter table public.profiles        enable row level security;
alter table public.guides          enable row level security;
alter table public.teachings       enable row level security;
alter table public.services        enable row level security;
alter table public.circles         enable row level security;
alter table public.live_events     enable row level security;
alter table public.posts           enable row level security;
alter table public.path_questions  enable row level security;
alter table public.saved_teachings enable row level security;
alter table public.read_teachings  enable row level security;
alter table public.circle_members  enable row level security;
alter table public.post_resonances enable row level security;
alter table public.path_answers    enable row level security;
alter table public.bookings        enable row level security;

-- Perfiles: cada quien ve y edita el suyo; las administradoras ven todos.
drop policy if exists "perfil propio visible" on public.profiles;
create policy "perfil propio visible" on public.profiles
  for select using (auth.uid() = id or public.is_admin());

drop policy if exists "perfil propio editable" on public.profiles;
create policy "perfil propio editable" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Contenido: lo lee cualquiera, incluso sin cuenta. Lo escriben las admins.
do $$
declare t text;
begin
  foreach t in array array['guides','teachings','services','circles','live_events','path_questions']
  loop
    execute format('drop policy if exists "contenido visible" on public.%I', t);
    execute format(
      'create policy "contenido visible" on public.%I for select using (true)', t);
    execute format('drop policy if exists "solo admin escribe" on public.%I', t);
    execute format(
      'create policy "solo admin escribe" on public.%I for all using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- Voces: se leen abiertas; una persona escribe y borra las suyas.
drop policy if exists "voces visibles" on public.posts;
create policy "voces visibles" on public.posts for select using (true);

drop policy if exists "escribo mis voces" on public.posts;
create policy "escribo mis voces" on public.posts
  for insert with check (auth.uid() = author_id);

drop policy if exists "edito mis voces" on public.posts;
create policy "edito mis voces" on public.posts
  for update using (auth.uid() = author_id) with check (auth.uid() = author_id);

drop policy if exists "borro mis voces" on public.posts;
create policy "borro mis voces" on public.posts
  for delete using (auth.uid() = author_id or public.is_admin());

-- Tablas personales: cada quien, solo lo suyo.
do $$
declare t text;
begin
  foreach t in array array['saved_teachings','read_teachings','circle_members',
                           'post_resonances','path_answers','bookings']
  loop
    execute format('drop policy if exists "solo lo mio" on public.%I', t);
    execute format(
      'create policy "solo lo mio" on public.%I for all using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
  end loop;
end $$;

-- ============================================ perfil automático al registrarse
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ======================= 0002_seed.sql =======================

-- ============================================================================
-- Contenido inicial de Desde la Red.
--
-- Generado por scripts/generate-seed.js a partir de src/data, para que la base
-- de datos y la app digan lo mismo. Es contenido de muestra: las guías y las
-- enseñanzas se sustituyen por las reales desde el panel de administración.
--
-- Se puede volver a correr sin duplicar nada (on conflict do nothing).
-- ============================================================================

insert into public.guides (id, name, title, location, initials, accent, years, circle_count, rating, bio, approach, languages, verified, sort_order) values
  ('g-amara', 'Amara Solís', 'Guía de silencio y contemplación', 'Ciudad de México', 'AS', 'cyan', 14, 3, 4.9, 'Acompaño a personas que sienten el llamado del silencio pero no saben por dónde entrar. Mi trabajo nace de catorce años de práctica contemplativa y de una convicción simple: el alma no necesita ruido para hablar, necesita espacio.', array['Contemplación', 'Escritura sagrada', 'Trabajo con el duelo'], array['Español', 'Inglés'], true, 0),
  ('g-tobias', 'Tobías Rey', 'Maestro de respiración y cuerpo', 'Bogotá', 'TR', 'glow', 9, 2, 4.8, 'La respiración es la puerta más antigua que conocemos. Trabajo con el cuerpo como territorio sagrado: lo que la mente no logra soltar, el aliento lo desanuda.', array['Respiración consciente', 'Movimiento', 'Regulación nerviosa'], array['Español', 'Portugués'], true, 1),
  ('g-neve', 'Neve Aguilar', 'Guía de umbrales y transiciones', 'Buenos Aires', 'NA', 'electric', 11, 4, 5, 'Acompaño umbrales: separaciones, mudanzas, pérdidas, comienzos. No hay atajo para cruzar una puerta, pero sí hay forma de no cruzarla sola.', array['Ritos de paso', 'Duelo', 'Constelación simbólica'], array['Español'], true, 2),
  ('g-idris', 'Idris Moreno', 'Cartógrafo de la sombra', 'Madrid', 'IM', 'cyan', 17, 2, 4.7, 'Lo que rechazamos de nosotros no desaparece: se organiza. Mi práctica consiste en devolverle nombre y lugar a lo que fue exiliado.', array['Trabajo con la sombra', 'Sueños', 'Escritura'], array['Español', 'Inglés', 'Francés'], false, 3),
  ('g-lucia', 'Lucía Ferrer', 'Voz y canto devocional', 'Valparaíso', 'LF', 'glow', 7, 1, 4.9, 'Canto con personas que creen que no saben cantar. La voz es el primer instrumento de la oración y nadie la tiene rota, solo dormida.', array['Canto devocional', 'Mantra', 'Voz libre'], array['Español'], true, 4)
on conflict (id) do nothing;

insert into public.teachings (id, title, subtitle, theme, image_key, author_id, read_minutes, listen_minutes, published_on, excerpt, body, tags, featured, sort_order) values
  ('t-silencio', 'El silencio también es una respuesta', 'Sobre lo que aprendemos cuando dejamos de exigirle palabras a la vida', 'Silencio', 'teaching-silence', 'g-amara', 6, 8, 'Hoy', 'Hay preguntas que no se contestan: se habitan. Lo que llamamos silencio casi nunca es ausencia, es una forma más lenta de ser respondido.', '[{"kind":"paragraph","text":"Llevas semanas preguntando. Has preguntado en voz alta, en la almohada, en el auto detenido frente al semáforo. Y no ha llegado nada. Ninguna señal, ninguna certeza, ningún golpe de claridad. Solo el mismo silencio de siempre."},{"kind":"paragraph","text":"Nos enseñaron a leer ese silencio como abandono. Como si la vida estuviera obligada a contestar en el idioma que nosotros elegimos y en el plazo que nosotros fijamos. Pero el silencio rara vez es un no. Casi siempre es un todavía no, y a veces —las más difíciles— es un ya te contesté, solo que no querías escucharlo así."},{"kind":"verse","text":"Lo que no responde con palabras\nte está respondiendo con tiempo."},{"kind":"subtitle","text":"La diferencia entre el vacío y el espacio"},{"kind":"paragraph","text":"El vacío es lo que sentimos cuando esperamos algo que no llega. El espacio es lo que aparece cuando dejamos de esperarlo. Son el mismo lugar visto desde dos posturas distintas del alma. Nadie puede pasar del uno al otro por decisión, pero sí por práctica."},{"kind":"paragraph","text":"La práctica es sencilla y brutal: quedarte. No arreglar el silencio con ruido, no llenarlo con explicaciones, no salir corriendo a pedir opinión. Quedarte los primeros diez minutos, que son los peores. Después de los diez, algo cede."},{"kind":"subtitle","text":"Una práctica para esta semana"},{"kind":"paragraph","text":"Cada mañana, antes de tomar el teléfono, siéntate cinco minutos con la pregunta que más te pesa. No la respondas. No la analices. Solo sostenla, como se sostiene a alguien que llora. Al séptimo día, escribe qué cambió: no en la respuesta, sino en ti."},{"kind":"verse","text":"No estás esperando una señal.\nEstás aprendiendo a reconocerla."}]'::jsonb, array['contemplación', 'escucha', 'duelo'], true, 0),
  ('t-luz', 'La luz que entra por lo roto', 'Por qué las grietas no son el fracaso del alma sino su arquitectura', 'Luz', 'teaching-light', 'g-idris', 7, 9, 'Ayer', 'Nadie construye una catedral sin ventanas. Lo que en tu historia parece daño estructural puede ser, visto de cerca, el lugar exacto por donde entra la claridad.', '[{"kind":"paragraph","text":"Hay una idea muy difundida de que la persona sana es la persona sin grietas. Que primero hay que repararse y después vivir. Con esa idea se pierden décadas enteras."},{"kind":"paragraph","text":"Pero mira una catedral. Su fuerza no está en el muro cerrado: está en cómo distribuye el peso alrededor de sus aberturas. Las ventanas no debilitan el edificio, lo definen. Y son, por supuesto, lo único por donde entra la luz."},{"kind":"verse","text":"Lo que en ti se abrió\nno se abrió en tu contra."},{"kind":"subtitle","text":"La diferencia entre herida y grieta"},{"kind":"paragraph","text":"Una herida pide atención inmediata; una grieta pide arquitectura. Confundirlas es el error más común. Si tratas una grieta antigua como una herida fresca, vivirás en emergencia permanente. Si tratas una herida fresca como una grieta antigua, te vas a acostumbrar a sangrar."},{"kind":"paragraph","text":"La pregunta honesta no es \"¿qué me rompió?\" sino \"¿qué se está sosteniendo alrededor de esto?\". Casi siempre descubrirás que has construido más de lo que creías."},{"kind":"verse","text":"No eres el derrumbe.\nEres lo que quedó en pie."}]'::jsonb, array['sombra', 'sanación', 'aceptación'], false, 1),
  ('t-agua', 'Agua que recuerda su cauce', 'Volver a lo esencial sin romantizar el pasado', 'Retorno', 'teaching-water', 'g-neve', 5, 6, 'Hace 3 días', 'Volver no es retroceder. El agua que regresa al cauce no está deshaciendo su viaje: está recordando su forma.', '[{"kind":"paragraph","text":"Hay épocas en las que uno se desconoce. No por una crisis dramática, sino por acumulación: decisiones pequeñas, sí dichos por costumbre, semanas que se parecen demasiado entre sí."},{"kind":"paragraph","text":"El agua tiene una inteligencia que nosotros perdimos: cuando se desborda, no se avergüenza. Busca el terreno más bajo y vuelve. No hay culpa en su regreso, solo gravedad."},{"kind":"verse","text":"Volver a ti no es retroceder.\nEs dejar de ir en contra de tu propio peso."},{"kind":"paragraph","text":"Pregúntate esta semana: ¿en qué parte de mi vida estoy subiendo una cuesta que nadie me pidió subir?"}]'::jsonb, array['retorno', 'identidad'], false, 2),
  ('t-umbral', 'Quedarse en el umbral', 'La sabiduría de no cruzar todavía', 'Umbral', 'teaching-threshold', 'g-neve', 8, 10, 'Hace 5 días', 'Toda cultura antigua tuvo ritos de umbral porque sabía algo que nosotros olvidamos: cruzar sin preparación no es valentía, es desperdicio.', '[{"kind":"paragraph","text":"Un umbral no es un obstáculo. Es un lugar. Tiene su propia duración, sus propias reglas y su propia dignidad."},{"kind":"paragraph","text":"La prisa moderna nos convenció de que la incertidumbre es un problema a resolver rápido. Por eso tomamos decisiones grandes en estados pequeños: cansados, asustados, apurados."},{"kind":"verse","text":"No toda puerta se cruza el día que se abre."},{"kind":"subtitle","text":"Tres señales de que aún no es tiempo"},{"kind":"paragraph","text":"Primera: la decisión te alivia más de lo que te alegra. Segunda: necesitas convencer a alguien más antes que a ti. Tercera: solo puedes sostenerla cuando estás enojado."}]'::jsonb, array['transiciones', 'ritos'], false, 3),
  ('t-raiz', 'Lo que la raíz sabe del invierno', 'Sobre los tiempos donde no hay nada visible que mostrar', 'Raíz', 'teaching-roots', 'g-amara', 6, 7, 'Hace una semana', 'El árbol en enero no está fracasando. Está haciendo, bajo tierra, el trabajo que en abril llamaremos florecer.', '[{"kind":"paragraph","text":"Medimos nuestra vida por lo que se ve. Y hay temporadas largas en las que no se ve nada: ni resultados, ni claridad, ni progreso medible."},{"kind":"paragraph","text":"Bajo tierra, sin embargo, ocurre casi todo lo importante. La raíz no pide aplausos porque no los necesita para trabajar."},{"kind":"verse","text":"Hay meses de tu vida\nque solo se entienden años después."}]'::jsonb, array['paciencia', 'ciclos'], false, 4),
  ('t-aliento', 'El aliento como primera oración', 'Una práctica de cinco minutos que sí vas a sostener', 'Respiración', 'teaching-breath', 'g-tobias', 4, 6, 'Hace una semana', 'Antes de cualquier tradición, de cualquier libro y de cualquier maestro, estuvo esto: alguien respirando con atención.', '[{"kind":"paragraph","text":"Tu sistema nervioso no entiende argumentos. Entiende ritmo. Por eso puedes saber perfectamente que estás a salvo y seguir temblando."},{"kind":"paragraph","text":"La exhalación larga es la única palanca voluntaria que tienes sobre un sistema involuntario. Cuatro tiempos al inhalar, ocho al exhalar. Cinco minutos."},{"kind":"verse","text":"Respirar despacio\nes decirle al cuerpo que ya pasó."}]'::jsonb, array['respiración', 'cuerpo', 'práctica'], false, 5),
  ('t-fuego', 'El fuego que no consume', 'Distinguir el deseo que da vida del que solo quema', 'Fuego', 'teaching-fire', 'g-lucia', 5, 7, 'Hace 10 días', 'No todo lo que arde te está destruyendo, y no todo lo que te calienta te está cuidando. Aprender a distinguirlos es trabajo de años.', '[{"kind":"paragraph","text":"Hay un fuego que ilumina la habitación y otro que la deja en cenizas. Ambos se sienten cálidos al principio."},{"kind":"paragraph","text":"La prueba no está en la intensidad, sino en lo que queda al día siguiente: ¿tienes más vida o menos?"},{"kind":"verse","text":"Lo que te enciende sin agotarte\nes probablemente tu camino."}]'::jsonb, array['deseo', 'vocación'], false, 6),
  ('t-retorno', 'Regresar sin pedir perdón', 'Sobre volver a una práctica que abandonaste', 'Retorno', 'teaching-return', 'g-idris', 5, 6, 'Hace 2 semanas', 'Dejaste de meditar, de escribir, de rezar, de moverte. Volviste a intentarlo tres veces. La cuarta también cuenta.', '[{"kind":"paragraph","text":"La culpa es un pésimo motor. Enciende rápido y se apaga antes de llegar a ninguna parte."},{"kind":"paragraph","text":"Volver sin ceremonia es una habilidad espiritual seria: sentarte hoy sin rendir cuentas por los cuarenta días que no te sentaste."},{"kind":"verse","text":"La práctica no lleva registro de tus ausencias.\nSolo de tu presencia."}]'::jsonb, array['constancia', 'compasión'], false, 7)
on conflict (id) do nothing;

insert into public.services (id, guide_id, name, format, modality, duration_minutes, price, currency, description, includes, sort_order) values
  ('s-amara-1', 'g-amara', 'Sesión de escucha profunda', 'Individual', 'En línea', 60, 75, 'USD', 'Un encuentro uno a uno para escuchar lo que está pidiendo espacio. Sin agenda, sin técnica impuesta: solo presencia sostenida y preguntas precisas.', array['Encuentro de 60 minutos', 'Práctica personalizada', 'Seguimiento por mensaje'], 0),
  ('s-amara-2', 'g-amara', 'Retiro de silencio de tres días', 'Intensivo', 'Presencial', 4320, 420, 'USD', 'Tres días de silencio estructurado con caminatas, escritura contemplativa y dos entrevistas individuales.', array['Hospedaje', 'Alimentación', 'Dos entrevistas privadas', 'Cuaderno de práctica'], 1),
  ('s-amara-3', 'g-amara', 'Círculo de escritura sagrada', 'Círculo', 'En línea', 90, 30, 'USD', 'Ocho personas, una pregunta y noventa minutos de escritura compartida. Escribir juntos lo que no diríamos en voz alta.', array['Encuentro semanal', 'Cuaderno digital', 'Acceso al círculo'], 2),
  ('s-tobias-1', 'g-tobias', 'Respiración para el sistema nervioso', 'Individual', 'En línea', 50, 60, 'USD', 'Sesión diseñada para cuerpos que viven en alerta. Evaluamos tu patrón respiratorio y construimos una práctica de cinco minutos que sí vas a sostener.', array['Diagnóstico respiratorio', 'Audio guiado propio', 'Plan de dos semanas'], 3),
  ('s-tobias-2', 'g-tobias', 'Ceremonia de aliento', 'Círculo', 'Presencial', 120, 45, 'USD', 'Dos horas de respiración conectada en grupo, con música en vivo y acompañamiento cercano.', array['Círculo de apertura', 'Sesión de respiración', 'Integración en grupo'], 4),
  ('s-neve-1', 'g-neve', 'Acompañamiento de umbral', 'Individual', 'En línea', 75, 90, 'USD', 'Para quien está en medio de un cambio grande y necesita a alguien que sostenga el mapa mientras cruza.', array['Encuentro de 75 minutos', 'Rito personal diseñado a medida', 'Carta de cierre'], 5),
  ('s-neve-2', 'g-neve', 'Rito de cierre de ciclo', 'Intensivo', 'Presencial', 240, 180, 'USD', 'Una tarde completa para cerrar formalmente lo que ya terminó: una relación, un trabajo, una versión de ti.', array['Preparación previa', 'Rito de cuatro horas', 'Sesión de integración'], 6),
  ('s-idris-1', 'g-idris', 'Cartografía de la sombra', 'Individual', 'En línea', 90, 110, 'USD', 'Un mapa honesto de lo que evitas. Trabajo directo, cuidadoso y sin complacencia.', array['Encuentro de 90 minutos', 'Mapa escrito', 'Ejercicios de integración'], 7),
  ('s-idris-2', 'g-idris', 'Laboratorio de sueños', 'Círculo', 'En línea', 100, 35, 'USD', 'Traemos sueños reales y los abrimos en grupo, sin interpretarlos a la fuerza.', array['Encuentro quincenal', 'Diario de sueños', 'Acceso a grabaciones'], 8),
  ('s-lucia-1', 'g-lucia', 'Despertar de la voz', 'Círculo', 'En línea', 80, 28, 'USD', 'Ochenta minutos de canto devocional para personas que "no saben cantar". Empezamos por el zumbido.', array['Círculo semanal', 'Repertorio de mantras', 'Grabaciones de práctica'], 9)
on conflict (id) do nothing;

insert into public.circles (id, name, image_key, guide_id, members, cadence, intention, topics, sort_order) values
  ('c-luna', 'Círculo de Luna', 'circle-luna', 'g-neve', 148, 'Cada luna nueva', 'Cerrar ciclos y nombrar lo que empieza.', array['Ritos', 'Transiciones', 'Duelo'], 0),
  ('c-fuego', 'Círculo de Fuego', 'circle-fuego', 'g-tobias', 203, 'Martes y viernes', 'Mover el cuerpo hasta que la mente afloje.', array['Respiración', 'Cuerpo', 'Energía'], 1),
  ('c-raiz', 'Círculo de Raíz', 'circle-raiz', 'g-amara', 96, 'Domingos por la mañana', 'Sostener la práctica cuando no se ve ningún resultado.', array['Silencio', 'Constancia', 'Escritura'], 2)
on conflict (id) do nothing;

insert into public.live_events (id, title, guide_id, image_key, starts_label, duration_minutes, attendees, status, description, sort_order) values
  ('e-ceremonia', 'Ceremonia de luna: cerrar el ciclo', 'g-neve', 'live-ceremony', 'Hoy · 20:00', 75, 214, 'soon', 'Una hora y cuarto para nombrar en voz alta lo que termina. Trae una vela y algo que quieras dejar ir.', 0),
  ('e-meditacion', 'Meditación guiada del amanecer', 'g-amara', 'live-meditation', 'En vivo ahora', 30, 89, 'live', 'Treinta minutos de silencio acompañado para empezar el día sin prisa.', 1),
  ('e-aliento', 'Ceremonia de aliento', 'g-tobias', 'circle-fuego', 'Mañana · 07:30', 120, 156, 'scheduled', 'Respiración conectada en grupo con música en vivo.', 2),
  ('e-canto', 'Canto devocional abierto', 'g-lucia', 'circle-luna', 'Jueves · 19:00', 80, 62, 'scheduled', 'Mantras sencillos, sin experiencia previa. Solo la voz que ya tienes.', 3)
on conflict (id) do nothing;

insert into public.path_questions (id, prompt, helper, multiple, options, sort_order) values
  ('q-intencion', '¿Qué buscas en este momento?', 'Elige hasta dos. Podrás cambiarlo cuando quieras.', true, '[{"id":"calma","label":"Calma","description":"Bajar el ruido interno y dormir mejor"},{"id":"claridad","label":"Claridad","description":"Entender una decisión que me pesa"},{"id":"duelo","label":"Acompañamiento","description":"Atravesar una pérdida o un cierre"},{"id":"proposito","label":"Propósito","description":"Reconocer hacia dónde quiero ir"}]'::jsonb, 0),
  ('q-ritmo', '¿Cuánto tiempo tienes al día?', 'Sé honesta. Es mejor poco y sostenido.', false, '[{"id":"5","label":"5 minutos","description":"Una práctica mínima diaria"},{"id":"15","label":"15 minutos","description":"Lectura y práctica corta"},{"id":"30","label":"30 minutos o más","description":"Práctica profunda y escritura"}]'::jsonb, 1),
  ('q-momento', '¿En qué momento del día?', 'La Red te recordará a esa hora.', false, '[{"id":"amanecer","label":"Al amanecer","description":"Antes de que empiece el ruido"},{"id":"mediodia","label":"Mediodía","description":"Una pausa en medio del día"},{"id":"noche","label":"Al anochecer","description":"Cerrar el día en silencio"}]'::jsonb, 2),
  ('q-forma', '¿Cómo prefieres recibir la enseñanza?', 'Elige todas las que resuenen.', true, '[{"id":"lectura","label":"Lectura","description":"Textos para leer con calma"},{"id":"audio","label":"Audio","description":"Escuchar mientras camino"},{"id":"circulo","label":"Círculo","description":"Acompañada por otras personas"},{"id":"guia","label":"Guía","description":"Sesiones uno a uno"}]'::jsonb, 3)
on conflict (id) do nothing;

insert into public.posts (author_name, author_role, accent, text, circle_id, replies, base_resonances)
select * from (values
  ('Marisol Vega', 'Caminante', 'cyan', 'Séptimo día seguido sentándome cinco minutos antes de tocar el teléfono. No pasó nada místico. Pero hoy no le grité a nadie en el tráfico y eso ya me parece un milagro.', 'c-raiz', 8, 47),
  ('Tobías Rey', 'Guía de la Red', 'glow', 'Recordatorio para quien lo necesite: si tu práctica solo funciona cuando estás tranquilo, no es una práctica, es un premio. Empieza los días malos.', null, 21, 132),
  ('Elena Ruiz', 'Caminante', 'electric', 'Anoche escribí la carta de cierre que llevaba ocho meses posponiendo. No la envié. No hacía falta. Gracias a quien en el círculo dijo que escribir ya es cruzar.', 'c-luna', 33, 214),
  ('Amara Solís', 'Guía de la Red', 'cyan', 'Pregunta para el domingo: ¿qué parte de tu vida está pidiendo silencio y qué parte está pidiendo voz? Casi nunca son la misma.', null, 45, 178),
  ('Joaquín Prat', 'Caminante', 'glow', 'Llevo tres semanas con la exhalación de ocho tiempos. Dormí seis horas seguidas por primera vez desde marzo.', 'c-fuego', 12, 91)
) as v(author_name, author_role, accent, text, circle_id, replies, base_resonances)
where not exists (select 1 from public.posts p where p.text = v.text);


-- ======================= 0003_admin_lectura.sql =======================

-- ============================================================================
-- El panel de administración necesita ver dos cosas que las políticas
-- originales dejaban fuera: las reservas de todo el mundo y el número de
-- personas en la Red.
--
-- Solo lectura, y solo para quien tenga role = 'admin'. Nadie más gana nada:
-- una persona sigue viendo únicamente sus propias reservas.
-- ============================================================================

drop policy if exists "las admins ven las reservas" on public.bookings;
create policy "las admins ven las reservas" on public.bookings
  for select using (public.is_admin());

-- `perfil propio visible` ya deja que las admins lean los perfiles; esto solo
-- lo deja escrito para que se vea al leer las políticas de la tabla.
comment on table public.profiles is
  'Cada persona ve y edita el suyo. Las administradoras los ven todos, para
   saber quién está en la Red y a nombre de quién viene una reserva.';


-- ======================= 0004_cierra_trigger_al_api.sql =======================

-- ============================================================================
-- El linter de seguridad de Supabase avisa de dos funciones `security definer`
-- alcanzables desde la API pública. Una se cierra; la otra tiene que quedarse.
-- ============================================================================

-- `handle_new_user` es una función de disparador: la ejecuta Postgres cuando
-- alguien se registra, nunca una persona. Al vivir en el esquema public quedaba
-- expuesta en /rest/v1/rpc/handle_new_user. Se le quita el permiso de ejecución
-- a quien entra por la API; el disparador sigue funcionando igual, porque corre
-- con los privilegios de su dueño.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- `is_admin` sí se queda ejecutable, y es a propósito: las políticas de RLS la
-- evalúan con los permisos de quien consulta, así que quitarle el permiso
-- rompería la escritura de las administradoras. No filtra nada — responde
-- únicamente si quien pregunta es administradora, mirando su propio auth.uid().
comment on function public.is_admin() is
  'Responde si quien consulta es administradora. Ejecutable por anon y
   authenticated a propósito: las políticas de RLS la evalúan como el rol que
   consulta. No revela nada de terceros.';


-- ======================= 0005_admins_gestionan_personas.sql =======================

-- ============================================================================
-- El Panel necesita poder ascender y retirar administradoras sin pasar por el
-- editor de SQL. La política original solo dejaba a cada quien editar su
-- propio perfil, así que una administradora no podía tocar el rol de nadie.
--
-- Dos límites que la base hace cumplir, no la interfaz:
--   · Nadie puede cambiar su propio rol. Así una administradora no se degrada
--     sola por error, y nadie se asciende a sí misma si algún día se abre esa
--     pantalla por otra vía.
--   · Nunca puede quedar la Red sin ninguna administradora.
-- ============================================================================

-- Un perfil solo puede cambiar de rol a través de esta función.
create or replace function public.set_member_role(target uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo una administradora puede cambiar roles';
  end if;

  if new_role not in ('member', 'admin') then
    raise exception 'Rol desconocido: %', new_role;
  end if;

  if target = auth.uid() then
    raise exception 'No puedes cambiar tu propio rol';
  end if;

  -- Retirar a alguien no puede dejar la Red sin quien publique.
  if new_role = 'member'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception 'La Red necesita al menos una administradora';
  end if;

  update public.profiles set role = new_role where id = target;

  if not found then
    raise exception 'Esa persona no está en la Red';
  end if;
end;
$$;

revoke execute on function public.set_member_role(uuid, text) from public, anon;
grant execute on function public.set_member_role(uuid, text) to authenticated;

comment on function public.set_member_role is
  'Cambia el rol de otra persona. Solo para administradoras; nadie puede
   cambiar el suyo y nunca se queda la Red sin administradoras.';
