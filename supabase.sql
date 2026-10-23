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

-- ---------- Actualización 3: pagos con Stripe ----------
-- Datos de la suscripción (solo los escribe el servidor)
alter table public.perfiles add column if not exists plan_estado text;
alter table public.perfiles add column if not exists stripe_customer_id text;
alter table public.perfiles add column if not exists stripe_subscription_id text;

-- El paciente ya NO puede activarse un plan por su cuenta: plan, socio, renovación y
-- datos de Stripe solo los cambia la función stripe-webhook (con la llave de servidor).
revoke insert, update on public.perfiles from anon, authenticated;
grant insert (id, nombre, telefono, email, miembros, seguros, notif, aviso_aceptado, creado, favoritos) on public.perfiles to authenticated;
grant update (id, nombre, telefono, email, miembros, seguros, notif, aviso_aceptado, creado, favoritos) on public.perfiles to authenticated;

-- Miembros de la familia: solo con Plan Familiar y máximo 3 además del titular.
drop policy if exists "perfil: crear el propio" on public.perfiles;
drop policy if exists "perfil: editar el propio" on public.perfiles;
create policy "perfil: crear el propio" on public.perfiles for insert to authenticated
  with check (id = auth.uid() and jsonb_array_length(miembros) = 0);
create policy "perfil: editar el propio" on public.perfiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and jsonb_array_length(miembros) <= 3
              and (jsonb_array_length(miembros) = 0 or plan = 'familiar'));

-- ¿Puede usar una consulta incluida en esa fecha? Plan pagado y sin pasar el cupo del mes.
create or replace function public.cupo_ok(p_fecha date, p_excluir uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select (select count(*) from citas c
             where c.user_id = auth.uid() and c.cubierta and c.estado <> 'cancelada'
               and date_trunc('month', c.fecha) = date_trunc('month', p_fecha)
               and c.id is distinct from p_excluir)
           < case p.plan when 'familiar' then 2 else 1 end
    from perfiles p
    where p.id = auth.uid() and p.plan is not null and p.plan_estado in ('active', 'trialing')
  ), false)
$$;
revoke all on function public.cupo_ok(date, uuid) from public, anon;
grant execute on function public.cupo_ok(date, uuid) to authenticated;

drop policy if exists "citas: crear las propias" on public.citas;
drop policy if exists "citas: editar las propias" on public.citas;
create policy "citas: crear las propias" on public.citas for insert to authenticated
  with check (user_id = auth.uid() and estado = 'confirmada' and fecha >= public.hoy_mx()
              and (not cubierta or public.cupo_ok(fecha)));
create policy "citas: editar las propias" on public.citas for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and estado in ('confirmada', 'cancelada')
              and (estado = 'cancelada' or not cubierta or public.cupo_ok(fecha, id)));

-- ---------- Actualización 4: médicos y comisiones ----------
-- ---------- Perfil público del médico ----------
create table if not exists public.doctores (
  id                   text primary key check (id ~ '^[a-z0-9-]{3,60}$'),
  user_id              uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  nombre               text not null check (char_length(nombre) between 3 and 120),
  especialidad         text not null check (char_length(especialidad) between 3 and 80),
  cedula               text not null check (cedula ~ '^[0-9]{6,10}$'),
  universidad          text check (universidad is null or char_length(universidad) <= 120),
  experiencia          integer check (experiencia between 0 and 70),
  telefono             text check (telefono is null or telefono ~ '^[0-9]{10}$'),
  zona                 text not null check (char_length(zona) between 2 and 80),
  direccion            text not null check (char_length(direccion) between 5 and 200),
  modos                jsonb not null default '["Presencial"]'::jsonb,
  seguros              jsonb not null default '[]'::jsonb,
  idiomas              jsonb not null default '["Español"]'::jsonb,
  dias                 jsonb not null default '[1,2,3,4,5]'::jsonb,
  horas                jsonb not null default '[]'::jsonb,
  bio                  text check (bio is null or char_length(bio) <= 600),
  servicios            jsonb not null default '[]'::jsonb,
  padecimientos        jsonb not null default '[]'::jsonb,
  color                text not null default '#0B7D91' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  terminos_aceptados   timestamptz not null,
  verificado           boolean not null default false,  -- Health Digital revisó la cédula
  suspendido           boolean not null default false,  -- p. ej. cobro rechazado
  comision             numeric(4,3) not null default 0.100,
  tarjeta_ok           boolean not null default false,
  stripe_customer_id   text,
  stripe_payment_method text,
  creado               timestamptz not null default now()
);
alter table public.doctores enable row level security;

