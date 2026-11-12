-- =====================================================================
-- Health Digital · Actualización 7: reservas, precios y privacidad en el servidor
-- Responde a los hallazgos P0 de la auditoría del 3 de noviembre de 2026.
--
-- Qué cambia:
--   1. Las citas ya no se escriben directamente desde el navegador. Reservar, cambiar
--      y cancelar pasan por funciones del servidor que hacen todo en una sola transacción.
--   2. El precio, la duración y la cobertura los calcula el servidor a partir del
--      catálogo del médico. El navegador solo envía identificadores.
--   3. Dos citas del mismo médico no pueden encimarse (rango de tiempo, no solo hora de inicio).
--   4. Las consultas incluidas en membresía quedan APAGADAS por una bandera hasta tener
--      convenio y tarifa con médicos. Los datos existentes se conservan.
--   5. El público ya no puede leer user_id ni cita_id de horarios ocupados ni de opiniones.
--   6. Las citas no se borran: se cancelan antes de su hora o quedan como evidencia.
--   7. Si un médico verificado cambia especialidad o cédula, vuelve a revisión.
--   8. Bandeja de eventos de Stripe y obligaciones de cobro (para las funciones del servidor).
--
-- Cómo usarlo: córrelo PRIMERO en un proyecto de prueba (staging). Después, en el real.
-- Requiere las actualizaciones 1 a 6. Se puede correr más de una vez.
-- Después de correrlo, publica también la nueva versión de la app (index.html) y de las
-- funciones pagos, stripe-webhook y cobrar-comisiones: la app anterior ya no podrá reservar.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------- 0. Banderas de la plataforma ----------
create table if not exists public.config_plataforma (
  clave       text primary key,
  valor       jsonb not null,
  actualizado timestamptz not null default now()
);
alter table public.config_plataforma enable row level security;
revoke all on public.config_plataforma from anon, authenticated;
grant select on public.config_plataforma to anon, authenticated;
drop policy if exists "config: lectura pública" on public.config_plataforma;
create policy "config: lectura pública" on public.config_plataforma for select to anon, authenticated using (true);
-- Consultas incluidas en membresía: apagado hasta que exista convenio y tarifa de red aprobados.
insert into public.config_plataforma (clave, valor) values ('cobertura_membresia', 'false'::jsonb)
  on conflict (clave) do nothing;
-- Venta de membresías: apagada por la misma razón (la función "pagos" la revisa).
insert into public.config_plataforma (clave, valor) values ('venta_membresias', 'false'::jsonb)
  on conflict (clave) do nothing;

create or replace function public.bandera(p_clave text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select valor = 'true'::jsonb from config_plataforma where clave = p_clave), false)
$$;
revoke all on function public.bandera(text) from public;
grant execute on function public.bandera(text) to anon, authenticated;

-- ---------- 1. Columnas nuevas de citas y horarios ----------
alter table public.citas add column if not exists servicio_id  text;
alter table public.citas add column if not exists duracion_min integer check (duracion_min between 5 and 480);
alter table public.citas add column if not exists inicio       timestamptz;
alter table public.citas add column if not exists fin          timestamptz;
alter table public.citas add column if not exists zona_horaria text not null default 'America/Mexico_City';
alter table public.citas add column if not exists idem_key     text check (idem_key is null or char_length(idem_key) between 8 and 80);
alter table public.citas add column if not exists reglas       jsonb;        -- comisión y precio acordados al reservar
alter table public.citas add column if not exists liquidada    boolean not null default false; -- ya entró en un cierre de cobro
create unique index if not exists citas_idem_idx on public.citas(user_id, idem_key) where idem_key is not null;

update public.citas set inicio = public.inicio_cita(fecha, hora) where inicio is null;
update public.citas set duracion_min = 30 where duracion_min is null;
update public.citas set fin = inicio + make_interval(mins => duracion_min) where fin is null;

alter table public.ocupados add column if not exists inicio  timestamptz;
alter table public.ocupados add column if not exists fin     timestamptz;
alter table public.ocupados add column if not exists cita_id uuid references public.citas(id) on delete set null;
update public.ocupados o set inicio = public.inicio_cita(o.fecha, o.hora) where o.inicio is null;
update public.ocupados o set fin = coalesce((select c.fin from public.citas c where c.slot = o.id and c.estado = 'confirmada' limit 1),
                                            o.inicio + interval '30 minutes')
 where o.fin is null;
update public.ocupados o set cita_id = (select c.id from public.citas c where c.slot = o.id and c.estado = 'confirmada' limit 1)
 where o.cita_id is null and o.tipo = 'cita';
alter table public.ocupados alter column inicio set not null;
alter table public.ocupados alter column fin set not null;

-- Sin encimar: un médico no puede tener dos intervalos ocupados que se crucen.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ocupados_sin_encimar') then
    alter table public.ocupados add constraint ocupados_sin_encimar
      exclude using gist (doctor_id with =, tstzrange(inicio, fin, '[)') with &&);
  end if;
