# Health Digital · Seguridad y reglas de negocio (actualización 7)

Respuesta a la auditoría del 3 de noviembre de 2026 sobre el commit `62a9581`. Al empezar, el HEAD del repositorio era ese mismo commit, así que los hallazgos aplican tal cual.

**Estado:** es una revisión técnica con pruebas en un Postgres 16 local y en navegador con un servidor simulado. **No está probado contra el proyecto real de Supabase ni contra Stripe sandbox**; ver "Pendiente de ejecutar". No declara cumplimiento legal.

Leyenda: **Implementado** = código escrito. **Probado** = prueba automática que pasa. **Pendiente** = falta trabajo o una decisión humana.

## 1. Hallazgos P0 y P1

| # | Hallazgo de la auditoría | Qué se hizo | Estado | Prueba |
|---|---|---|---|---|
| 1 | El paciente podía escribir `precio`, `cubierta`, `servicio`, `fecha`, `hora`, `slot` | Se revocó toda escritura directa en `citas` y `ocupados`. La función `reservar_cita` recibe solo identificadores y toma precio, duración y servicio del catálogo del médico; guarda una copia en `citas.reglas` | Implementado y probado | test7 §5, §6; t16 (el navegador cambia el precio y el servidor guarda el del catálogo) |
| 2 | `claim()` y `addCita()` iban por separado, sin reversa | Reservar, cambiar y cancelar son una sola función por operación, en una transacción. Si algo falla, no queda un horario sin cita ni una cita sin horario | Implementado y probado | test7 §10 (un cambio fallido conserva la cita anterior) |
| 3 | El paciente cancelaba o borraba sin límite de tiempo | Ya no se pueden borrar citas. Solo se cancela antes de la hora de inicio y nunca una cita ya liquidada. "Borrar mis datos" cancela las citas futuras y anonimiza las pasadas | Implementado y probado | test7 §11, §14 |
| 4 | El cobro mensual podía duplicarse (clave `cobro-id-intentos`) | Un cobro por médico y periodo, con bloqueo (`tomar_cobro`). Los montos se congelan una vez y la clave de Stripe es fija; solo cambia tras un rechazo definitivo. Antes de cobrar se consulta el pago anterior y se busca en Stripe por `cobro_id`, porque la clave de Stripe vence a las 24 h | Implementado. SQL probado; función sin probar con Stripe | test7b §1, §3, §5 |
| 5 | El webhook no registraba `event.id` ni manejaba eventos en desorden | Bandeja `stripe_eventos` con `event.id` único. Siempre se consulta el estado actual de la suscripción o del pago en Stripe. Todo error de base de datos se detecta y el evento no se marca procesado si algo falló | Implementado. SQL probado; función sin probar con Stripe | test7b §8; `deno check` |
| 6 | La membresía pierde dinero ($300 contra $630 pagados al médico) | Banderas `cobertura_membresia` y `venta_membresias`, **apagadas**. La base de datos no cubre citas, la función `pagos` no vende y la app muestra "Próximamente". Los planes y datos existentes se conservan | Implementado y probado | test7 §7; t16 |
| 7 | El aviso de privacidad no coincidía con lo que ve el médico | El aviso ahora dice que el médico ve nombre, servicio, fecha y motivo. Se quitó "tu expediente solo lo ves tú" | Implementado. **Falta revisión legal** | t16 |
| 8 | `ocupados` y `resenas` exponían `user_id` y `cita_id` | Permisos por columna: el público solo lee columnas sin identificadores. `mis_resenas()` le dice al paciente en qué citas opinó. Tiempo real por una tabla de `senales` sin datos (antes los avisos podían llevar columnas privadas de `doctores`). `doctores.user_id` dejó de ser público | Implementado y probado | test7 §8 |
| 9 | El cupo de membresía se podía rebasar con reservas simultáneas | Bloqueo por titular (`pg_advisory_xact_lock`). El cupo se cuenta por periodo de facturación, y la cita debe caer dentro del periodo pagado | Implementado y probado | Prueba concurrente: dos reservas cubiertas a la vez, solo una se cubre |
| 10 | Solo se impedía la misma hora de inicio, no el encime | Restricción `exclude using gist` sobre el rango `[inicio, fin)` por médico. La app también oculta horarios que caen dentro de otra cita | Implementado y probado | test7 §4; prueba concurrente |
| 11 | Opiniones sin evidencia de asistencia | Solo se opina si el médico marcó "asistió" o el paciente lo confirmó, y nunca si el médico marcó "no asistió" | Implementado y probado | test7 §12 |
| 12 | `a_favor_medico` no se transfería y los saldos chicos desaparecían | Ledger `movimientos_medico` (no se borra nada). Los saldos menores a $10 quedan `arrastrado` y se suman al siguiente periodo. Los saldos a favor se transfieren a mano con `registrar_transferencia` (referencia y revisor) | Implementado y probado. **La transferencia no es automática** | test7b §6 |
| 13 | La cancelación tragaba errores de Stripe | Primero se consulta la suscripción; si no se confirma `canceled`, se responde error y no se marca nada en la base | Implementado. Sin probar con Stripe | `deno check` |
| 14 | E-books con desbloqueo local y capítulos pendientes | Con Supabase la venta está desactivada ("Venta disponible pronto"); la vista previa sigue. La demo local dice "(demo)" | Implementado | t16 |
| 15 | Un médico verificado podía cambiar especialidad sin nueva revisión | Si el médico cambia nombre, cédula o especialidad, `verificado` vuelve a falso. Administración puede reverificar | Implementado y probado | test7 §13 |
| 16 | Se prometían recordatorios 24 h / 2 h y una sala de video | Se retiraron esas promesas: ahora "agrega la cita a tu calendario" y "el consultorio te compartirá el enlace" | Implementado | Revisión visual |
| 17 | Cobro del día 4 antes de que cierre la ventana de 7 días del paciente | El cierre pasa al **día 10**. Si hay consultas en revisión, no se cobra hasta resolverlas | Implementado y probado | test7b §2 |
| 18 | Disputas resueltas cambiando campos a mano | `resolver_revision(cita, decisión, revisor, evidencia, avisado)` deja registro en `revisiones_asistencia`. No resuelve a favor del cobro sin haber avisado al médico | Implementado y probado | Prueba manual SQL |
| 19 | El diálogo dejaba el foco en el fondo | Al abrir: foco inicial en el título, Tab no sale del diálogo y el fondo queda `inert`. Al cerrar, el foco regresa al botón que lo abrió | Implementado y probado | t16 |
| 20 | Rechazo de tarjeta = suspensión inmediata | El primer rechazo avisa y se reintenta en el siguiente cierre. Al segundo rechazo seguido se pausa el perfil, y se reactiva al registrar una tarjeta nueva o pagar | Implementado y probado | test7b §7 |
| 21 | Perfiles de ejemplo con "Cédula verificada" | Los perfiles de ejemplo dicen "Perfil de ejemplo · datos ficticios", sin la insignia. Con Supabase no se pueden reservar (el servidor rechaza médicos que no existen o no están verificados) | Implementado y probado | t16 |