-- Lo que ven los pacientes: solo columnas públicas.
revoke all on public.doctores from anon, authenticated;
grant select (id, user_id, nombre, especialidad, cedula, universidad, experiencia, zona, direccion, modos, seguros,
              idiomas, dias, horas, bio, servicios, padecimientos, color, verificado, suspendido, tarjeta_ok, creado)
  on public.doctores to anon, authenticated;
-- Lo que el médico puede llenar al registrarse (verificado, comisión y tarjeta NO: los pone el sistema).
grant insert (id, user_id, nombre, especialidad, cedula, universidad, experiencia, telefono, zona, direccion, modos,
              seguros, idiomas, dias, horas, bio, servicios, padecimientos, color, terminos_aceptados)
  on public.doctores to authenticated;
-- Lo que puede editar después (nombre y cédula quedan fijos tras el registro).
grant update (especialidad, universidad, experiencia, telefono, zona, direccion, modos, seguros, idiomas, dias, horas,
              bio, servicios, padecimientos, color)
  on public.doctores to authenticated;

drop policy if exists "doctores: directorio público" on public.doctores;
drop policy if exists "doctores: registrarse" on public.doctores;
drop policy if exists "doctores: editar el propio" on public.doctores;
create policy "doctores: directorio público" on public.doctores for select to anon, authenticated
  using ((verificado and tarjeta_ok and not suspendido) or user_id = auth.uid());
create policy "doctores: registrarse" on public.doctores for insert to authenticated
  with check (user_id = auth.uid());
create policy "doctores: editar el propio" on public.doctores for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Al registrarse, el médico queda vinculado a su agenda (permite bloquear horarios y responder opiniones).
create or replace function public.vincular_medico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into medicos (user_id, doctor_id) values (new.user_id, new.id)
  on conflict (user_id) do update set doctor_id = excluded.doctor_id;
  return new;
end $$;
drop trigger if exists doctores_vincular on public.doctores;
create trigger doctores_vincular after insert on public.doctores for each row execute function public.vincular_medico();

-- El médico lee su perfil completo (incluye teléfono y estado de su tarjeta).
create or replace function public.mi_doctor() returns setof public.doctores
language sql stable security definer set search_path = public as $$
  select * from doctores where user_id = auth.uid()
$$;
revoke all on function public.mi_doctor() from public, anon;
grant execute on function public.mi_doctor() to authenticated;

-- ---------- Asistencia en las citas ----------
alter table public.citas add column if not exists asistencia_medico   text check (asistencia_medico   in ('asistio','no_asistio'));
alter table public.citas add column if not exists asistencia_paciente text check (asistencia_paciente in ('asistio','no_asistio'));
alter table public.citas add column if not exists asistencia_en       timestamptz;
alter table public.citas add column if not exists cancelada_por       text check (cancelada_por in ('paciente','medico'));

-- El paciente ya no puede escribir la asistencia ni quién canceló: eso va por funciones con reglas.
revoke update on public.citas from anon, authenticated;
grant update (fecha, hora, modalidad, paciente, motivo, estado, cubierta, precio, slot, servicio, cancelada_en)
  on public.citas to authenticated;

-- El médico ve las citas de su agenda (nombre del paciente, servicio y motivo, para atenderlo).
drop policy if exists "citas: el médico ve las de su agenda" on public.citas;
create policy "citas: el médico ve las de su agenda" on public.citas for select to authenticated
  using (exists (select 1 from medicos m where m.user_id = auth.uid() and m.doctor_id = citas.doctor_id));

-- Momento de inicio de la cita (hora de la Ciudad de México).
create or replace function public.inicio_cita(p_fecha date, p_hora text) returns timestamptz
language sql stable as $$ select ((p_fecha + p_hora::time) at time zone 'America/Mexico_City') $$;

