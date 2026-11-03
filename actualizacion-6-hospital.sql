-- =====================================================================
-- Health Digital · Actualización 6: hospital y consultorio de los médicos
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Requiere haber corrido antes la actualización 4. Se puede correr más de una vez.
-- =====================================================================

alter table public.doctores add column if not exists hospital text
  check (hospital is null or char_length(hospital) between 2 and 120);
alter table public.doctores add column if not exists consultorio text
  check (consultorio is null or char_length(consultorio) between 1 and 120);

grant select (hospital, consultorio) on public.doctores to anon, authenticated;
grant insert (hospital, consultorio) on public.doctores to authenticated;
grant update (hospital, consultorio) on public.doctores to authenticated;
