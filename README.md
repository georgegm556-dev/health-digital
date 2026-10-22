# Health Digital · Cómo ponerla en línea con tu propia base de datos

Son 3 archivos:
- **index.html**: la app completa.
- **supabase.sql**: crea la base de datos y sus reglas de seguridad.
- **LEEME.md**: estas instrucciones.

Tiempo aproximado: 15 minutos. No necesitas saber programar.

---

## Paso 1 · Crea tu proyecto en Supabase (gratis)

1. Entra a **supabase.com** y crea una cuenta. Usa el correo de Health Digital.
2. Presiona **New project**.
   - Name: `health-digital`
   - Database password: genera una y guárdala en un lugar seguro.
   - Region: **East US (North Virginia)**, que es la más cercana a México.
3. Espera 1 o 2 minutos a que termine de crearse.

## Paso 2 · Crea la base de datos

1. En el menú de la izquierda abre **SQL Editor** y luego **New query**.
2. Abre el archivo **supabase.sql**, copia **todo** su contenido y pégalo.
3. Presiona **Run**. Debe aparecer "Success. No rows returned".

Si después necesitas volver a correrlo, puedes hacerlo sin problema: no borra nada.

## Paso 3 · Configura el inicio de sesión

1. Ve a **Authentication → Sign In / Providers → Email** y confirma que esté **activado**.
   Deja activado "Confirm email": así cada paciente confirma que el correo es suyo.
2. En **Authentication → URL Configuration**, en **Site URL**, pon la dirección donde publicarás la app (Paso 5). Por ejemplo: `https://healthdigital.netlify.app`.
   Agrega esa misma dirección en **Redirect URLs**.

## Paso 4 · Conecta la app a tu base de datos

1. En Supabase ve a **Project Settings → API** (o **Data API**).
2. Copia dos datos:
   - **Project URL**, que se ve como `https://abcdxyz.supabase.co`
   - **anon public key**, una clave larga que empieza con `eyJ...`
3. Abre **index.html** con un editor de texto (Bloc de notas, TextEdit en modo texto sin formato, o VS Code).
4. Busca `SUPABASE_URL` y pega los datos entre las comillas:

```js
const CONFIG = {
  SUPABASE_URL: 'https://abcdxyz.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOi...',
  DEMO: true
};
```

5. Guarda el archivo.

La "anon key" puede ir en la app sin peligro: es pública por diseño. Lo que protege los datos son las reglas del Paso 2.
**Nunca** pegues ahí la clave "service_role".

## Paso 5 · Publícala en internet

La forma más fácil es **Netlify Drop**:
1. Crea una carpeta y mete ahí el **index.html** ya editado.
2. Entra a **app.netlify.com/drop** y arrastra la carpeta.
3. Netlify te da un enlace. Regresa al Paso 3 y pon ese enlace en **Site URL**.

Otras opciones son Vercel y GitHub Pages. También puedes conectarle tu propio dominio, por ejemplo healthdigital.mx.

## Paso 6 · Pruébala

1. Abre el enlace y crea una cuenta con tu correo.
2. Confirma el correo con el enlace que te llega y vuelve a entrar.
3. Reserva una cita. Desde otro teléfono, con otra cuenta, verás que ese horario ya aparece ocupado.

---

## Activar el Portal médico para un doctor

Solo los médicos vinculados pueden bloquear horarios de su agenda:
1. El médico crea su cuenta en la app.
2. En Supabase ve a **Authentication → Users** y copia el **UID** de su usuario.
3. En **SQL Editor** corre esto, cambiando el UID y el médico:

```sql
insert into public.medicos (user_id, doctor_id)
values ('PEGA-AQUI-EL-UID', 'camila-restrepo');
```

Los identificadores de los médicos de ejemplo son: `camila-restrepo`, `alejandro-mendez`, `valeria-torres`, `diego-hernandez`, `sofia-ramirez`, `luis-ortega`, `andres-villalobos`, `paula-ibarra`.

## Qué protege la base de datos (ya probado)

- Cada paciente solo ve su perfil y sus citas. Nadie más, ni otro paciente ni alguien con la clave pública.
- **No se puede reservar dos veces el mismo horario.** Lo impide la propia base de datos.
- Otras personas solo ven qué horarios están ocupados, nunca quién los reservó.
- Solo puede opinar quien tuvo una cita real con ese médico, ya pasada, y solo una vez por cita.
- Un paciente no puede marcar su cita como "atendida" para dejar opiniones falsas.
- Solo el médico vinculado puede bloquear horarios de su agenda.

## Lo que falta para el lanzamiento comercial

- **Cobro real de membresías** con Stripe o Mercado Pago. Hoy activar un plan no cobra nada.
- **Directorio real de médicos:** pasar la lista de médicos a la base de datos y verificar cada cédula en el Registro Nacional de Profesionistas de la SEP.
- **Aviso de privacidad definitivo**, revisado por un abogado conforme a la LFPDPPP. Los datos de salud son datos sensibles.
- **Correo con tu marca:** configurar el envío de correos en Supabase para que la confirmación llegue desde Health Digital. El plan gratuito tiene un límite bajo de correos por hora.
- **App en tiendas:** empaquetarla para Google Play y la App Store.
- Cambiar `DEMO: true` por `DEMO: false` cuando ya no sea una demostración.
