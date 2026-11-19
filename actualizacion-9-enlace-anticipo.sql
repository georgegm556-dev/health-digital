-- =====================================================================
-- Health Digital · Actualización 9: enlace del médico (0% de comisión), anticipo y colegas
--
-- Decisiones del 19 de noviembre de 2026:
--   1. Pacientes que llegan por el ENLACE o QR del propio médico no pagan comisión.
--      Si el paciente ya llegó antes por la app (búsqueda), sigue contando como paciente de la app.
--   2. Anticipo al reservar (por defecto $200): la plataforma lo cobra con Stripe y lo acredita al
--      médico en su cierre mensual. APAGADO hasta que el contador revise el esquema fiscal:
--      update config_plataforma set valor = 'true' where clave = 'anticipo_activo';
--   3. La comisión se cobra como 10% + IVA (16%) sobre ese 10%.
--   4. "Médicos que recomiendo": cada médico puede mostrar hasta 12 colegas en su perfil.
--
-- Requiere las actualizaciones 7 y 8. Se puede correr más de una vez. No borra datos.
-- =====================================================================

-- ---------- 0. Banderas ----------
insert into public.config_plataforma (clave, valor) values
  ('anticipo_activo', 'false'::jsonb),
  ('anticipo_monto', '200'::jsonb),
  ('iva_comision', '0.16'::jsonb)
on conflict (clave) do nothing;