## 2. Reglas de una cita

```
reservar_cita ──► confirmada ──(antes de la hora)──► cancelada (paciente o médico)
                      │
                      ├─(llega la hora)──► asistencia: médico 72 h · paciente 7 días
                      │                     ├─ médico "asistió" o nadie marca en 72 h ─► cobrable
                      │                     ├─ médico "no asistió" ─► sin comisión
                      │                     └─ médico "no asistió" + paciente "sí" ─► en revisión ─► resolver_revision
                      └─(cierre del día 10)──► liquidada: ya no se cambia ni se cancela
```

- **Precio:** el del servicio del catálogo del médico al momento de reservar. Queda en `citas.precio` y `citas.reglas`.
- **Duración:** la del servicio (5 a 480 min). Ocupa el rango `[inicio, fin)` en `ocupados`.
- **Zona horaria:** `America/Mexico_City` para todas las sedes. **Pendiente:** zona por sede para otras ciudades.
- **Doble clic:** cada reserva lleva `idem_key`, y repetir la misma solicitud devuelve la misma cita.

## 3. Cobros a médicos

1. El día 10, `cobrar-comisiones` toma cada médico con `tomar_cobro`. Un bloqueo de 10 minutos impide que otra ejecución procese el mismo cobro a la vez.
2. `congelar_cobro` calcula una sola vez: comisiones, créditos por membresía y saldo anterior (`arrastre`). Todo queda en `movimientos_medico`.
3. Según el neto:
   - negativo: `a_favor_medico`, y se transfiere a mano;
   - cero: `sin_cargo`;
   - menor a $10: `arrastrado`;
   - de $10 en adelante: se cobra a la tarjeta.
