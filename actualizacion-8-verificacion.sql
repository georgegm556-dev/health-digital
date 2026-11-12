-- =====================================================================
-- Health Digital · Actualización 8: verificación de médicos por pasos
--
-- Qué cambia:
--   1. Cada revisión queda registrada: paso, resultado, quién revisó y con qué evidencia.
--   2. "verificado" se enciende solo cuando la cédula (SEP) Y la identidad están aprobadas.
--   3. Insignias públicas opcionales: especialidad verificada, certificado por su consejo,
--      consultorio verificado. Solo Health Digital las puede encender.
--   4. Carpeta PRIVADA "documentos-medicos": el médico sube su constancia, cédula de
--      especialidad o certificado; solo él y Health Digital los ven. Nunca es pública.
--   5. Si el médico cambia nombre, cédula o especialidad, se apagan las insignias afectadas.
--
-- Requiere la actualización 7. Se puede correr más de una vez. No borra datos.
-- =====================================================================

-- ---------- 1. Insignias públicas y mensaje al médico ----------
alter table public.doctores add column if not exists esp_verificada         boolean not null default false;
alter table public.doctores add column if not exists consejo_verificado     boolean not null default false;
alter table public.doctores add column if not exists consultorio_verificado boolean not null default false;
alter table public.doctores add column if not exists verificacion_nota      text check (verificacion_nota is null or char_length(verificacion_nota) <= 300);
-- El público ve las insignias; la nota solo la ve el médico (por mi_doctor).
grant select (esp_verificada, consejo_verificado, consultorio_verificado) on public.doctores to anon, authenticated;
-- Nadie las escribe desde el navegador (no hay permiso de insert/update en estas columnas).

-- ---------- 2. Registro de revisiones ----------
create table if not exists public.verificaciones_medico (
  id         uuid primary key default gen_random_uuid(),
  doctor_id  text not null references public.doctores(id) on delete cascade,
  paso       text not null check (paso in ('cedula_sep','identidad','especialidad','consejo','consultorio')),
  resultado  text not null check (resultado in ('aprobado','rechazado')),
  revisor    text not null check (char_length(revisor) between 2 and 120),
  evidencia  text not null check (char_length(evidencia) between 5 and 1000),
  creado     timestamptz not null default now()
);
create index if not exists verificaciones_doctor_idx on public.verificaciones_medico(doctor_id, paso, creado desc);
alter table public.verificaciones_medico enable row level security;
revoke all on public.verificaciones_medico from anon, authenticated;
grant select (id, doctor_id, paso, resultado, creado) on public.verificaciones_medico to authenticated;  -- sin revisor ni evidencia
drop policy if exists "verificaciones: el médico ve las suyas" on public.verificaciones_medico;
create policy "verificaciones: el médico ve las suyas" on public.verificaciones_medico for select to authenticated
  using (exists (select 1 from public.medicos m where m.doctor_id = verificaciones_medico.doctor_id and m.user_id = auth.uid()));

-- Último resultado de un paso.
create or replace function public.paso_aprobado(p_doctor text, p_paso text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select resultado = 'aprobado' from verificaciones_medico
                    where doctor_id = p_doctor and paso = p_paso order by creado desc limit 1), false)
$$;
revoke all on function public.paso_aprobado(text, text) from public, anon, authenticated;

-- ---------- 3. Función de administración (solo SQL Editor / llave de servidor) ----------
create or replace function public.registrar_verificacion(
  p_cedula text, p_paso text, p_resultado text, p_revisor text, p_evidencia text, p_nota text default null)