create or replace function public.config_num(p_clave text, p_defecto numeric) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select (valor #>> '{}')::numeric from config_plataforma where clave = p_clave), p_defecto)
$$;
revoke all on function public.config_num(text, numeric) from public, anon, authenticated;

-- ---------- 1. Origen de la cita y anticipo ----------
alter table public.citas add column if not exists origen text not null default 'app';
alter table public.citas drop constraint if exists citas_origen_check;
alter table public.citas add constraint citas_origen_check check (origen in ('app','enlace_medico'));

alter table public.citas add column if not exists anticipo integer not null default 0 check (anticipo >= 0);
alter table public.citas add column if not exists anticipo_estado text not null default 'no_requerido';
alter table public.citas drop constraint if exists citas_anticipo_estado_check;
alter table public.citas add constraint citas_anticipo_estado_check
  check (anticipo_estado in ('no_requerido','pendiente','pagado','reembolso_pendiente','reembolsado','vencido'));
alter table public.citas add column if not exists stripe_checkout text;

-- El sistema puede cancelar (anticipo no pagado a tiempo).
alter table public.citas drop constraint if exists citas_cancelada_por_check;
alter table public.citas add constraint citas_cancelada_por_check check (cancelada_por in ('paciente','medico','sistema'));

-- ---------- 2. Comisión: paciente propio = sin comisión ----------
create or replace function public.estado_comision(c public.citas) returns text
language sql stable as $$
  select case
    when c.estado = 'cancelada' then 'sin_comision'
    when now() < inicio_cita(c.fecha, c.hora) then 'pendiente'
    when c.asistencia_medico = 'no_asistio' and c.asistencia_paciente = 'asistio' then 'en_revision'
    when c.asistencia_medico = 'no_asistio' then 'no_asistio'
    when c.asistencia_paciente = 'no_asistio' and c.asistencia_medico is distinct from 'asistio' then 'no_asistio'
    when c.origen = 'enlace_medico' then 'paciente_propio'
    when c.asistencia_medico = 'asistio' then 'cobrable'
    when now() > inicio_cita(c.fecha, c.hora) + interval '72 hours' then 'cobrable'
    else 'por_confirmar'
  end
$$;

-- Resumen para el cierre: comisiones, IVA, créditos por membresía y anticipos cobrados por la plataforma.
drop function if exists public.resumen_comisiones(date, date);
create function public.resumen_comisiones(p_desde date, p_hasta date)
returns table (doctor_id text, consultas integer, comisiones numeric, creditos numeric, en_revision integer,
               iva numeric, anticipos numeric)
language sql stable security definer set search_path = public as $$
  select d.id,
         count(*) filter (where estado_comision(c) = 'cobrable')::int,
         coalesce(sum(round(c.precio * d.comision, 2)) filter (where estado_comision(c) = 'cobrable' and not c.cubierta), 0),
         coalesce(sum(round(c.precio * (1 - d.comision), 2)) filter (where estado_comision(c) = 'cobrable' and c.cubierta), 0),
         count(*) filter (where estado_comision(c) = 'en_revision')::int,
         round(coalesce(sum(round(c.precio * d.comision, 2)) filter (where estado_comision(c) = 'cobrable' and not c.cubierta), 0)
               * config_num('iva_comision', 0.16), 2),
         coalesce(sum(c.anticipo) filter (where c.anticipo_estado = 'pagado'), 0)
    from doctores d
    join citas c on c.doctor_id = d.id
   where c.fecha between p_desde and p_hasta
   group by d.id
$$;
revoke all on function public.resumen_comisiones(date, date) from public, anon, authenticated;

alter table public.cobros_medicos add column if not exists iva numeric(10,2) not null default 0;
alter table public.cobros_medicos add column if not exists anticipos numeric(10,2) not null default 0;
alter table public.movimientos_medico drop constraint if exists movimientos_medico_tipo_check;
alter table public.movimientos_medico add constraint movimientos_medico_tipo_check
  check (tipo in ('comision','iva','credito_membresia','anticipo','arrastre','pago','transferencia','ajuste'));
drop index if exists public.movimientos_unicos;
create unique index if not exists movimientos_unicos on public.movimientos_medico(cobro_id, tipo, coalesce(nota, ''))
  where tipo in ('comision','iva','credito_membresia','anticipo','pago','arrastre','transferencia');

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
  insert into movimientos_medico (doctor_id, cobro_id, tipo, monto, nota)
  select o.doctor_id, c.id, 'arrastre', o.neto, o.id::text from cobros_medicos o
   where o.doctor_id = c.doctor_id and o.periodo_inicio < c.periodo_inicio and o.estado in ('arrastrado','a_favor_medico')
     and not exists (select 1 from movimientos_medico m where m.nota = o.id::text and m.tipo in ('arrastre','transferencia'));
  select coalesce(sum(monto), 0) into v_saldo from movimientos_medico where cobro_id = c.id and tipo = 'arrastre';
  if coalesce(r.comisiones, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto) values (c.doctor_id, c.id, 'comision', r.comisiones) on conflict do nothing;
  end if;
  if coalesce(r.iva, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto) values (c.doctor_id, c.id, 'iva', r.iva) on conflict do nothing;
  end if;
  if coalesce(r.creditos, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto) values (c.doctor_id, c.id, 'credito_membresia', -r.creditos) on conflict do nothing;
  end if;
  if coalesce(r.anticipos, 0) <> 0 then
    insert into movimientos_medico (doctor_id, cobro_id, tipo, monto, nota) values (c.doctor_id, c.id, 'anticipo', -r.anticipos, 'Anticipos cobrados por la plataforma') on conflict do nothing;
  end if;
  update cobros_medicos set consultas = coalesce(r.consultas, 0), comisiones = coalesce(r.comisiones, 0),
         iva = coalesce(r.iva, 0), creditos = coalesce(r.creditos, 0), anticipos = coalesce(r.anticipos, 0),
         saldo_anterior = v_saldo,
         neto = round(coalesce(r.comisiones, 0) + coalesce(r.iva, 0) - coalesce(r.creditos, 0) - coalesce(r.anticipos, 0) + v_saldo, 2),
         congelado = true, estado = 'pendiente', error = null
   where id = c.id returning * into c;
  update citas set liquidada = true
   where doctor_id = c.doctor_id and fecha between c.periodo_inicio and c.periodo_fin and estado <> 'cancelada';
  return c;
end $$;
revoke all on function public.congelar_cobro(uuid) from public, anon, authenticated;

-- Estado de cuenta del médico: paciente propio y anticipo visibles.
drop function if exists public.estado_cuenta(date, date);
create function public.estado_cuenta(p_desde date, p_hasta date)
returns table (cita_id uuid, fecha date, hora text, paciente text, servicio text, precio integer, cubierta boolean,
               estado text, comision numeric, credito numeric, origen text, anticipo integer)
language sql stable security definer set search_path = public as $$
  select c.id, c.fecha, c.hora, c.paciente, c.servicio, c.precio, c.cubierta, estado_comision(c),
         case when estado_comision(c) = 'cobrable' and not c.cubierta then round(c.precio * d.comision, 2) else 0 end,
         case when estado_comision(c) = 'cobrable' and c.cubierta then round(c.precio * (1 - d.comision), 2) else 0 end,
         c.origen, case when c.anticipo_estado = 'pagado' then c.anticipo else 0 end
    from citas c
    join medicos m on m.doctor_id = c.doctor_id and m.user_id = auth.uid()
    join doctores d on d.id = c.doctor_id
   where c.fecha between p_desde and p_hasta
   order by c.fecha, c.hora
$$;
revoke all on function public.estado_cuenta(date, date) from public, anon;
grant execute on function public.estado_cuenta(date, date) to authenticated;

-- ---------- 3. Reservar con origen y anticipo ----------
drop function if exists public.reservar_cita(text, text, date, text, text, text, text, boolean, text);
create or replace function public.reservar_cita(
  p_doctor text, p_servicio text, p_fecha date, p_hora text, p_modalidad text,
  p_paciente text, p_motivo text, p_usar_membresia boolean, p_idem text, p_origen text default 'app')
returns public.citas
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); d doctores; p perfiles; v jsonb; v_ini timestamptz; v_fin timestamptz;
  v_cubierta boolean := false; v_key text; c citas; v_origen text := 'app'; v_anticipo integer := 0; v_ant_estado text := 'no_requerido';