4. Antes de cobrar, se revisa en Stripe si ya existe un pago de ese cobro. Se cobra con la clave fija `cobro-<id>-p<n>`.
5. El resultado llega por la función o por el webhook (`cerrar_cobro`); los dos son idempotentes. Un cobro `pagado` nunca cambia.

Transferir un saldo a favor (solo administración, en SQL Editor):

```sql
select registrar_transferencia('<id del cobro>', '<referencia SPEI>', '<quién revisó>');
```

## 4. Roles y quién puede qué

| Acción | Invitado | Paciente | Médico | Servidor / admin |
|---|---|---|---|---|
| Ver directorio, horarios y opiniones (sin identificadores) | Sí | Sí | Sí | Sí |
| Reservar, cambiar, cancelar | No | Solo las suyas, por función | No | — |
| Ver citas | No | Las suyas | Las de su agenda | Todas |
| Bloquear horarios | No | No | Su agenda | — |
| Marcar asistencia | No | Confirmar la suya | Las de su agenda | Resolver revisión |
| Ver cobros y movimientos | No | No | Los suyos | Todos |
| Cambiar precio, verificación, comisión o tarjeta | No | No | Solo el catálogo de servicios; un cambio material quita la verificación | Sí |
| Funciones de cobro y bandeja de Stripe | No | No | No | Solo con llave de servidor |

## 5. Cómo aplicarlo

1. **Proyecto de prueba primero.** Crea un segundo proyecto de Supabase (staging) y corre `supabase.sql` y luego `actualizacion-7-seguridad.sql`.
2. Publica ahí la app de la rama `seguridad-p0` y las 3 funciones nuevas. Prueba con las tarjetas de prueba de Stripe (PAGOS.md, Paso 9).
3. Si todo funciona, en el proyecto real:
   1. respalda la base (Database → Backups);
   2. corre `actualizacion-7-seguridad.sql`;
   3. publica las 3 funciones;
   4. fusiona la rama a `main`.

   **Orden importante:** la app nueva necesita la actualización 7 para reservar. La app vieja deja de poder reservar en cuanto corres la actualización 7, así que hazlo todo seguido.
4. Cambia el programador del cobro al día 10 (PAGOS.md, Paso 8.5).
5. **Reversa:** la migración no borra datos. Si algo sale mal, vuelve a la versión anterior de `index.html` y restaura el respaldo. No intentes revertir a mano los permisos.

**Pruebas locales:** `tests/correr-pruebas.sh` (necesita Postgres 16 con `btree_gist`). Las pruebas del navegador están en `tests/t16.mjs` (Playwright, con un Supabase simulado).

## 6. Pendiente de ejecutar o decidir

**Sin probar todavía, necesita acceso:**
- Correr la migración en el Supabase real o de staging y comparar con el esquema actual exportado.
- Stripe sandbox:
  - evento duplicado y evento viejo después de una cancelación;
  - corte de red justo después de cobrar;
  - dos ejecuciones del cierre a la vez;
  - rechazo de tarjeta y autenticación 3DS;
  - cancelación fallida.
- Comprobar que Realtime no envía columnas privadas (se quitaron las tablas de la publicación por precaución).

**Decisiones de negocio y legales (responsable humano):**
- Tarifa de red y convenios antes de encender `cobertura_membresia` y `venta_membresias`.
- Definir qué genera comisión: ¿solo pacientes nuevos que llegan por Health Digital? Si cambia, se necesita una nueva versión de las reglas (`citas.reglas`) sin cobrar retroactivamente.
- Aviso de privacidad, consentimiento expreso para datos de salud (LFPDPPP 2025), términos de suscripción (LFPC art. 76 Bis), contrato con médicos, CFDI.
- Proceso completo de borrado: cuenta de acceso (Auth), Stripe y respaldos. Hoy se borra el perfil, se cancelan las citas futuras y se anonimizan las pasadas.
- Representación de familiares: un adulto no debe ver datos clínicos de otro adulto.

**Técnico, siguiente fase (P1):**
- Zona horaria por sede.
- Catálogo de servicios como tabla versionada (hoy es JSON dentro del médico, con una copia en cada cita).
- Recordatorios reales con proveedor de mensajes.
- Videollamada con salas privadas.
- MFA para administración.
- CI con estas pruebas.
- Páginas públicas por médico (SEO).
