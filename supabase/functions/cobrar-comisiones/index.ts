// Health Digital · Función "cobrar-comisiones"
// Cobra a cada médico el 10% de las consultas atendidas del periodo (por defecto, el mes anterior)
// en la tarjeta que registró. Las consultas incluidas en membresía se le acreditan (90%).
// La ejecuta un programador automático el día 10 de cada mes (ver PAGOS.md), cuando ya cerraron
// las ventanas de asistencia (72 h del médico y 7 días del paciente).
//
// Reglas de seguridad del cobro (actualización 7):
//   · Un cobro por médico y periodo, con bloqueo: dos ejecuciones a la vez no cobran dos veces.
//   · Los montos se congelan una sola vez y quedan en el ledger (movimientos_medico).
//   · La clave de idempotencia de Stripe es fija por cobro; solo cambia tras un rechazo definitivo.
//   · Antes de crear otro pago, se consulta el PaymentIntent anterior en Stripe.
//   · Si hay consultas en revisión, no se cobra hasta resolverlas.
//   · Saldos menores al mínimo se arrastran; saldos a favor quedan para transferencia manual.
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
const MINIMO_MXN = 10; // Stripe no permite cobros menores a $10 MXN; el saldo pasa al siguiente periodo.
const ABIERTOS = ["pendiente", "procesando", "requiere_accion", "fallido", "en_revision"];

type Cobro = {
  id: string; doctor_id: string; periodo_inicio: string; periodo_fin: string; estado: string;
  neto: number | string; congelado: boolean; idem_key: string; reintento_pago: number;
  stripe_payment_intent: string | null;
};

const ymd = (d: Date) => d.toISOString().slice(0, 10);
function mesAnterior() {
  const hoy = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Mexico_City" }));
  const inicio = new Date(Date.UTC(hoy.getFullYear(), hoy.getMonth() - 1, 1));
  const fin = new Date(Date.UTC(hoy.getFullYear(), hoy.getMonth(), 0));
  return { desde: ymd(inicio), hasta: ymd(fin) };
}
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function rpc<T>(nombre: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(nombre, args);
  if (error) throw new Error(`${nombre}: ${error.message}`);
  return data as T;
}
const cerrar = (id: string, estado: string, pi: string | null = null, err: string | null = null) =>
  rpc<Cobro>("cerrar_cobro", { p_cobro: id, p_estado: estado, p_pi: pi, p_error: err });

function estadoDePI(pi: Stripe.PaymentIntent): string {
  if (pi.status === "succeeded") return "pagado";
  if (pi.status === "processing") return "procesando";
  if (pi.status === "requires_action" || pi.status === "requires_confirmation") return "requiere_accion";
  return "fallido"; // requires_payment_method, canceled
}