begin
  if v_uid is null then perform hd_error('sin_sesion', 'Inicia sesión para reservar.'); end if;
  if p_idem is null or char_length(p_idem) not between 8 and 80 then perform hd_error('solicitud_invalida', 'Falta el identificador de la solicitud.'); end if;

  select * into c from citas where user_id = v_uid and idem_key = p_idem;
  if found then return c; end if;
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

  -- Enlace del médico: 0% de comisión, salvo que este paciente ya haya llegado a ese médico por la app.
  if p_origen = 'enlace_medico' and not exists (
       select 1 from citas x where x.user_id = v_uid and x.doctor_id = d.id and x.origen = 'app' and x.estado <> 'cancelada') then
    v_origen := 'enlace_medico';
  end if;

  if bandera('anticipo_activo') and not v_cubierta then
    v_anticipo := least(config_num('anticipo_monto', 200)::int, (v->>'p')::int);
    if v_anticipo > 0 then v_ant_estado := 'pendiente'; end if;
  end if;

  v_key := d.id || '_' || p_fecha::text || '_' || replace(p_hora, ':', '');
  begin
    insert into ocupados (id, doctor_id, fecha, hora, modalidad, tipo, user_id, inicio, fin)
    values (v_key, d.id, p_fecha, p_hora, p_modalidad, 'cita', v_uid, v_ini, v_fin);
  exception when unique_violation or exclusion_violation then
    perform hd_error('horario_ocupado', 'Ese horario ya no está disponible.');
  end;

  insert into citas (user_id, doctor_id, fecha, hora, modalidad, paciente, motivo, estado, cubierta, precio,
                     servicio, servicio_id, duracion_min, inicio, fin, slot, folio, idem_key, reglas,
                     origen, anticipo, anticipo_estado)
  values (v_uid, d.id, p_fecha, p_hora, p_modalidad, p_paciente, nullif(btrim(p_motivo), ''), 'confirmada', v_cubierta,
          (v->>'p')::int, left(v->>'n', 120), v->>'id', extract(epoch from (v_fin - v_ini))::int / 60, v_ini, v_fin,
          v_key, 'HD' || upper(substr(md5(gen_random_uuid()::text), 1, 8)), p_idem,
          jsonb_build_object('comision', case when v_origen = 'enlace_medico' then 0 else d.comision end,
                             'iva', config_num('iva_comision', 0.16), 'precio', (v->>'p')::int, 'servicio', v,
                             'origen', v_origen, 'reservada', now()),
          v_origen, v_anticipo, v_ant_estado)
  returning * into c;
  update ocupados set cita_id = c.id where id = v_key;
  return c;
end $$;
revoke all on function public.reservar_cita(text, text, date, text, text, text, text, boolean, text, text) from public, anon;
grant execute on function public.reservar_cita(text, text, date, text, text, text, text, boolean, text, text) to authenticated;

-- Cancelar: si había anticipo pagado y faltan 24 h o más, queda para reembolso.
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
  update citas set estado = 'cancelada', cancelada_por = 'paciente', cancelada_en = now(),
         anticipo_estado = case when anticipo_estado = 'pagado' and inicio - now() >= interval '24 hours' then 'reembolso_pendiente'
                                when anticipo_estado = 'pendiente' then 'vencido' else anticipo_estado end
   where id = c.id returning * into c;
  delete from ocupados where id = c.slot;
  return c;
