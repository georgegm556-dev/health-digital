-- =====================================================================
-- Health Digital · Base de datos para Supabase
-- Cómo usarlo: en tu proyecto de Supabase abre "SQL Editor" → "New query",
-- pega TODO este archivo y presiona "Run". Se puede correr más de una vez.
-- =====================================================================

-- Fecha de hoy en hora de la Ciudad de México (para no rechazar citas de la noche por el desfase con UTC).
create or replace function public.hoy_mx() returns date language sql stable as $$ select (now() at time zone 'America/Mexico_City')::date $$;

-- ---------- Perfiles de pacientes (privados) ----------
create table if not exists public.perfiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  nombre          text not null check (char_length(nombre) between 3 and 120),
  telefono        text check (telefono is null or telefono = '' or telefono ~ '^[0-9]{10}$'),
  email           text,
  plan            text check (plan in ('individual','familiar')),
  socio           text,
  renovacion      timestamptz,
  miembros        jsonb not null default '[]'::jsonb,
  seguros         jsonb not null default '[]'::jsonb,
  notif           jsonb not null default '{"recordatorios":true,"promos":false}'::jsonb,
  aviso_aceptado  timestamptz not null,
  creado          timestamptz not null default now()
);
alter table public.perfiles enable row level security;
drop policy if exists "perfil: ver el propio" on public.perfiles;
drop policy if exists "perfil: crear el propio" on public.perfiles;
drop policy if exists "perfil: editar el propio" on public.perfiles;
drop policy if exists "perfil: borrar el propio" on public.perfiles;
create policy "perfil: ver el propio"    on public.perfiles for select to authenticated using (id = auth.uid());
create policy "perfil: crear el propio"  on public.perfiles for insert to authenticated with check (id = auth.uid());
create policy "perfil: editar el propio" on public.perfiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "perfil: borrar el propio" on public.perfiles for delete to authenticated using (id = auth.uid());

-- ---------- Citas de cada paciente (privadas) ----------
create table if not exists public.citas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  doctor_id     text not null,
  fecha         date not null,
  hora          text not null check (hora ~ '^[0-9]{2}:[0-9]{2}$'),
  modalidad     text not null check (modalidad in ('Presencial','Videoconsulta')),
  paciente      text not null check (char_length(paciente) <= 120),
  motivo        text check (motivo is null or char_length(motivo) <= 300),
  estado        text not null default 'confirmada' check (estado in ('confirmada','cancelada','completada')),
  cubierta      boolean not null default false,
  precio        integer not null check (precio >= 0),
  slot          text,
  folio         text not null,
  creada        timestamptz not null default now(),
  cancelada_en  timestamptz
);
create index if not exists citas_user_idx on public.citas(user_id);
alter table public.citas enable row level security;
drop policy if exists "citas: ver las propias" on public.citas;
drop policy if exists "citas: crear las propias" on public.citas;
drop policy if exists "citas: editar las propias" on public.citas;
drop policy if exists "citas: borrar las propias" on public.citas;
create policy "citas: ver las propias"   on public.citas for select to authenticated using (user_id = auth.uid());
create policy "citas: crear las propias" on public.citas for insert to authenticated
  with check (user_id = auth.uid() and estado = 'confirmada' and fecha >= public.hoy_mx());
-- El paciente puede reprogramar o cancelar, pero NO marcar su cita como "completada"
-- (eso lo hace el médico o un administrador), así las opiniones no se pueden falsear.
create policy "citas: editar las propias" on public.citas for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and estado in ('confirmada','cancelada'));
create policy "citas: borrar las propias" on public.citas for delete to authenticated using (user_id = auth.uid());

-- ---------- Médicos vinculados a una agenda ----------
-- Para que un médico pueda bloquear horarios desde el Portal médico, vincula su cuenta:
--   insert into public.medicos (user_id, doctor_id)
--   values ('<uuid de su usuario en Authentication>', 'camila-restrepo');
create table if not exists public.medicos (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  doctor_id  text not null unique
);
alter table public.medicos enable row level security;
drop policy if exists "medicos: ver el propio vínculo" on public.medicos;
create policy "medicos: ver el propio vínculo" on public.medicos for select to authenticated using (user_id = auth.uid());