async function procesar(doctorId: string, desde: string, hasta: string) {
  const t = await rpc<{ tomado: boolean; motivo?: string; cobro: Cobro }>("tomar_cobro", { p_doctor: doctorId, p_desde: desde, p_hasta: hasta });
  if (!t.tomado) return { doctor: doctorId, periodo: desde, estado: t.cobro.estado, nota: t.motivo };
  let c = t.cobro;
  try {
    // 1. ¿Ya hubo un intento? Primero se reconcilia con Stripe; nunca se crea un pago a ciegas.
    if (c.stripe_payment_intent) {
      const pi = await stripe.paymentIntents.retrieve(c.stripe_payment_intent);
      const est = estadoDePI(pi);
      if (est !== "fallido" || c.estado !== "fallido") {
        // pagado, en proceso, requiere acción, o un rechazo que aún no se había registrado
        c = await cerrar(c.id, est, pi.id, est === "fallido" ? (pi.last_payment_error?.message ?? "Pago rechazado") : null);
        if (est !== "fallido") return { doctor: doctorId, periodo: desde, estado: c.estado, pi: pi.id };
      }
      // rechazo definitivo ya registrado: se intenta de nuevo abajo con una clave nueva
    }

    // 2. Montos congelados una sola vez (con saldo anterior y revisión de disputas).
    if (!c.congelado) c = await rpc<Cobro>("congelar_cobro", { p_cobro: c.id });
    if (c.estado === "en_revision") { await cerrar(c.id, "en_revision", null, "Consultas en revisión"); return { doctor: doctorId, periodo: desde, estado: "en_revision" }; }

    const neto = Number(c.neto);
    if (neto < 0) { await cerrar(c.id, "a_favor_medico"); return { doctor: doctorId, periodo: desde, neto, estado: "a_favor_medico" }; }
    if (neto === 0) { await cerrar(c.id, "sin_cargo"); return { doctor: doctorId, periodo: desde, neto, estado: "sin_cargo" }; }
    if (neto < MINIMO_MXN) { await cerrar(c.id, "arrastrado", null, `Menor al mínimo de $${MINIMO_MXN}: pasa al siguiente periodo`); return { doctor: doctorId, periodo: desde, neto, estado: "arrastrado" }; }

    const { data: doc, error: eDoc } = await admin.from("doctores")
      .select("tarjeta_ok, stripe_customer_id, stripe_payment_method").eq("id", doctorId).single();
    if (eDoc) throw new Error(`doctor: ${eDoc.message}`);
    if (!doc?.tarjeta_ok || !doc.stripe_customer_id || !doc.stripe_payment_method) {
      await cerrar(c.id, "fallido", null, "Sin tarjeta registrada");
      return { doctor: doctorId, periodo: desde, neto, estado: "fallido", error: "sin tarjeta" };
    }

    // 3. Si una ejecución anterior se cortó después de crear el pago (sin guardar su id), la clave de
    //    idempotencia de Stripe solo dura 24 h: se busca en Stripe cualquier pago de este cobro.
    const prev = await stripe.paymentIntents.search({ query: `metadata['cobro_id']:'${c.id}'`, limit: 10 });
    const vivo = prev.data.find((p) => ["succeeded", "processing", "requires_action", "requires_confirmation"].includes(p.status));
    if (vivo) {
      c = await cerrar(c.id, estadoDePI(vivo), vivo.id, null);
      return { doctor: doctorId, periodo: desde, neto, estado: c.estado, pi: vivo.id, nota: "reconciliado" };
    }

    // 4. Cobro con clave fija: un reintento técnico devuelve el mismo pago, nunca uno nuevo.
    const clave = `${c.idem_key}-p${c.reintento_pago}`;
    try {
      const pi = await stripe.paymentIntents.create({
        amount: Math.round(neto * 100),
        currency: "mxn",
        customer: doc.stripe_customer_id,
        payment_method: doc.stripe_payment_method,
        off_session: true,
        confirm: true,
        description: `Comisión Health Digital · consultas del ${c.periodo_inicio} al ${c.periodo_fin}`,
        metadata: { cobro_id: c.id, doctor_id: doctorId, periodo: c.periodo_inicio },
      }, { idempotencyKey: clave });
      c = await cerrar(c.id, estadoDePI(pi), pi.id, pi.status === "succeeded" ? null : (pi.last_payment_error?.message ?? pi.status));
      return { doctor: doctorId, periodo: desde, neto, estado: c.estado, pi: pi.id };
    } catch (e) {
      const err = e as Stripe.errors.StripeError & { raw?: { payment_intent?: { id?: string } } };
      if (err.type === "StripeCardError") {
        // Rechazo de la tarjeta: definitivo para este intento. Se guarda el PaymentIntent si Stripe lo devolvió.
        await cerrar(c.id, "fallido", err.payment_intent?.id ?? err.raw?.payment_intent?.id ?? null, err.message ?? "Pago rechazado");
        return { doctor: doctorId, periodo: desde, neto, estado: "fallido", error: err.code };
      }
      // Error de red o de Stripe sin respuesta clara: el bloqueo expira y la siguiente ejecución
      // vuelve a llamar con la MISMA clave, así Stripe devuelve el resultado del primer intento.
      throw e;
    }
  } catch (e) {
    console.error("cobro", doctorId, desde, e);
    return { doctor: doctorId, periodo: desde, estado: "reintentar", error: (e as Error).message };
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  const secreto = Deno.env.get("CRON_SECRET");
  if (!secreto || secreto.length < 24 || req.headers.get("x-cron-secret") !== secreto) return json({ error: "No autorizado" }, 401);

  let body: { desde?: string; hasta?: string } = {};
  try { body = await req.json(); } catch { /* sin cuerpo: mes anterior */ }
  const fecha = /^\d{4}-\d{2}-\d{2}$/;
  const { desde, hasta } = body.desde && body.hasta && fecha.test(body.desde) && fecha.test(body.hasta)
    ? { desde: body.desde, hasta: body.hasta } : mesAnterior();

  try {
    const resultado: unknown[] = [];
    // Cobros abiertos de periodos anteriores (rechazos, revisiones resueltas, intentos sin respuesta)
    const { data: abiertos, error: eA } = await admin.from("cobros_medicos")
      .select("doctor_id, periodo_inicio, periodo_fin").in("estado", ABIERTOS).lt("periodo_inicio", desde);
    if (eA) throw new Error(eA.message);
    for (const a of abiertos ?? []) resultado.push(await procesar(a.doctor_id, a.periodo_inicio, a.periodo_fin));
    // Periodo actual
    const medicos = await rpc<string[]>("medicos_a_procesar", { p_desde: desde, p_hasta: hasta });
    for (const m of medicos ?? []) resultado.push(await procesar(typeof m === "string" ? m : (m as { medicos_a_procesar: string }).medicos_a_procesar, desde, hasta));
    return json({ periodo: { desde, hasta }, procesados: resultado.length, resultado });
  } catch (e) {
    console.error("cobrar-comisiones", e);
    return json({ error: "No se pudo completar el cierre. Se puede volver a ejecutar sin riesgo de doble cobro." }, 500);
  }
});