returns table (medico text, paso text, resultado text, verificado boolean, especialidad boolean, consejo boolean, consultorio boolean)
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare d doctores;
begin
  select * into d from doctores where cedula = p_cedula;
  if not found then raise exception 'No hay un médico con la cédula %', p_cedula; end if;
  insert into verificaciones_medico (doctor_id, paso, resultado, revisor, evidencia)
  values (d.id, p_paso, p_resultado, p_revisor, p_evidencia);

  update doctores x set
    verificado             = paso_aprobado(d.id, 'cedula_sep') and paso_aprobado(d.id, 'identidad'),
    esp_verificada         = paso_aprobado(d.id, 'especialidad'),
    consejo_verificado     = paso_aprobado(d.id, 'consejo'),
    consultorio_verificado = paso_aprobado(d.id, 'consultorio'),
    verificacion_nota      = coalesce(p_nota, case when p_resultado = 'rechazado' then 'Revisa tu perfil: hay un dato que no pudimos confirmar.' end)
  where x.id = d.id
  returning * into d;

  return query select d.nombre, p_paso, p_resultado, d.verificado, d.esp_verificada, d.consejo_verificado, d.consultorio_verificado;
end $$;
revoke all on function public.registrar_verificacion(text, text, text, text, text, text) from public, anon, authenticated;

-- Médicos esperando revisión (para quien verifica).
create or replace function public.medicos_por_verificar()
returns table (nombre text, especialidad text, cedula text, telefono text, email text, creado timestamptz,
               cedula_sep text, identidad text, documentos bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select d.nombre, d.especialidad, d.cedula, d.telefono, u.email::text, d.creado,
         coalesce((select v.resultado from verificaciones_medico v where v.doctor_id = d.id and v.paso = 'cedula_sep' order by v.creado desc limit 1), 'pendiente'),
         coalesce((select v.resultado from verificaciones_medico v where v.doctor_id = d.id and v.paso = 'identidad' order by v.creado desc limit 1), 'pendiente'),
         (select count(*) from storage.objects o where o.bucket_id = 'documentos-medicos' and (storage.foldername(o.name))[1] = d.user_id::text)
    from doctores d left join auth.users u on u.id = d.user_id
   where not d.verificado
   order by d.creado
$$;
revoke all on function public.medicos_por_verificar() from public, anon, authenticated;

-- ---------- 4. Cambios materiales apagan insignias ----------
create or replace function public.doctores_revision() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null then
    if new.especialidad is distinct from old.especialidad then
      new.verificado := false; new.esp_verificada := false; new.consejo_verificado := false;
      new.verificacion_nota := 'Cambiaste tu especialidad: la volvemos a revisar.';
    end if;
    if new.cedula is distinct from old.cedula or new.nombre is distinct from old.nombre then
      new.verificado := false;
      new.verificacion_nota := 'Cambiaste tu nombre o cédula: lo volvemos a revisar.';
    end if;
    if new.direccion is distinct from old.direccion or new.consultorio is distinct from old.consultorio then
      new.consultorio_verificado := false;
    end if;
  end if;
  return new;
end $$;

-- ---------- 5. Carpeta privada de documentos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos-medicos', 'documentos-medicos', false, 5242880, array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp'];

drop policy if exists "documentos medicos: subir los propios"  on storage.objects;
drop policy if exists "documentos medicos: ver los propios"    on storage.objects;
drop policy if exists "documentos medicos: borrar los propios" on storage.objects;
create policy "documentos medicos: subir los propios" on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos-medicos' and (storage.foldername(name))[1] = auth.uid()::text
              and exists (select 1 from public.medicos m where m.user_id = auth.uid()));
create policy "documentos medicos: ver los propios" on storage.objects for select to authenticated
  using (bucket_id = 'documentos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "documentos medicos: borrar los propios" on storage.objects for delete to authenticated
  using (bucket_id = 'documentos-medicos' and (storage.foldername(name))[1] = auth.uid()::text);
-- Sin política de actualizar: un documento enviado no se reemplaza en silencio; se sube otro.

-- ---------- 6. Médicos ya verificados antes de esta actualización ----------
-- Conservan su verificación: se registra como aprobada por "migración" para que el cálculo nuevo no la apague.
insert into public.verificaciones_medico (doctor_id, paso, resultado, revisor, evidencia)
select d.id, p.paso, 'aprobado', 'migración', 'Verificado antes de la actualización 8'
  from public.doctores d cross join (values ('cedula_sep'), ('identidad')) p(paso)
 where d.verificado
   and not exists (select 1 from public.verificaciones_medico v where v.doctor_id = d.id and v.paso = p.paso);
