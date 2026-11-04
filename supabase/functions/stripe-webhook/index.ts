// Health Digital · Función "stripe-webhook"
// Stripe avisa aquí cada vez que una suscripción se crea, se renueva, cambia, falla o se cancela.
// Esta función es la ÚNICA que activa o desactiva membresías en la base de datos.
// También registra la tarjeta de los médicos y el resultado de los cobros de comisión.
//
// Reglas (actualización 7):
//   · Firma de Stripe obligatoria.
//   · Cada event.id se registra en stripe_eventos y se procesa una sola vez; si falla, Stripe reintenta.
//   · Los eventos pueden llegar repetidos o en desorden: siempre se consulta el estado ACTUAL del
//     objeto en Stripe (suscripción o pago) en lugar de confiar en el contenido del evento.
//   · Todo error de base de datos se detecta; el evento no se marca procesado si algo falló.
//
// Secretos necesarios (Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, PRICE_INDIVIDUAL, PRICE_FAMILIAR

import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.99.3";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2025-02-24.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);
const PLAN_POR_PRECIO: Record<string, string> = {
  [Deno.env.get("PRICE_INDIVIDUAL") ?? "_"]: "individual",
  [Deno.env.get("PRICE_FAMILIAR") ?? "_"]: "familiar",
};
const CON_PLAN = ["active", "trialing", "past_due"]; // past_due: Stripe reintenta el cobro, aún sin cortar

const ok = (d: { error: unknown }, donde: string) => { if (d.error) throw new Error(`${donde}: ${(d.error as { message?: string }).message}`); };

async function sincronizar(subId: string, userIdRespaldo?: string | null) {
  const sub = await stripe.subscriptions.retrieve(subId);          // estado actual, no el del evento
  const userId = sub.metadata?.user_id || userIdRespaldo;
  if (!userId) { console.warn("Suscripción sin user_id", sub.id); return; }
  const priceId = sub.items.data[0]?.price?.id ?? "";
  const plan = PLAN_POR_PRECIO[priceId] ?? null;
  const conPlan = CON_PLAN.includes(sub.status) && !!plan;

  const r = await admin.from("perfiles").select("socio, stripe_subscription_id").eq("id", userId).maybeSingle();
  ok(r, "leer perfil");
  if (!r.data) { console.warn("Perfil no encontrado", userId); return; }
  // Una suscripción vieja (ya reemplazada) no puede pisar a la actual.
  if (r.data.stripe_subscription_id && r.data.stripe_subscription_id !== sub.id && !conPlan) return;

  const cambios: Record<string, unknown> = {
    plan: conPlan ? plan : null,
    plan_estado: sub.status,
    renovacion: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
    stripe_customer_id: typeof sub.customer === "string" ? sub.customer : sub.customer.id,
    stripe_subscription_id: sub.id,
  };
  if (conPlan && !r.data.socio) cambios.socio = "HD-" + crypto.getRandomValues(new Uint32Array(1))[0].toString().slice(0, 6).padStart(6, "0");
  if (!conPlan || plan === "individual") cambios.miembros = [];
  ok(await admin.from("perfiles").update(cambios).eq("id", userId), "actualizar perfil");
}

async function resultadoCobro(piId: string) {
  const pi = await stripe.paymentIntents.retrieve(piId);           // estado actual
  const cobro = pi.metadata?.cobro_id;
  if (!cobro) return;
  const estado = pi.status === "succeeded" ? "pagado"
    : pi.status === "processing" ? "procesando"
    : ["requires_action", "requires_confirmation"].includes(pi.status) ? "requiere_accion" : "fallido";
  const { error } = await admin.rpc("cerrar_cobro", {
    p_cobro: cobro, p_estado: estado, p_pi: pi.id,
    p_error: estado === "pagado" ? null : (pi.last_payment_error?.message ?? pi.status),
  });
  if (error) throw new Error(`cerrar_cobro: ${error.message}`);
}

async function procesar(evento: Stripe.Event) {
  switch (evento.type) {
    case "checkout.session.completed": {
      const s = evento.data.object as Stripe.Checkout.Session;
      if (s.mode === "setup" && s.metadata?.tipo === "medico" && s.setup_intent) {
        const si = await stripe.setupIntents.retrieve(String(s.setup_intent));
        if (si.status !== "succeeded") return;
        const pm = typeof si.payment_method === "string" ? si.payment_method : si.payment_method?.id;
        const customer = typeof s.customer === "string" ? s.customer : s.customer?.id;
        if (pm && customer) {
          await stripe.customers.update(customer, { invoice_settings: { default_payment_method: pm } });
          ok(await admin.from("doctores")
            .update({ tarjeta_ok: true, stripe_payment_method: pm, stripe_customer_id: customer })
            .eq("id", s.metadata.doctor_id).eq("stripe_customer_id", customer), "registrar tarjeta");
          // Si estaba pausado por rechazos, se reactiva al tener tarjeta nueva y se reintenta en el próximo cierre.
          ok(await admin.from("doctores").update({ suspendido: false }).eq("id", s.metadata.doctor_id), "reactivar médico");
        }
        return;
      }
      if (s.mode === "subscription" && s.subscription) await sincronizar(String(s.subscription), s.client_reference_id);
      return;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      await sincronizar((evento.data.object as Stripe.Subscription).id);
      return;
    case "invoice.paid":
    case "invoice.payment_failed": {
      const inv = evento.data.object as Stripe.Invoice;
      if (inv.subscription) await sincronizar(String(inv.subscription));
      return;
    }
    case "payment_intent.succeeded":
    case "payment_intent.payment_failed":
    case "payment_intent.processing":
    case "payment_intent.requires_action":
      await resultadoCobro((evento.data.object as Stripe.PaymentIntent).id);
      return;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Método no permitido", { status: 405 });
  const firma = req.headers.get("Stripe-Signature");
  const cuerpo = await req.text();
  let evento: Stripe.Event;
  try {
    evento = await stripe.webhooks.constructEventAsync(
      cuerpo, firma ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "", undefined, cryptoProvider,
    );
  } catch (e) {
    console.error("Firma inválida", e);
    return new Response("Firma inválida", { status: 400 });
  }

  // Bandeja: un event.id se procesa una sola vez.
  const t = await admin.rpc("evento_stripe_tomar", { p_id: evento.id, p_tipo: evento.type });
  if (t.error) { console.error("bandeja", t.error); return new Response("Error", { status: 500 }); }
  if (t.data === "procesado") return new Response(JSON.stringify({ recibido: true, repetido: true }), { headers: { "Content-Type": "application/json" } });
  if (t.data === "en_proceso") return new Response("En proceso", { status: 409 }); // Stripe reintenta más tarde

  try {
    await procesar(evento);
    const c = await admin.rpc("evento_stripe_cerrar", { p_id: evento.id, p_ok: true, p_error: null });
    if (c.error) throw new Error(c.error.message);
    return new Response(JSON.stringify({ recibido: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("Error al procesar", evento.type, evento.id, e);
    await admin.rpc("evento_stripe_cerrar", { p_id: evento.id, p_ok: false, p_error: String((e as Error).message ?? e).slice(0, 500) });
    return new Response("Error", { status: 500 }); // Stripe reintentará
  }
});