end $$;

-- ---------- 2. Sin escritura directa del navegador ----------
revoke insert, update, delete on public.citas from anon, authenticated;
drop policy if exists "citas: crear las propias"  on public.citas;
drop policy if exists "citas: editar las propias" on public.citas;
drop policy if exists "citas: borrar las propias" on public.citas;

revoke insert, update, delete on public.ocupados from anon, authenticated;
drop policy if exists "ocupados: reservar"          on public.ocupados;
drop policy if exists "ocupados: liberar lo propio" on public.ocupados;

-- Lectura pública de horarios: solo columnas sin datos del paciente.
revoke select on public.ocupados from anon, authenticated;
grant select (id, doctor_id, fecha, hora, modalidad, tipo, inicio, fin) on public.ocupados to anon, authenticated;

-- Opiniones públicas sin user_id ni cita_id.
revoke select on public.resenas from anon, authenticated;
grant select (id, doctor_id, estrellas, texto, fecha, puntualidad, trato, instalaciones, respuesta, respondida)
  on public.resenas to anon, authenticated;
revoke insert on public.resenas from anon, authenticated;
grant insert (doctor_id, cita_id, estrellas, texto, puntualidad, trato, instalaciones) on public.resenas to authenticated;

-- Solo opina quien tiene evidencia de haber sido atendido (marca del médico o del paciente),
-- nunca si el médico marcó "no asistió", una vez por cita.
drop policy if exists "resenas: solo con cita atendida" on public.resenas;
create policy "resenas: solo con cita atendida" on public.resenas for insert to authenticated
  with check (
    user_id = auth.uid() and exists (
      select 1 from public.citas c
       where c.id = resenas.cita_id and c.user_id = auth.uid() and c.doctor_id = resenas.doctor_id
         and c.estado <> 'cancelada' and c.inicio < now()
         and c.asistencia_medico is distinct from 'no_asistio'
         and (c.estado = 'completada' or c.asistencia_medico = 'asistio' or c.asistencia_paciente = 'asistio')
    )
  );

-- El paciente consulta en qué citas ya opinó (sin exponer el vínculo al público).
create or replace function public.mis_resenas() returns table (id uuid, cita_id uuid)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, r.cita_id from resenas r where r.user_id = auth.uid()
$$;
revoke all on function public.mis_resenas() from public, anon;
grant execute on function public.mis_resenas() to authenticated;

-- ---------- 3. Funciones auxiliares ----------
create or replace function public.hd_error(p_codigo text, p_mensaje text) returns void
language plpgsql as $$ begin raise exception using errcode = 'P0001', message = p_codigo, detail = p_mensaje; end $$;

-- Médico que se puede reservar: verificado, activo y con tarjeta para la comisión.
create or replace function public.doctor_reservable(p_doctor text) returns public.doctores
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d doctores;
begin
  select * into d from doctores where id = p_doctor;
  if not found or not d.verificado or d.suspendido or not d.tarjeta_ok then
    perform hd_error('medico_no_disponible', 'Este profesional no está disponible para reservar.');
  end if;
  return d;
end $$;
revoke all on function public.doctor_reservable(text) from public, anon, authenticated;

-- Periodo de beneficios del titular: el ciclo de facturación vigente (renovación − 1 mes, renovación].
create or replace function public.periodo_beneficio(p perfiles, out desde timestamptz, out hasta timestamptz)
language sql stable as $$
  select p.renovacion - interval '1 month', p.renovacion
$$;
revoke all on function public.periodo_beneficio(perfiles) from public, anon, authenticated;

