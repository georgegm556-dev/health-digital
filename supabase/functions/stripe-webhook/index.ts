// Health Digital · Función "stripe-webhook"
// Stripe avisa aquí cada vez que una suscripción se crea, se renueva, cambia, falla o se cancela.
// Esta función es la ÚNICA que activa o desactiva membresías en la base de datos.
// También registra la tarjeta de los médicos y el resultado de los cobros de comisión.
//
// Secretos necesarios (Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY       clave secreta de Stripe
//   STRIPE_WEBHOOK_SECRET   secreto del webhook (whsec_...)
//   PRICE_INDIVIDUAL        id del precio del Plan Individual
//   PRICE_FAMILIAR          id del precio del Plan Familiar

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
const CON_PLAN = ["active", "trialing", "past_due"]; // past_due: se reintenta el cobro, aún sin cortar

async function sincronizar(sub: Stripe.Subscription) {
  const userId = sub.metadata?.user_id;
  if (!userId) { console.warn("Suscripción sin user_id", sub.id); return; }
  const priceId = sub.items.data[0]?.price?.id ?? "";
  const plan = PLAN_POR_PRECIO[priceId] ?? sub.metadata?.plan ?? null;
  const conPlan = CON_PLAN.includes(sub.status);

  const { data: actual } = await admin.from("perfiles").select("socio, miembros").eq("id", userId).maybeSingle();
  if (!actual) { console.warn("Perfil no encontrado", userId); return; }

  const cambios: Record<string, unknown> = {
    plan: conPlan ? plan : null,
    plan_estado: sub.status,
    renovacion: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
    stripe_customer_id: typeof sub.customer === "string" ? sub.customer : sub.customer.id,
    stripe_subscription_id: sub.id,
  };
  if (conPlan && !actual.socio) cambios.socio = "HD-" + Math.floor(100000 + Math.random() * 900000);
  if (!conPlan || plan === "individual") cambios.miembros = [];

  const { error } = await admin.from("perfiles").update(cambios).eq("id", userId);
  if (error) throw error;
}

Deno.serve(async (req) => {
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

  try {
    switch (evento.type) {
      case "checkout.session.completed": {
        const s = evento.data.object as Stripe.Checkout.Session;
        // Médico registró su tarjeta para la comisión mensual
        if (s.mode === "setup" && s.metadata?.tipo === "medico" && s.setup_intent) {
          const si = await stripe.setupIntents.retrieve(String(s.setup_intent));
          const pm = typeof si.payment_method === "string" ? si.payment_method : si.payment_method?.id;
          const customer = typeof s.customer === "string" ? s.customer : s.customer?.id;
          if (pm && customer) {
            await stripe.customers.update(customer, { invoice_settings: { default_payment_method: pm } });
            const { error } = await admin.from("doctores")
              .update({ tarjeta_ok: true, suspendido: false, stripe_payment_method: pm, stripe_customer_id: customer })
              .eq("id", s.metadata.doctor_id);
            if (error) throw error;
          }
          break;
        }
        if (s.mode === "subscription" && s.subscription) {
          const sub = await stripe.subscriptions.retrieve(String(s.subscription));
          if (!sub.metadata?.user_id && s.client_reference_id) {
            sub.metadata = { ...sub.metadata, user_id: s.client_reference_id };
          }
          await sincronizar(sub);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await sincronizar(evento.data.object as Stripe.Subscription);
        break;
      // Cobro mensual de comisiones a médicos
      case "payment_intent.succeeded":
      case "payment_intent.payment_failed": {
        const pi = evento.data.object as Stripe.PaymentIntent;
        const cobro = pi.metadata?.cobro_id;
        if (cobro) {
          const ok = evento.type === "payment_intent.succeeded";
          await admin.from("cobros_medicos")
            .update({ estado: ok ? "pagado" : "fallido", stripe_payment_intent: pi.id,
                      error: ok ? null : (pi.last_payment_error?.message ?? "Pago rechazado") })
            .eq("id", cobro);
          if (!ok && pi.metadata?.doctor_id) {
            await admin.from("doctores").update({ suspendido: true }).eq("id", pi.metadata.doctor_id);
          }
        }
        break;
      }
      case "invoice.paid":
      case "invoice.payment_failed": {
        const inv = evento.data.object as Stripe.Invoice;
        if (inv.subscription) await sincronizar(await stripe.subscriptions.retrieve(String(inv.subscription)));
        break;
      }
    }
    return new Response(JSON.stringify({ recibido: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("Error al procesar", evento.type, e);
    return new Response("Error", { status: 500 }); // Stripe reintentará
  }
});
