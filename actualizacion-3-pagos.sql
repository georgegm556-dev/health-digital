-- =====================================================================
-- Health Digital · Actualización 3: pagos de membresías con Stripe
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Córrelo DESPUÉS de publicar las funciones "pagos" y "stripe-webhook".
-- Se puede correr más de una vez.
-- =====================================================================

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