-- ---------- Horarios ocupados (públicos, sin datos del paciente) ----------
-- La llave primaria es médico+fecha+hora: la base de datos impide reservar dos veces el mismo horario.
create table if not exists public.ocupados (
  id         text primary key,
  doctor_id  text not null,
  fecha      date not null,
  hora       text not null,
  modalidad  text,
  tipo       text not null check (tipo in ('cita','bloqueo')),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  creada     timestamptz not null default now(),
  check (id = doctor_id || '_' || fecha::text || '_' || replace(hora, ':', ''))
);
create index if not exists ocupados_fecha_idx on public.ocupados(fecha);
alter table public.ocupados enable row level security;
drop policy if exists "ocupados: todos ven la disponibilidad" on public.ocupados;
drop policy if exists "ocupados: reservar" on public.ocupados;
drop policy if exists "ocupados: liberar lo propio" on public.ocupados;
create policy "ocupados: todos ven la disponibilidad" on public.ocupados for select to anon, authenticated using (true);
create policy "ocupados: reservar" on public.ocupados for insert to authenticated
  with check (
    user_id = auth.uid() and fecha >= public.hoy_mx() and (
      tipo = 'cita'
      or exists (select 1 from public.medicos m where m.user_id = auth.uid() and m.doctor_id = ocupados.doctor_id)
    )
  );
create policy "ocupados: liberar lo propio" on public.ocupados for delete to authenticated using (user_id = auth.uid());

-- ---------- Opiniones verificadas (públicas, anónimas) ----------
create table if not exists public.resenas (
  id         uuid primary key default gen_random_uuid(),
  doctor_id  text not null,
  cita_id    uuid unique references public.citas(id) on delete set null,
  estrellas  integer not null check (estrellas between 1 and 5),
  texto      text check (texto is null or char_length(texto) <= 400),
  fecha      date not null default current_date,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade
);
alter table public.resenas enable row level security;
drop policy if exists "resenas: todos las leen" on public.resenas;
drop policy if exists "resenas: solo con cita atendida" on public.resenas;
create policy "resenas: todos las leen" on public.resenas for select to anon, authenticated using (true);
-- Solo puede opinar quien tuvo una cita real con ese médico, ya pasada o marcada como completada, y una sola vez por cita.
create policy "resenas: solo con cita atendida" on public.resenas for insert to authenticated
  with check (
    user_id = auth.uid() and exists (
      select 1 from public.citas c
      where c.id = resenas.cita_id and c.user_id = auth.uid() and c.doctor_id = resenas.doctor_id
        and c.estado <> 'cancelada' and (c.estado = 'completada' or c.fecha < public.hoy_mx())
    )
  );

-- ---------- Tiempo real (la disponibilidad se actualiza al instante) ----------
do $$
declare t text;
begin
  foreach t in array array['ocupados','resenas','citas','perfiles'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- Actualización 2: servicios, favoritos y opiniones por categoría ----------
-- Servicio elegido en cada cita (ej. "Consulta de seguimiento")
alter table public.citas add column if not exists servicio text
  check (servicio is null or char_length(servicio) <= 120);

-- Médicos favoritos de cada paciente
alter table public.perfiles add column if not exists favoritos jsonb not null default '[]'::jsonb;

-- Opiniones por categoría y respuesta del médico
alter table public.resenas add column if not exists puntualidad   integer check (puntualidad   between 1 and 5);
alter table public.resenas add column if not exists trato         integer check (trato         between 1 and 5);
alter table public.resenas add column if not exists instalaciones integer check (instalaciones between 1 and 5);
alter table public.resenas add column if not exists respuesta     text    check (respuesta is null or char_length(respuesta) <= 600);
alter table public.resenas add column if not exists respondida    timestamptz;

-- El médico solo puede escribir su respuesta: nunca cambiar las estrellas ni el texto del paciente.
revoke update on public.resenas from anon, authenticated;
grant update (respuesta, respondida) on public.resenas to authenticated;
drop policy if exists "resenas: el médico responde" on public.resenas;
create policy "resenas: el médico responde" on public.resenas for update to authenticated
  using      (exists (select 1 from public.medicos m where m.user_id = auth.uid() and m.doctor_id = resenas.doctor_id))
  with check (exists (select 1 from public.medicos m where m.user_id = auth.uid() and m.doctor_id = resenas.doctor_id));
