// Health Digital · Función "cobrar-comisiones"
// Cobra a cada médico el 10% de las consultas atendidas del periodo (por defecto, el mes anterior)
// en la tarjeta que registró. Las consultas incluidas en membresía se le acreditan (90%).
// La ejecuta un programador automático cada mes (ver PAGOS.md) o Health Digital a mano.
//
// Seguridad: solo responde si la petición trae el encabezado x-cron-secret correcto.
// Secretos necesarios: STRIPE_SECRET_KEY, CRON_SECRET (una contraseña larga que tú inventas).

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
const MINIMO_MXN = 10; // Stripe no permite cobros menores a $10 MXN; el saldo pasa al siguiente mes.

const ymd = (d: Date) => d.toISOString().slice(0, 10);
function mesAnterior() {
  // Fecha de hoy en la Ciudad de México
  const hoy = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Mexico_City" }));
  const inicio = new Date(Date.UTC(hoy.getFullYear(), hoy.getMonth() - 1, 1));
  const fin = new Date(Date.UTC(hoy.getFullYear(), hoy.getMonth(), 0));
  return { desde: ymd(inicio), hasta: ymd(fin) };
}
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const secreto = Deno.env.get("CRON_SECRET");
  if (!secreto || req.headers.get("x-cron-secret") !== secreto) return json({ error: "No autorizado" }, 401);

  let body: { desde?: string; hasta?: string } = {};
  try { body = await req.json(); } catch { /* sin cuerpo: mes anterior */ }
  const { desde, hasta } = body.desde && body.hasta ? { desde: body.desde, hasta: body.hasta } : mesAnterior();

  const { data: filas, error } = await admin.rpc("resumen_comisiones", { p_desde: desde, p_hasta: hasta });
  if (error) return json({ error: error.message }, 500);

  const resultado: unknown[] = [];
  for (const f of filas ?? []) {
    const comisiones = Number(f.comisiones), creditos = Number(f.creditos);
    const neto = Math.round((comisiones - creditos) * 100) / 100;

    // Registro del periodo (uno por médico y mes). Si ya se pagó, no se vuelve a cobrar.
    const { data: previo } = await admin.from("cobros_medicos")
      .select("id, estado, intentos").eq("doctor_id", f.doctor_id).eq("periodo_inicio", desde).maybeSingle();
    if (previo && ["pagado", "a_favor_medico", "sin_cargo"].includes(previo.estado)) {
      resultado.push({ doctor: f.doctor_id, estado: previo.estado, nota: "ya procesado" });
      continue;
    }
    const base = {
      doctor_id: f.doctor_id, periodo_inicio: desde, periodo_fin: hasta,
      consultas: f.consultas, comisiones, creditos, neto,
    };
    const { data: cobro, error: e1 } = await admin.from("cobros_medicos")
      .upsert({ ...base, estado: "pendiente", intentos: (previo?.intentos ?? 0) + 1 }, { onConflict: "doctor_id,periodo_inicio" })
      .select("id, intentos").single();
    if (e1 || !cobro) { resultado.push({ doctor: f.doctor_id, error: e1?.message }); continue; }

    if (neto <= 0 || neto < MINIMO_MXN) {
      const estado = neto < 0 ? "a_favor_medico" : "sin_cargo";
      await admin.from("cobros_medicos").update({
        estado, error: neto > 0 ? `Monto menor al mínimo de $${MINIMO_MXN}` : null,
      }).eq("id", cobro.id);
      resultado.push({ doctor: f.doctor_id, neto, estado });
      continue;
    }

    const { data: doc } = await admin.from("doctores")
      .select("tarjeta_ok, stripe_customer_id, stripe_payment_method").eq("id", f.doctor_id).single();
    if (!doc?.tarjeta_ok || !doc.stripe_customer_id || !doc.stripe_payment_method) {
      await admin.from("cobros_medicos").update({ estado: "fallido", error: "Sin tarjeta registrada" }).eq("id", cobro.id);
      await admin.from("doctores").update({ suspendido: true }).eq("id", f.doctor_id);
      resultado.push({ doctor: f.doctor_id, neto, estado: "fallido", error: "sin tarjeta" });
      continue;
    }

    try {
      const pi = await stripe.paymentIntents.create({
        amount: Math.round(neto * 100),
        currency: "mxn",
        customer: doc.stripe_customer_id,
        payment_method: doc.stripe_payment_method,
        off_session: true,
        confirm: true,
        description: `Comisión Health Digital · consultas del ${desde} al ${hasta}`,
        metadata: { cobro_id: cobro.id, doctor_id: f.doctor_id, periodo: desde },
      }, { idempotencyKey: `cobro-${cobro.id}-${cobro.intentos}` });
      const pagado = pi.status === "succeeded";
      await admin.from("cobros_medicos").update({
        estado: pagado ? "pagado" : "pendiente", stripe_payment_intent: pi.id, error: null,
      }).eq("id", cobro.id);
      resultado.push({ doctor: f.doctor_id, neto, estado: pagado ? "pagado" : pi.status });
    } catch (e) {
      const msg = (e as { message?: string }).message ?? "Pago rechazado";
      await admin.from("cobros_medicos").update({ estado: "fallido", error: msg }).eq("id", cobro.id);
      await admin.from("doctores").update({ suspendido: true }).eq("id", f.doctor_id);
      resultado.push({ doctor: f.doctor_id, neto, estado: "fallido", error: msg });
    }
  }
  return json({ periodo: { desde, hasta }, medicos: resultado.length, resultado });
});
