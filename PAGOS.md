# Health Digital · Cómo activar los pagos con Stripe

Incluye dos tipos de cobro:
- **Membresías de pacientes:** $300 y $500 al mes, con cobro automático.
- **Comisión del 10% a médicos:** el médico registra su tarjeta y cada mes se le cobra el 10% de las consultas que atendió.

Primero se hace todo en **modo de prueba**: con tarjetas falsas y sin cobrar dinero real.
Cuando funcione, se cambia a modo real (Paso 8).

Tiempo aproximado: 30 a 40 minutos.

---

## Paso 1 · Crea tu cuenta de Stripe

1. Entra a **dashboard.stripe.com/register** y regístrate con el correo de Health Digital.
2. País: **México**. Para el modo de prueba no necesitas subir documentos todavía.
3. Arriba a la derecha, confirma que esté activado **"Modo de prueba" / "Test mode"**.

## Paso 2 · Crea los dos planes en Stripe

1. Ve a **Catálogo de productos → + Agregar producto**.
2. Primer producto:
   - Nombre: `Plan Individual Health Digital`
   - Precio: `300` · Moneda: **MXN** · **Recurrente** · Periodo: **Mensual**
   - Guarda.
3. Segundo producto:
   - Nombre: `Plan Familiar Health Digital`
   - Precio: `500` · **MXN** · **Recurrente** · **Mensual**
   - Guarda.
4. Entra a cada producto y copia el **ID del precio**. Empieza con `price_...`.
   Anota cuál es el Individual y cuál el Familiar.

## Paso 3 · Copia tu clave secreta de Stripe

1. Ve a **Desarrolladores → Claves de API**.
2. Copia la **Clave secreta**. Empieza con `sk_test_...`.
   ⚠️ No la mandes por chat ni la pegues en la app. Solo va en Supabase (Paso 4).

## Paso 4 · Guarda las claves en Supabase

1. En Supabase ve a **Edge Functions → Secrets**. También está en Project Settings → Edge Functions.
2. Agrega estos 4 secretos, uno por uno (Name / Value):

| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | tu clave `sk_test_...` |
| `PRICE_INDIVIDUAL` | el `price_...` del Plan Individual |
| `PRICE_FAMILIAR` | el `price_...` del Plan Familiar |
| `SITE_URL` | `https://georgegm556-dev.github.io/health-digital/` |
| `CRON_SECRET` | una contraseña larga que tú inventes, por ejemplo `hd-cobro-7Kq2-9fXz-2026`. Protege el cobro mensual |

3. Guarda.

## Paso 5 · Publica las 2 funciones del servidor

En Supabase ve a **Edge Functions → Deploy a new function → Via Editor**.

**Función 1**
- Nombre: `pagos` (exactamente así)
- Borra el código de ejemplo y pega todo el archivo `supabase/functions/pagos/index.ts`
- Presiona **Deploy**

**Función 2**
- Nombre: `stripe-webhook` (exactamente así)
- Pega todo el archivo `supabase/functions/stripe-webhook/index.ts`
- Presiona **Deploy**

**Función 3**
- Nombre: `cobrar-comisiones` (exactamente así)
- Pega todo el archivo `supabase/functions/cobrar-comisiones/index.ts`
- Presiona **Deploy**

**Importante:** en cada una de las 3 funciones entra a sus **Settings / Details** y **apaga "Verify JWT"**
(puede decir "Enforce JWT verification" o "Verify JWT with legacy secret").
- `stripe-webhook` lo necesita porque Stripe no inicia sesión. La función verifica la firma de Stripe.
- `pagos` lo necesita para que el navegador pueda llamarla. La función revisa la sesión del usuario.
- `cobrar-comisiones` lo necesita porque la llama el programador automático. La protege tu `CRON_SECRET`.

## Paso 6 · Conecta el aviso de Stripe (webhook)

1. En Stripe ve a **Desarrolladores → Webhooks → + Agregar destino** (o "Add endpoint").
2. URL del endpoint:
   `https://kzajozfetwfmbxojgnol.supabase.co/functions/v1/stripe-webhook`
3. Eventos a escuchar (selecciona estos 8):
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `payment_intent.succeeded`
   - `payment_intent.payment_failed`
4. Guarda y copia el **Secreto de firma**. Empieza con `whsec_...`.
5. Regresa a Supabase → Edge Functions → Secrets y agrega:

| Name | Value |
|---|---|
| `STRIPE_WEBHOOK_SECRET` | tu `whsec_...` |

## Paso 7 · Activa el portal del cliente en Stripe

Con el portal, el paciente cambia su tarjeta, descarga recibos o cancela sin escribirte.

1. En Stripe ve a **Configuración → Facturación → Portal de clientes**.
2. Actívalo y permite:
   - actualizar método de pago;
   - ver historial de facturas;
   - cancelar suscripciones.
3. Guarda.

## Paso 8 · Bloquea las membresías gratis y activa el registro de médicos

En Supabase → **SQL Editor → New query**, corre estos dos archivos, uno por uno y en este orden:
1. `actualizacion-3-pagos.sql`
2. `actualizacion-4-medicos.sql`

Desde ese momento:
- solo un pago real de Stripe puede activar un plan;
- la base de datos impide usar más consultas incluidas de las que tiene el plan cada mes.

## Paso 8.5 · Programa el cobro mensual a médicos

El cobro de comisiones se hace solo el **día 4 de cada mes a las 10:00 a. m.** (hora de la Ciudad de México).

1. En Supabase ve a **Database → Extensions**. Busca y activa **pg_cron** y **pg_net**.
2. En **SQL Editor → New query** pega esto. Cambia `TU_CRON_SECRET` por el mismo valor del Paso 4 y presiona **Run**:

```sql
select cron.schedule(
  'cobro-comisiones-medicos',
  '0 16 4 * *',
  $$ select net.http_post(
       url := 'https://kzajozfetwfmbxojgnol.supabase.co/functions/v1/cobrar-comisiones',
       headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','TU_CRON_SECRET'),
       body := '{}'::jsonb) $$
);
```

`0 16 4 * *` significa día 4 a las 16:00 UTC, que son las 10:00 en la Ciudad de México.

## Paso 8.6 · Cómo das de alta a un médico

1. El médico entra a la app, toca **Crear cuenta → Soy médico** y llena su perfil.
2. Tú verificas su cédula en **cedulaprofesional.sep.gob.mx**.
3. Si es correcta, en **SQL Editor** corre esto, cambiando la cédula:

```sql
update public.doctores set verificado = true where cedula = '12345678';
```

4. El médico registra su tarjeta desde la app (**Pagos → Registrar tarjeta**). En ese momento aparece en el directorio.

**Consultas en revisión** (el médico dijo "no asistió" y el paciente dice que sí):

```sql
-- Ver las que están en revisión
select c.id, d.nombre, c.fecha, c.hora, c.paciente
  from citas c join doctores d on d.id = c.doctor_id
 where c.asistencia_medico = 'no_asistio' and c.asistencia_paciente = 'asistio';
-- Resolver a favor de Health Digital (sí se cobra):
update public.citas set asistencia_medico = 'asistio' where id = 'ID_DE_LA_CITA';
-- Resolver a favor del médico (no se cobra):
update public.citas set asistencia_paciente = 'no_asistio' where id = 'ID_DE_LA_CITA';
```

Cuando ya tengas médicos reales, abre `index.html` y cambia `MEDICOS_EJEMPLO: true` por `false` para ocultar los 8 médicos de ejemplo.

## Paso 9 · Prueba con una tarjeta de prueba

1. Abre la app, entra a **Membresía → Elegir Plan Familiar → Continuar al pago**.
2. En la página de Stripe usa:
   - Tarjeta: `4242 4242 4242 4242`
   - Fecha: cualquier fecha futura (ej. `12/30`)
   - CVC: cualquier número (ej. `123`)
   - Nombre y código postal: los que quieras
3. Al pagar, regresas a la app y en unos segundos aparece tu **credencial** con número de socio.
4. Para el médico: entra con una cuenta de médico, ve a **Pagos → Registrar tarjeta**, usa `4242 4242 4242 4242` y verifícalo con el SQL del Paso 8.6.
5. Para probar el cobro mensual sin esperar al día 4, en SQL Editor corre esto (con tu `CRON_SECRET`):

```sql
select net.http_post(
  url := 'https://kzajozfetwfmbxojgnol.supabase.co/functions/v1/cobrar-comisiones',
  headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','TU_CRON_SECRET'),
  body := jsonb_build_object('desde', to_char(current_date - 30, 'YYYY-MM-DD'), 'hasta', to_char(current_date, 'YYYY-MM-DD')));
```

6. Prueba también:
   - **Pagos, recibos y cancelación** en Membresía, para abrir el portal;
   - una tarjeta que falla: `4000 0000 0000 0341`, que se acepta al inicio y falla en la renovación.

## Paso 10 · Pasar a cobros reales (cuando todo funcione)

1. En Stripe completa la **activación de la cuenta**: RFC, datos del negocio, CLABE para depósitos y representante legal.
2. Desactiva el modo de prueba. Vuelve a crear los 2 productos en modo real y copia sus nuevos `price_...`.
3. Copia la nueva clave `sk_live_...`.
4. Crea el webhook otra vez en modo real y copia su nuevo `whsec_...`.
5. En Supabase cambia los secretos `STRIPE_SECRET_KEY`, `PRICE_INDIVIDUAL`, `PRICE_FAMILIAR` y `STRIPE_WEBHOOK_SECRET` por los de modo real.
6. Activa el portal de clientes también en modo real.

---

### Qué hace cada pieza

- **Función `pagos`:**
  - crea la página de pago de Stripe;
  - cambia de plan con prorrateo;
  - abre el portal del cliente;
  - cancela la suscripción si el paciente borra su cuenta.
- **Función `stripe-webhook`:** recibe los avisos de Stripe y es la **única** que activa, renueva o desactiva membresías. También marca la tarjeta del médico como registrada y anota si el cobro de su comisión pasó o fue rechazado. Rechaza cualquier aviso sin la firma correcta de Stripe.
- **Función `cobrar-comisiones`:** cada mes cobra a cada médico el 10% de sus consultas atendidas y le descuenta el 90% de las consultas con membresía. Si el cobro es rechazado, pausa su perfil hasta que actualice la tarjeta. Nunca cobra dos veces el mismo mes.
- **Reglas de comisión (en la base de datos):**
  - cancelada por el paciente o por el médico: no se cobra;
  - el médico marca "no asistió" dentro de 72 h: no se cobra;
  - el médico no marca nada en 72 h: cuenta como atendida y se cobra;
  - el médico dice "no asistió" y el paciente dice "sí asistí": queda en revisión y lo decides tú;
  - el médico no puede verificarse solo, ni cambiar su comisión, ni leer datos de pago de otros.
- **Reglas de la base de datos:**
  - el paciente no puede activarse un plan;
  - no puede exceder sus consultas incluidas;
  - solo puede agregar familiares con Plan Familiar.

### Pendiente para después

- **Facturas CFDI:** Stripe no las emite. Se puede conectar un servicio como Facturama o Facturapi para generarlas en cada pago.
- **Aviso de privacidad y términos de la membresía:** revisa con un abogado las condiciones de renovación y cancelación.