-- El médico marca asistencia: desde que empieza la cita y hasta 72 h después.
create or replace function public.marcar_asistencia(p_cita uuid, p_valor text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_valor not in ('asistio','no_asistio') then raise exception 'Valor no válido'; end if;
  update citas c set asistencia_medico = p_valor, asistencia_en = now()
   where c.id = p_cita and c.estado = 'confirmada'
     and exists (select 1 from medicos m where m.user_id = auth.uid() and m.doctor_id = c.doctor_id)
     and now() >= inicio_cita(c.fecha, c.hora)
     and now() <= inicio_cita(c.fecha, c.hora) + interval '72 hours';
  if not found then raise exception 'Esta cita ya no se puede marcar'; end if;
end $$;

-- El paciente confirma si asistió: desde que empieza la cita y hasta 7 días después.
create or replace function public.confirmar_asistencia(p_cita uuid, p_valor text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_valor not in ('asistio','no_asistio') then raise exception 'Valor no válido'; end if;
  update citas c set asistencia_paciente = p_valor
   where c.id = p_cita and c.user_id = auth.uid() and c.estado = 'confirmada'
     and now() >= inicio_cita(c.fecha, c.hora)
     and now() <= inicio_cita(c.fecha, c.hora) + interval '7 days';
  if not found then raise exception 'Esta cita ya no se puede confirmar'; end if;
end $$;

-- El médico cancela una cita futura (no genera comisión y libera el horario).
create or replace function public.cancelar_por_medico(p_cita uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_slot text;
begin
  update citas c set estado = 'cancelada', cancelada_por = 'medico', cancelada_en = now()
   where c.id = p_cita and c.estado = 'confirmada' and now() < inicio_cita(c.fecha, c.hora)
     and exists (select 1 from medicos m where m.user_id = auth.uid() and m.doctor_id = c.doctor_id)
  returning slot into v_slot;
  if not found then raise exception 'Esta cita ya no se puede cancelar'; end if;
  delete from ocupados where id = v_slot;
end $$;

revoke all on function public.marcar_asistencia(uuid, text), public.confirmar_asistencia(uuid, text),
                       public.cancelar_por_medico(uuid) from public, anon;
grant execute on function public.marcar_asistencia(uuid, text), public.confirmar_asistencia(uuid, text),
                          public.cancelar_por_medico(uuid) to authenticated;

-- ---------- Regla de comisión por cita ----------
-- cobrable · no_asistio · en_revision · por_confirmar · pendiente · sin_comision
create or replace function public.estado_comision(c public.citas) returns text
language sql stable as $$
  select case
    when c.estado = 'cancelada' then 'sin_comision'
    when now() < inicio_cita(c.fecha, c.hora) then 'pendiente'
    when c.asistencia_medico = 'no_asistio' and c.asistencia_paciente = 'asistio' then 'en_revision'
    when c.asistencia_medico = 'no_asistio' then 'no_asistio'
    when c.asistencia_medico = 'asistio' then 'cobrable'
    when c.asistencia_paciente = 'no_asistio' then 'no_asistio'
    when now() > inicio_cita(c.fecha, c.hora) + interval '72 hours' then 'cobrable'
    else 'por_confirmar'
  end
$$;

-- Estado de cuenta del médico (solo de su agenda).
create or replace function public.estado_cuenta(p_desde date, p_hasta date)
returns table (cita_id uuid, fecha date, hora text, paciente text, servicio text, precio integer, cubierta boolean,
               estado text, comision numeric, credito numeric)
language sql stable security definer set search_path = public as $$
  select c.id, c.fecha, c.hora, c.paciente, c.servicio, c.precio, c.cubierta, estado_comision(c),
         case when estado_comision(c) = 'cobrable' and not c.cubierta then round(c.precio * d.comision, 2) else 0 end,
         case when estado_comision(c) = 'cobrable' and c.cubierta then round(c.precio * (1 - d.comision), 2) else 0 end
    from citas c
    join doctores d on d.id = c.doctor_id
   where d.user_id = auth.uid() and c.fecha between p_desde and p_hasta
   order by c.fecha, c.hora
$$;
revoke all on function public.estado_cuenta(date, date) from public, anon;
grant execute on function public.estado_cuenta(date, date) to authenticated;

-- ---------- Cobros mensuales a médicos ----------
create table if not exists public.cobros_medicos (
  id               uuid primary key default gen_random_uuid(),
  doctor_id        text not null references public.doctores(id) on delete cascade,
  periodo_inicio   date not null,
  periodo_fin      date not null,
  consultas        integer not null default 0,
  comisiones       numeric(10,2) not null default 0,
  creditos         numeric(10,2) not null default 0,
  neto             numeric(10,2) not null default 0,   -- positivo: lo paga el médico · negativo: se le transfiere
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','pagado','fallido','a_favor_medico','sin_cargo','en_revision')),
  stripe_payment_intent text,
  error            text,
  intentos         integer not null default 0,
  creado           timestamptz not null default now(),
  unique (doctor_id, periodo_inicio)
);
alter table public.cobros_medicos add column if not exists intentos integer not null default 0;
alter table public.cobros_medicos enable row level security;
revoke all on public.cobros_medicos from anon, authenticated;
grant select on public.cobros_medicos to authenticated;
drop policy if exists "cobros: el médico ve los suyos" on public.cobros_medicos;
create policy "cobros: el médico ve los suyos" on public.cobros_medicos for select to authenticated
  using (exists (select 1 from doctores d where d.id = cobros_medicos.doctor_id and d.user_id = auth.uid()));

-- Resumen por médico para el cobro (solo lo usa el servidor).
create or replace function public.resumen_comisiones(p_desde date, p_hasta date)
returns table (doctor_id text, consultas integer, comisiones numeric, creditos numeric, en_revision integer)
language sql stable security definer set search_path = public as $$
  select d.id,
         count(*) filter (where estado_comision(c) = 'cobrable')::int,
         coalesce(sum(round(c.precio * d.comision, 2)) filter (where estado_comision(c) = 'cobrable' and not c.cubierta), 0),
         coalesce(sum(round(c.precio * (1 - d.comision), 2)) filter (where estado_comision(c) = 'cobrable' and c.cubierta), 0),
         count(*) filter (where estado_comision(c) = 'en_revision')::int
    from doctores d
    join citas c on c.doctor_id = d.id
   where c.fecha between p_desde and p_hasta
   group by d.id
$$;
revoke all on function public.resumen_comisiones(date, date) from public, anon, authenticated;

-- Tiempo real para la agenda del médico.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'doctores') then
    execute 'alter publication supabase_realtime add table public.doctores';
  end if;
end $$;

-- ---------- Para Health Digital (administración) ----------
-- Verificar a un médico después de revisar su cédula en cedulaprofesional.sep.gob.mx:
--   update public.doctores set verificado = true where cedula = '12345678';
-- Resolver una consulta en revisión (sí asistió → se cobra; no asistió → no se cobra):
--   update public.citas set asistencia_paciente = 'no_asistio' where id = '...';  -- a favor del médico
--   update public.citas set asistencia_medico = 'asistio' where id = '...';      -- a favor de Health Digital

-- ---------- Actualización 5: foto, web y redes de médicos ----------
-- Nuevas columnas del perfil público
alter table public.doctores add column if not exists foto_url text
  check (foto_url is null or (char_length(foto_url) <= 500
         and foto_url ~ '^https://[^[:space:]]+/storage/v1/object/public/fotos-medicos/'));
alter table public.doctores add column if not exists web text
  check (web is null or (char_length(web) <= 200 and web ~ '^https://[^[:space:]<>"]+$'));
alter table public.doctores add column if not exists redes jsonb not null default '{}'::jsonb
  check (jsonb_typeof(redes) = 'object'
         and not jsonb_path_exists(redes, '$.* ? (!(@ like_regex "^https://[^ <>\"]+$"))'));

grant select (foto_url, web, redes) on public.doctores to anon, authenticated;
grant insert (foto_url, web, redes) on public.doctores to authenticated;
grant update (foto_url, web, redes) on public.doctores to authenticated;

-- Carpeta pública para las fotos (máximo 2 MB, solo imágenes)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-medicos', 'fotos-medicos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- Cada médico solo puede subir, cambiar o borrar su propia foto (carpeta con su id de usuario)
drop policy if exists "fotos medicos: subir la propia" on storage.objects;
drop policy if exists "fotos medicos: cambiar la propia" on storage.objects;
drop policy if exists "fotos medicos: borrar la propia" on storage.objects;
drop policy if exists "fotos medicos: ver la propia" on storage.objects;
create policy "fotos medicos: subir la propia" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "fotos medicos: cambiar la propia" on storage.objects for update to authenticated
  using (bucket_id = 'fotos-medicos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'fotos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "fotos medicos: borrar la propia" on storage.objects for delete to authenticated
  using (bucket_id = 'fotos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "fotos medicos: ver la propia" on storage.objects for select to authenticated
  using (bucket_id = 'fotos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