-- Valida horario contra la agenda del médico y devuelve el servicio.
create or replace function public.validar_agenda(d doctores, p_servicio text, p_fecha date, p_hora text, p_modalidad text,
                                                 out serv jsonb, out inicio timestamptz, out fin timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_min int;
begin
  select s into serv from jsonb_array_elements(d.servicios) s where s->>'id' = p_servicio limit 1;
  if serv is null then perform hd_error('servicio_invalido', 'Ese servicio no existe para este profesional.'); end if;
  if coalesce((serv->>'p')::int, -1) < 0 then perform hd_error('servicio_invalido', 'Servicio sin precio.'); end if;
  if not (d.modos ? p_modalidad) then perform hd_error('modalidad_invalida', 'El profesional no ofrece esa modalidad.'); end if;
  if p_hora !~ '^[0-9]{2}:[0-9]{2}$' or not (d.horas ? p_hora) then perform hd_error('fuera_de_agenda', 'Ese horario no está en la agenda.'); end if;
  if not (d.dias @> to_jsonb(extract(dow from p_fecha)::int)) then perform hd_error('fuera_de_agenda', 'El profesional no atiende ese día.'); end if;
  inicio := inicio_cita(p_fecha, p_hora);
  if inicio <= now() then perform hd_error('fuera_de_agenda', 'Ese horario ya pasó.'); end if;
  if p_fecha > hoy_mx() + 90 then perform hd_error('fuera_de_agenda', 'Solo se puede reservar hasta 90 días.'); end if;
  v_min := coalesce(nullif(serv->>'min', '')::int, 30);
  if v_min < 5 or v_min > 480 then v_min := 30; end if;
  fin := inicio + make_interval(mins => v_min);
end $$;
revoke all on function public.validar_agenda(doctores, text, date, text, text) from public, anon, authenticated;

-- Decide si la cita va cubierta por membresía (bandera, servicio elegible, plan activo y cupo del periodo).
-- Debe llamarse con el bloqueo del titular tomado.
create or replace function public.cobertura_disponible(p_uid uuid, p_serv jsonb, p_inicio timestamptz, p_excluir uuid)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p perfiles; v_desde timestamptz; v_hasta timestamptz; v_usadas int;
begin
  if not bandera('cobertura_membresia') then return false; end if;
  if coalesce((p_serv->>'mem')::boolean, false) is false then return false; end if;
  select * into p from perfiles where id = p_uid;
  if not found or p.plan is null or coalesce(p.plan_estado, '') not in ('active','trialing') or p.renovacion is null then return false; end if;
  select b.desde, b.hasta into v_desde, v_hasta from periodo_beneficio(p) b;
  if p_inicio > v_hasta then return false; end if;               -- la cita cae después del periodo pagado
  select count(*) into v_usadas from citas c
   where c.user_id = p_uid and c.cubierta and c.estado <> 'cancelada'
     and c.creada > v_desde and c.creada <= v_hasta and c.id is distinct from p_excluir;
  return v_usadas < case p.plan when 'familiar' then 2 else 1 end;
end $$;
revoke all on function public.cobertura_disponible(uuid, jsonb, timestamptz, uuid) from public, anon, authenticated;

-- ---------- 4. Reservar ----------
create or replace function public.reservar_cita(
  p_doctor text, p_servicio text, p_fecha date, p_hora text, p_modalidad text,
  p_paciente text, p_motivo text, p_usar_membresia boolean, p_idem text)
returns public.citas
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); d doctores; p perfiles; v jsonb; v_ini timestamptz; v_fin timestamptz;
  v_cubierta boolean := false; v_key text; c citas;
begin
  if v_uid is null then perform hd_error('sin_sesion', 'Inicia sesión para reservar.'); end if;
  if p_idem is null or char_length(p_idem) not between 8 and 80 then perform hd_error('solicitud_invalida', 'Falta el identificador de la solicitud.'); end if;

  -- Reintento o doble clic: devuelve la misma cita.
  select * into c from citas where user_id = v_uid and idem_key = p_idem;
  if found then return c; end if;

  -- Un titular a la vez (evita usar dos veces el mismo beneficio y reservas duplicadas en paralelo).
  perform pg_advisory_xact_lock(hashtextextended('titular:' || v_uid::text, 0));
  select * into c from citas where user_id = v_uid and idem_key = p_idem;
  if found then return c; end if;

  select * into p from perfiles where id = v_uid;
  if not found then perform hd_error('sin_perfil', 'Completa tu perfil antes de reservar.'); end if;
  p_paciente := btrim(coalesce(p_paciente, ''));
  if p_paciente <> p.nombre and not exists (
       select 1 from jsonb_array_elements(case when p.plan = 'familiar' then p.miembros else '[]'::jsonb end) m
        where m->>'nombre' = p_paciente) then
    perform hd_error('paciente_invalido', 'El paciente debe ser el titular o un familiar registrado.');
  end if;
  if p_motivo is not null and char_length(p_motivo) > 300 then perform hd_error('motivo_largo', 'El motivo es demasiado largo.'); end if;

  d := doctor_reservable(p_doctor);
  select a.serv, a.inicio, a.fin into v, v_ini, v_fin from validar_agenda(d, p_servicio, p_fecha, p_hora, p_modalidad) a;

  if coalesce(p_usar_membresia, false) then
    v_cubierta := cobertura_disponible(v_uid, v, v_ini, null);
    if not v_cubierta then perform hd_error('sin_cobertura', 'Esta cita no se puede cubrir con tu membresía.'); end if;
  end if;

  v_key := d.id || '_' || p_fecha::text || '_' || replace(p_hora, ':', '');
  begin
    insert into ocupados (id, doctor_id, fecha, hora, modalidad, tipo, user_id, inicio, fin)
    values (v_key, d.id, p_fecha, p_hora, p_modalidad, 'cita', v_uid, v_ini, v_fin);
  exception when unique_violation or exclusion_violation then
    perform hd_error('horario_ocupado', 'Ese horario ya no está disponible.');
  end;

  insert into citas (user_id, doctor_id, fecha, hora, modalidad, paciente, motivo, estado, cubierta, precio,
                     servicio, servicio_id, duracion_min, inicio, fin, slot, folio, idem_key, reglas)
  values (v_uid, d.id, p_fecha, p_hora, p_modalidad, p_paciente, nullif(btrim(p_motivo), ''), 'confirmada', v_cubierta,
          (v->>'p')::int, left(v->>'n', 120), v->>'id', extract(epoch from (v_fin - v_ini))::int / 60, v_ini, v_fin,
          v_key, 'HD' || upper(substr(md5(gen_random_uuid()::text), 1, 8)), p_idem,
          jsonb_build_object('comision', d.comision, 'precio', (v->>'p')::int, 'servicio', v, 'reservada', now()))
  returning * into c;
  update ocupados set cita_id = c.id where id = v_key;
  return c;
