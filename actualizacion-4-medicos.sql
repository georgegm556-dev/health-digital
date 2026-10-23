-- =====================================================================
-- Health Digital · Actualización 4: registro de médicos y comisión del 10%
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Requiere haber corrido antes supabase.sql y las actualizaciones 2 y 3.
-- Se puede correr más de una vez.
--
-- Cómo funciona la comisión:
--   • El paciente paga la consulta completa en el consultorio (efectivo o tarjeta).
--   • El médico registra su tarjeta en la app. Sin tarjeta no aparece en el directorio.
--   • Cada mes se cobra a su tarjeta el 10% de las consultas ATENDIDAS del mes anterior.
--   • Consultas incluidas en membresía: Health Digital le paga al médico el 90%
--     (se descuenta de lo que el médico debe; si queda a su favor, se le transfiere).
--   • No hay comisión si el paciente cancela, si el médico cancela o si el paciente no llega.
--   • Para que no se abuse del "no asistió": el médico tiene 72 h para marcarlo; si no marca
--     nada, la consulta cuenta como atendida. El paciente también confirma; si el médico dice
--     "no asistió" y el paciente dice "sí asistí", la consulta queda EN REVISIÓN y la decide
--     Health Digital.
-- =====================================================================

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
