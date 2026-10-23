-- =====================================================================
-- Health Digital · Actualización 2: servicios, favoritos y opiniones por categoría
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Se puede correr más de una vez sin problema.
-- =====================================================================

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