end $$;
revoke all on function public.reservar_cita(text, text, date, text, text, text, text, boolean, text) from public, anon;
grant execute on function public.reservar_cita(text, text, date, text, text, text, text, boolean, text) to authenticated;

-- ---------- 5. Cambiar fecha u hora (mismo médico y servicio) ----------
create or replace function public.reprogramar_cita(p_cita uuid, p_fecha date, p_hora text, p_modalidad text)
returns public.citas
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); c citas; d doctores; v jsonb; v_ini timestamptz; v_fin timestamptz; v_key text; v_cub boolean;
begin
  if v_uid is null then perform hd_error('sin_sesion', 'Inicia sesión.'); end if;
  perform pg_advisory_xact_lock(hashtextextended('titular:' || v_uid::text, 0));
  select * into c from citas where id = p_cita and user_id = v_uid for update;
  if not found then perform hd_error('cita_no_encontrada', 'No encontramos esa cita.'); end if;
  if c.estado <> 'confirmada' or c.inicio <= now() or c.liquidada then
    perform hd_error('cita_cerrada', 'Esta cita ya no se puede cambiar.');
  end if;
  d := doctor_reservable(c.doctor_id);
  select a.serv, a.inicio, a.fin into v, v_ini, v_fin from validar_agenda(d, c.servicio_id, p_fecha, p_hora, p_modalidad) a;
  v_cub := c.cubierta and cobertura_disponible(v_uid, v, v_ini, c.id);
  if c.cubierta and not v_cub then perform hd_error('sin_cobertura', 'La nueva fecha queda fuera de tu membresía.'); end if;

  delete from ocupados where id = c.slot;
  v_key := d.id || '_' || p_fecha::text || '_' || replace(p_hora, ':', '');
  begin
    insert into ocupados (id, doctor_id, fecha, hora, modalidad, tipo, user_id, inicio, fin, cita_id)
    values (v_key, d.id, p_fecha, p_hora, p_modalidad, 'cita', v_uid, v_ini, v_fin, c.id);
  exception when unique_violation or exclusion_violation then
    perform hd_error('horario_ocupado', 'Ese horario ya no está disponible.');  -- revierte todo: la cita anterior queda igual
  end;
  update citas set fecha = p_fecha, hora = p_hora, modalidad = p_modalidad, inicio = v_ini, fin = v_fin, slot = v_key
   where id = c.id returning * into c;
  return c;
end $$;
revoke all on function public.reprogramar_cita(uuid, date, text, text) from public, anon;
grant execute on function public.reprogramar_cita(uuid, date, text, text) to authenticated;

-- ---------- 6. Cancelar (solo antes de que empiece) ----------
create or replace function public.cancelar_cita(p_cita uuid) returns public.citas
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); c citas;
begin
  if v_uid is null then perform hd_error('sin_sesion', 'Inicia sesión.'); end if;
  select * into c from citas where id = p_cita and user_id = v_uid for update;
  if not found then perform hd_error('cita_no_encontrada', 'No encontramos esa cita.'); end if;
  if c.estado <> 'confirmada' or c.inicio <= now() or c.liquidada then
    perform hd_error('cita_cerrada', 'Esta cita ya no se puede cancelar.');
  end if;
  update citas set estado = 'cancelada', cancelada_por = 'paciente', cancelada_en = now() where id = c.id returning * into c;
  delete from ocupados where id = c.slot;
  return c;
end $$;
revoke all on function public.cancelar_cita(uuid) from public, anon;
grant execute on function public.cancelar_cita(uuid) to authenticated;