end $$;

-- El médico cancela: el anticipo pagado siempre se reembolsa.
create or replace function public.cancelar_por_medico(p_cita uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_slot text;
begin
  update citas c set estado = 'cancelada', cancelada_por = 'medico', cancelada_en = now(),
         anticipo_estado = case when c.anticipo_estado = 'pagado' then 'reembolso_pendiente'
                                when c.anticipo_estado = 'pendiente' then 'vencido' else c.anticipo_estado end
   where c.id = p_cita and c.estado = 'confirmada' and now() < c.inicio and not c.liquidada
     and exists (select 1 from medicos m where m.user_id = auth.uid() and m.doctor_id = c.doctor_id)
  returning slot into v_slot;
  if not found then perform hd_error('cita_cerrada', 'Esta cita ya no se puede cancelar.'); end if;
  delete from ocupados where id = v_slot;
end $$;

-- Anticipos no pagados en 20 minutos liberan el horario (lo llama el programador cada 10 minutos).
create or replace function public.liberar_anticipos_vencidos() returns integer
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  with v as (
    update citas set estado = 'cancelada', cancelada_por = 'sistema', cancelada_en = now(), anticipo_estado = 'vencido'
     where estado = 'confirmada' and anticipo_estado = 'pendiente' and creada < now() - interval '20 minutes'
    returning slot)
  delete from ocupados o using v where o.id = v.slot;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.liberar_anticipos_vencidos() from public, anon, authenticated;

-- El webhook marca el anticipo pagado (solo llave de servidor).
create or replace function public.anticipo_pagado(p_cita uuid, p_checkout text) returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  -- Si la cita ya se liberó por falta de pago, el dinero queda para reembolso.
  update citas set anticipo_estado = case when estado = 'cancelada' then 'reembolso_pendiente' else 'pagado' end,
         stripe_checkout = p_checkout
   where id = p_cita and anticipo_estado in ('pendiente','vencido')
$$;
revoke all on function public.anticipo_pagado(uuid, text) from public, anon, authenticated;

-- ---------- 4. Médicos que recomiendo ----------
alter table public.doctores add column if not exists recomendados text[] not null default '{}';
alter table public.doctores drop constraint if exists doctores_recomendados_check;
alter table public.doctores add constraint doctores_recomendados_check check (cardinality(recomendados) <= 12);
grant select (recomendados) on public.doctores to anon, authenticated;
grant insert (recomendados), update (recomendados) on public.doctores to authenticated;

create or replace function public.limpiar_recomendados() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Solo colegas que existen y están verificados; sin repetidos y sin uno mismo.
  new.recomendados := coalesce((select array_agg(distinct r) from unnest(new.recomendados) r
                                 where r <> new.id and exists (select 1 from doctores x where x.id = r and x.verificado)), '{}');
  return new;
end $$;
drop trigger if exists doctores_recomendados on public.doctores;
create trigger doctores_recomendados before insert or update of recomendados on public.doctores
  for each row execute function public.limpiar_recomendados();

-- ---------- 7. Lista de espera de la membresía (prueba de precio $149 / $199) ----------
-- Mientras la venta está apagada, el paciente ve el precio de su grupo (A = $149, B = $199) y puede
-- pedir que le avisemos. Con eso se compara cuántos se apuntan en cada precio antes de cobrar.
create table if not exists public.lista_espera (
  user_id  uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  plan     text not null check (plan in ('individual','familiar')),
  precio   int  not null check (precio in (149,199,399)),
  grupo    text not null check (grupo in ('A','B')),
  alcaldia text check (alcaldia is null or char_length(alcaldia) <= 60),
  creado   timestamptz not null default now()
);
alter table public.lista_espera enable row level security;
revoke all on public.lista_espera from anon, authenticated;
grant select, insert, delete on public.lista_espera to authenticated;
grant update (plan, precio, grupo, alcaldia) on public.lista_espera to authenticated;
drop policy if exists "lista espera: la propia" on public.lista_espera;
create policy "lista espera: la propia" on public.lista_espera for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Resultado de la prueba de precio (solo SQL Editor).
create or replace function public.prueba_precio()
returns table (grupo text, precio int, apuntados bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select grupo, precio, count(*) from lista_espera where plan = 'individual' group by 1, 2 order by 1
$$;
revoke all on function public.prueba_precio() from public, anon, authenticated;
