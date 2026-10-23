-- =====================================================================
-- Health Digital · Actualización 5: foto de perfil, página web y redes de los médicos
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Requiere haber corrido antes la actualización 4. Se puede correr más de una vez.
-- =====================================================================

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