-- El médico cancela: misma regla y ahora también deja registro de quién y cuándo.
create or replace function public.cancelar_por_medico(p_cita uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_slot text;
begin
  update citas c set estado = 'cancelada', cancelada_por = 'medico', cancelada_en = now()
   where c.id = p_cita and c.estado = 'confirmada' and now() < c.inicio and not c.liquidada
     and exists (select 1 from medicos m where m.user_id = auth.uid() and m.doctor_id = c.doctor_id)
  returning slot into v_slot;
  if not found then perform hd_error('cita_cerrada', 'Esta cita ya no se puede cancelar.'); end if;
  delete from ocupados where id = v_slot;
end $$;

-- ---------- 7. Bloqueos de agenda del médico ----------
create or replace function public.bloquear_horario(p_fecha date, p_hora text, p_min integer default 30) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_doc text; v_ini timestamptz;
begin
  select m.doctor_id into v_doc from medicos m where m.user_id = auth.uid();
  if v_doc is null then perform hd_error('no_medico', 'Solo el médico de esta agenda puede bloquear horarios.'); end if;
  if p_hora !~ '^[0-9]{2}:[0-9]{2}$' or p_fecha < hoy_mx() then perform hd_error('fuera_de_agenda', 'Horario no válido.'); end if;
  v_ini := inicio_cita(p_fecha, p_hora);
  begin
    insert into ocupados (id, doctor_id, fecha, hora, tipo, user_id, inicio, fin)
    values (v_doc || '_' || p_fecha::text || '_' || replace(p_hora, ':', ''), v_doc, p_fecha, p_hora, 'bloqueo', auth.uid(),
            v_ini, v_ini + make_interval(mins => greatest(5, least(coalesce(p_min, 30), 480))));
  exception when unique_violation or exclusion_violation then
    perform hd_error('horario_ocupado', 'Ese horario ya está ocupado.');
  end;
end $$;
create or replace function public.liberar_bloqueo(p_fecha date, p_hora text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from ocupados o using medicos m
   where m.user_id = auth.uid() and o.doctor_id = m.doctor_id and o.tipo = 'bloqueo'
     and o.fecha = p_fecha and o.hora = p_hora;
  if not found then perform hd_error('no_encontrado', 'No hay un bloqueo en ese horario.'); end if;
end $$;
revoke all on function public.bloquear_horario(date, text, integer), public.liberar_bloqueo(date, text) from public, anon;
grant execute on function public.bloquear_horario(date, text, integer), public.liberar_bloqueo(date, text) to authenticated;

-- ---------- 8. Borrar mis datos (sin destruir evidencia de consultas) ----------
-- Cancela las citas futuras, anonimiza las pasadas (se conservan para conciliación con médicos)
-- y borra el perfil. La cuenta de acceso y Stripe se atienden aparte (ver SEGURIDAD.md).
create or replace function public.borrar_mis_datos() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform hd_error('sin_sesion', 'Inicia sesión.'); end if;
  delete from ocupados where user_id = v_uid and tipo = 'cita'
     and cita_id in (select id from citas where user_id = v_uid and estado = 'confirmada' and inicio > now());
  update citas set estado = 'cancelada', cancelada_por = 'paciente', cancelada_en = now()
   where user_id = v_uid and estado = 'confirmada' and inicio > now();
  update citas set paciente = 'Paciente', motivo = null where user_id = v_uid;
  delete from perfiles where id = v_uid;
end $$;
revoke all on function public.borrar_mis_datos() from public, anon;
grant execute on function public.borrar_mis_datos() to authenticated;

-- Las funciones viejas de cupo ya no se usan desde el navegador.
revoke all on function public.cupo_ok(date, uuid) from public, anon, authenticated;

-- ---------- 9. Cambios materiales del médico vuelven a revisión ----------
create or replace function public.doctores_revision() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Solo aplica a cambios hechos por el propio médico (las correcciones de administración no tienen auth.uid()).
  if auth.uid() is not null and old.verificado and
     (new.especialidad is distinct from old.especialidad or new.cedula is distinct from old.cedula
      or new.nombre is distinct from old.nombre) then
    new.verificado := false;
  end if;
  return new;
end $$;
drop trigger if exists doctores_revision on public.doctores;
create trigger doctores_revision before update on public.doctores for each row execute function public.doctores_revision();

-- ---------- 10. Comisión: precio acordado al reservar y citas liquidadas ----------
-- (estado_comision y resumen_comisiones siguen leyendo c.precio, que ahora solo escribe el servidor.)

-- ---------- 11. Cobros: bandeja de eventos de Stripe y obligaciones ----------
create table if not exists public.stripe_eventos (
  id          text primary key,             -- event.id de Stripe
  tipo        text not null,
  estado      text not null default 'recibido' check (estado in ('recibido','procesando','procesado','fallido')),
  intentos    integer not null default 0,
  error       text,
  recibido    timestamptz not null default now(),
  procesado   timestamptz
);
alter table public.stripe_eventos enable row level security;
revoke all on public.stripe_eventos from anon, authenticated;

-- Un cobro por médico y periodo; la clave de Stripe queda fija aunque se reintente.
alter table public.cobros_medicos add column if not exists idem_key       text;
alter table public.cobros_medicos add column if not exists saldo_anterior numeric(10,2) not null default 0;
alter table public.cobros_medicos add column if not exists bloqueado_hasta timestamptz;
alter table public.cobros_medicos drop constraint if exists cobros_medicos_estado_check;
alter table public.cobros_medicos add constraint cobros_medicos_estado_check
  check (estado in ('pendiente','procesando','requiere_accion','pagado','fallido','a_favor_medico','sin_cargo','arrastrado','en_revision'));
update public.cobros_medicos set idem_key = 'cobro-' || id::text where idem_key is null;

-- Movimientos (ledger) por médico: nada se borra; los ajustes son movimientos nuevos.
create table if not exists public.movimientos_medico (
  id          uuid primary key default gen_random_uuid(),
  doctor_id   text not null references public.doctores(id) on delete restrict,
  cobro_id    uuid references public.cobros_medicos(id) on delete restrict,
  tipo        text not null check (tipo in ('comision','credito_membresia','arrastre','pago','transferencia','ajuste')),
  monto       numeric(10,2) not null,          -- positivo: debe el médico · negativo: se le debe
  nota        text,
  creado      timestamptz not null default now(),
  creado_por  text not null default 'sistema'
);
alter table public.movimientos_medico enable row level security;
revoke all on public.movimientos_medico from anon, authenticated;
grant select on public.movimientos_medico to authenticated;
drop policy if exists "movimientos: el médico ve los suyos" on public.movimientos_medico;
create policy "movimientos: el médico ve los suyos" on public.movimientos_medico for select to authenticated
  using (exists (select 1 from medicos m where m.doctor_id = movimientos_medico.doctor_id and m.user_id = auth.uid()));
-- Igual para los cobros (antes consultaba doctores.user_id, que ya no es público).
drop policy if exists "cobros: el médico ve los suyos" on public.cobros_medicos;
create policy "cobros: el médico ve los suyos" on public.cobros_medicos for select to authenticated
  using (exists (select 1 from medicos m where m.doctor_id = cobros_medicos.doctor_id and m.user_id = auth.uid()));

alter table public.cobros_medicos add column if not exists congelado      boolean not null default false; -- montos fijos desde el primer intento
alter table public.cobros_medicos add column if not exists reintento_pago integer not null default 0;     -- solo sube con un rechazo definitivo
create unique index if not exists movimientos_unicos on public.movimientos_medico(cobro_id, tipo, coalesce(nota, ''))
  where tipo in ('comision','credito_membresia','pago','arrastre','transferencia');
drop function if exists public.saldo_medico(text, date);

-- Médicos a revisar en un periodo: con consultas, con saldo anterior o con un cobro abierto.
create or replace function public.medicos_a_procesar(p_desde date, p_hasta date) returns setof text
language sql stable security definer set search_path = public, pg_temp as $$
  select doctor_id from resumen_comisiones(p_desde, p_hasta)
  union
  select o.doctor_id from cobros_medicos o
   where o.periodo_inicio < p_desde and o.estado in ('arrastrado','a_favor_medico')
     and not exists (select 1 from movimientos_medico m where m.nota = o.id::text and m.tipo in ('arrastre','transferencia'))
  union
  select doctor_id from cobros_medicos where periodo_inicio = p_desde and estado not in ('pagado','sin_cargo','arrastrado','a_favor_medico')
$$;

drop function if exists public.tomar_cobro(text, date, date);
-- Toma el cobro de un periodo con bloqueo de 10 minutos: dos ejecuciones nunca procesan el mismo a la vez.
create or replace function public.tomar_cobro(p_doctor text, p_desde date, p_hasta date) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c cobros_medicos;
begin
  insert into cobros_medicos (doctor_id, periodo_inicio, periodo_fin, estado)
  values (p_doctor, p_desde, p_hasta, 'pendiente')
  on conflict (doctor_id, periodo_inicio) do nothing;
  select * into c from cobros_medicos where doctor_id = p_doctor and periodo_inicio = p_desde for update;
  if c.idem_key is null then update cobros_medicos set idem_key = 'cobro-' || c.id::text where id = c.id returning * into c; end if;
  if c.estado in ('pagado','a_favor_medico','sin_cargo','arrastrado') then
    return jsonb_build_object('tomado', false, 'motivo', 'cerrado', 'cobro', to_jsonb(c));
  end if;
  if c.bloqueado_hasta is not null and c.bloqueado_hasta > now() then
    return jsonb_build_object('tomado', false, 'motivo', 'en_proceso', 'cobro', to_jsonb(c));
  end if;
  update cobros_medicos set bloqueado_hasta = now() + interval '10 minutes', intentos = intentos + 1
   where id = c.id returning * into c;
  return jsonb_build_object('tomado', true, 'cobro', to_jsonb(c));
end $$;

-- Congela los montos del periodo una sola vez: comisiones, créditos y saldo anterior pasan al ledger.
-- Si hay consultas en revisión, no se cobra nada hasta resolverlas.
create or replace function public.congelar_cobro(p_cobro uuid) returns public.cobros_medicos
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c cobros_medicos; r record; v_saldo numeric := 0;
begin
  select * into c from cobros_medicos where id = p_cobro for update;
  if c.congelado then return c; end if;
  select * into r from resumen_comisiones(c.periodo_inicio, c.periodo_fin) x where x.doctor_id = c.doctor_id;
  if coalesce(r.en_revision, 0) > 0 then
    update cobros_medicos set estado = 'en_revision', consultas = coalesce(r.consultas, 0),
           error = r.en_revision || ' consulta(s) en revisión: se cobra al resolverlas'
     where id = c.id returning * into c;
    return c;
  end if;
  -- saldo de periodos anteriores no cobrado (arrastre) o a favor no transferido
  insert into movimientos_medico (doctor_id, cobro_id, tipo, monto, nota)
  select o.doctor_id, c.id, 'arrastre', o.neto, o.id::text from cobros_medicos o
   where o.doctor_id = c.doctor_id and o.periodo_inicio < c.periodo_inicio and o.estado in ('arrastrado','a_favor_medico')
     and not exists (select 1 from movimientos_medico m where m.nota = o.id::text and m.tipo in ('arrastre','transferencia'));
  select coalesce(sum(monto), 0) into v_saldo from movimientos_medico where cobro_id = c.id and tipo = 'arrastre';
  if coalesce(r.comisiones, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto) values (c.doctor_id, c.id, 'comision', r.comisiones) on conflict do nothing;
  end if;
  if coalesce(r.creditos, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto) values (c.doctor_id, c.id, 'credito_membresia', -r.creditos) on conflict do nothing;
  end if;
  update cobros_medicos set consultas = coalesce(r.consultas, 0), comisiones = coalesce(r.comisiones, 0),
         creditos = coalesce(r.creditos, 0), saldo_anterior = v_saldo,
         neto = round(coalesce(r.comisiones, 0) - coalesce(r.creditos, 0) + v_saldo, 2),
         congelado = true, estado = 'pendiente', error = null
   where id = c.id returning * into c;
  update citas set liquidada = true
   where doctor_id = c.doctor_id and fecha between c.periodo_inicio and c.periodo_fin and estado <> 'cancelada';
  return c;
end $$;

-- Cierra el intento: estado final o intermedio, guarda el PaymentIntent y libera el bloqueo.
-- Un rechazo definitivo sube reintento_pago; al segundo rechazo seguido se pausa el perfil.
create or replace function public.cerrar_cobro(p_cobro uuid, p_estado text, p_pi text default null, p_error text default null)
returns public.cobros_medicos
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c cobros_medicos;
begin
  select * into c from cobros_medicos where id = p_cobro for update;
  if c.estado = 'pagado' then
    update cobros_medicos set bloqueado_hasta = null where id = c.id returning * into c;
    return c;                       -- nunca se "despaga"
  end if;
  update cobros_medicos set estado = p_estado, stripe_payment_intent = coalesce(p_pi, stripe_payment_intent),
         error = p_error, bloqueado_hasta = null,
         reintento_pago = reintento_pago + case when p_estado = 'fallido' then 1 else 0 end
   where id = c.id returning * into c;
  if p_estado = 'pagado' then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto, nota)
    values (c.doctor_id, c.id, 'pago', -c.neto, c.stripe_payment_intent) on conflict do nothing;
    update doctores set suspendido = false where id = c.doctor_id and suspendido;
  elsif p_estado = 'fallido' and c.reintento_pago >= 2 then
    update doctores set suspendido = true where id = c.doctor_id;
  end if;
  return c;
end $$;

-- Health Digital registra una transferencia manual al médico (saldo a su favor). Solo administración.
create or replace function public.registrar_transferencia(p_cobro uuid, p_referencia text, p_revisor text)
returns void language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c cobros_medicos;
begin
  if p_referencia is null or p_revisor is null then raise exception 'Faltan referencia y revisor'; end if;
  select * into c from cobros_medicos where id = p_cobro and estado = 'a_favor_medico' for update;
  if not found then raise exception 'No es un saldo a favor'; end if;
  insert into movimientos_medico (doctor_id, cobro_id, tipo, monto, nota, creado_por)
  values (c.doctor_id, c.id, 'transferencia', -c.neto, c.id::text, p_revisor || ' · ' || p_referencia);
end $$;

revoke all on function public.medicos_a_procesar(date, date), public.tomar_cobro(text, date, date),
  public.congelar_cobro(uuid), public.cerrar_cobro(uuid, text, text, text),
  public.registrar_transferencia(uuid, text, text) from public, anon, authenticated;

-- Revisión de consultas en disputa: la decisión queda registrada con revisor y evidencia.
create table if not exists public.revisiones_asistencia (
  id         uuid primary key default gen_random_uuid(),
  cita_id    uuid not null references public.citas(id) on delete restrict,
  decision   text not null check (decision in ('asistio','no_asistio')),
  revisor    text not null check (char_length(revisor) between 2 and 120),
  evidencia  text not null check (char_length(evidencia) between 5 and 1000),
  avisado    boolean not null default false,   -- se avisó al médico antes de cobrar
  creado     timestamptz not null default now()
);
alter table public.revisiones_asistencia enable row level security;
revoke all on public.revisiones_asistencia from anon, authenticated;

create or replace function public.resolver_revision(p_cita uuid, p_decision text, p_revisor text, p_evidencia text, p_avisado boolean)
returns void language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if p_decision not in ('asistio','no_asistio') then raise exception 'Decisión no válida'; end if;
  if not coalesce(p_avisado, false) and p_decision = 'asistio' then raise exception 'Avisa al médico antes de resolver a favor del cobro'; end if;
  insert into revisiones_asistencia (cita_id, decision, revisor, evidencia, avisado) values (p_cita, p_decision, p_revisor, p_evidencia, coalesce(p_avisado, false));
  if p_decision = 'asistio' then
    update citas set asistencia_medico = 'asistio' where id = p_cita and asistencia_medico = 'no_asistio' and asistencia_paciente = 'asistio';
  else
    update citas set asistencia_paciente = 'no_asistio' where id = p_cita and asistencia_medico = 'no_asistio' and asistencia_paciente = 'asistio';
  end if;
  if not found then raise exception 'Esa cita no está en revisión'; end if;
end $$;
revoke all on function public.resolver_revision(uuid, text, text, text, boolean) from public, anon, authenticated;

-- Bandeja de eventos de Stripe: registra cada event.id una vez y su resultado.
create or replace function public.evento_stripe_tomar(p_id text, p_tipo text) returns text
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare e stripe_eventos;
begin
  insert into stripe_eventos (id, tipo) values (p_id, p_tipo) on conflict (id) do nothing;
  select * into e from stripe_eventos where id = p_id for update;
  if e.estado = 'procesado' then return 'procesado'; end if;
  if e.estado = 'procesando' and e.recibido > now() - interval '2 minutes' and e.intentos > 0 then return 'en_proceso'; end if;
  update stripe_eventos set estado = 'procesando', intentos = intentos + 1, recibido = now() where id = p_id;
  return 'tomado';
end $$;
create or replace function public.evento_stripe_cerrar(p_id text, p_ok boolean, p_error text default null) returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  update stripe_eventos set estado = case when p_ok then 'procesado' else 'fallido' end,
         error = p_error, procesado = case when p_ok then now() end where id = p_id
$$;
revoke all on function public.evento_stripe_tomar(text, text), public.evento_stripe_cerrar(text, boolean, text) from public, anon, authenticated;

-- Tiempo real: config también, para que la app vea el cambio de bandera.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'config_plataforma') then
    execute 'alter publication supabase_realtime add table public.config_plataforma';
  end if;
