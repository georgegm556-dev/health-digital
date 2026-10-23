// Health Digital · Función "pagos"
// Crea el pago de la membresía en Stripe, cambia de plan, abre el portal del cliente
// y cancela la suscripción. La llama la app con la sesión del paciente.
//
// Secretos necesarios (Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY   clave secreta de Stripe (sk_test_... o sk_live_...)
//   PRICE_INDIVIDUAL    id del precio del Plan Individual (price_...)
//   PRICE_FAMILIAR      id del precio del Plan Familiar (price_...)
//   SITE_URL            https://georgegm556-dev.github.io/health-digital/
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase automáticamente.

import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.99.3";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2025-02-24.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});
const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);
const PRECIOS: Record<string, string | undefined> = {
  individual: Deno.env.get("PRICE_INDIVIDUAL"),
  familiar: Deno.env.get("PRICE_FAMILIAR"),
};
const SITE = Deno.env.get("SITE_URL") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  // 1. Quién es el paciente: se verifica su sesión con Supabase.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !auth?.user) return json({ error: "Inicia sesión para continuar." }, 401);
  const user = auth.user;

  let body: { accion?: string; plan?: string } = {};
  try { body = await req.json(); } catch { /* cuerpo vacío */ }
  const accion = body.accion ?? "";

  const { data: perfil } = await admin
    .from("perfiles")
    .select("stripe_customer_id, stripe_subscription_id, plan, plan_estado")
    .eq("id", user.id)
    .maybeSingle();
  if (!perfil) return json({ error: "Completa tu perfil antes de activar una membresía." }, 400);

  try {
    // 2. Pagar una membresía nueva: página de pago segura de Stripe.
    if (accion === "checkout") {
      const price = PRECIOS[body.plan ?? ""];
      if (!price) return json({ error: "Plan no válido." }, 400);
      const activa = perfil.stripe_subscription_id && ["active", "trialing", "past_due"].includes(perfil.plan_estado ?? "");
      if (activa) return json({ error: "Ya tienes una membresía activa. Usa Cambiar de plan." }, 409);

      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        line_items: [{ price, quantity: 1 }],
        ...(perfil.stripe_customer_id ? { customer: perfil.stripe_customer_id } : { customer_email: user.email ?? undefined }),
        client_reference_id: user.id,
        metadata: { user_id: user.id, plan: body.plan! },
        subscription_data: { metadata: { user_id: user.id, plan: body.plan! } },
        locale: "es",
        allow_promotion_codes: true,
        success_url: `${SITE}?pago=ok`,
        cancel_url: `${SITE}?pago=cancelado`,
      });
      return json({ url: session.url });
    }

    // 3. Cambiar de plan con prorrateo (se cobra o acredita la diferencia).
    if (accion === "cambiar") {
      const price = PRECIOS[body.plan ?? ""];
      if (!price) return json({ error: "Plan no válido." }, 400);
      if (!perfil.stripe_subscription_id) return json({ error: "No tienes una membresía activa." }, 400);
      const sub = await stripe.subscriptions.retrieve(perfil.stripe_subscription_id);
      await stripe.subscriptions.update(sub.id, {
        items: [{ id: sub.items.data[0].id, price }],
        proration_behavior: "create_prorations",
        metadata: { user_id: user.id, plan: body.plan! },
      });
      return json({ ok: true });
    }

    // 4. Portal de Stripe: cambiar tarjeta, ver recibos o cancelar.
    if (accion === "portal") {
      if (!perfil.stripe_customer_id) return json({ error: "Aún no tienes pagos registrados." }, 400);
      const portal = await stripe.billingPortal.sessions.create({
        customer: perfil.stripe_customer_id,
        return_url: SITE,
        locale: "es",
      });
      return json({ url: portal.url });
    }

    // 5. Cancelar de inmediato (se usa al eliminar la cuenta, para no seguir cobrando).
    if (accion === "cancelar") {
      if (perfil.stripe_subscription_id) {
        try { await stripe.subscriptions.cancel(perfil.stripe_subscription_id); } catch { /* ya cancelada */ }
      }
      await admin.from("perfiles")
        .update({ plan: null, plan_estado: "canceled", miembros: [] })
        .eq("id", user.id);
      return json({ ok: true });
    }

    return json({ error: "Acción no válida." }, 400);
  } catch (e) {
    console.error("pagos", accion, e);
    return json({ error: "No se pudo procesar el pago. Inténtalo de nuevo." }, 500);
  }
});