end $$;

-- ---------- 12. Tiempo real sin datos privados ----------
-- Los avisos en tiempo real de ocupados, opiniones y médicos podían incluir columnas privadas
-- (user_id, cita_id, teléfono o datos de Stripe). Se quitan de la publicación y se reemplazan
-- por una tabla de "señales" que solo dice qué cambió; la app vuelve a leer con sus permisos.
create table if not exists public.senales (
  tabla      text primary key,
  version    bigint not null default 0,
  cambiado   timestamptz not null default now()
);
alter table public.senales enable row level security;
revoke all on public.senales from anon, authenticated;
grant select on public.senales to anon, authenticated;
drop policy if exists "senales: lectura pública" on public.senales;
create policy "senales: lectura pública" on public.senales for select to anon, authenticated using (true);
insert into public.senales (tabla) values ('ocupados'), ('resenas'), ('doctores') on conflict do nothing;

create or replace function public.senal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update senales set version = version + 1, cambiado = now() where tabla = tg_table_name;
  return null;
end $$;
drop trigger if exists senal_ocupados on public.ocupados;
drop trigger if exists senal_resenas  on public.resenas;
drop trigger if exists senal_doctores on public.doctores;
create trigger senal_ocupados after insert or update or delete on public.ocupados for each statement execute function public.senal();
create trigger senal_resenas  after insert or update or delete on public.resenas  for each statement execute function public.senal();
create trigger senal_doctores after insert or update or delete on public.doctores for each statement execute function public.senal();

do $$
declare t text;
begin
  foreach t in array array['ocupados','resenas','doctores'] loop
    if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'senales') then
    execute 'alter publication supabase_realtime add table public.senales';
  end if;
end $$;

-- El identificador de cuenta del médico ya no es público.
revoke select (user_id) on public.doctores from anon, authenticated;
