# Health Digital · Cómo verificar a un médico

Un médico aparece en el directorio solo cuando tiene **cédula** e **identidad** aprobadas, más su **tarjeta** registrada en Stripe. Cada revisión queda guardada: quién la hizo, cuándo y con qué evidencia.

Necesitas la actualización 8 (`actualizacion-8-verificacion.sql`) corrida en Supabase.

## 1. Ver quién está esperando

En Supabase → **SQL Editor → New query**:

```sql
select * from medicos_por_verificar();
```

Muestra a cada médico pendiente con:
- nombre, especialidad, cédula, teléfono y correo;
- cómo va su cédula y su identidad;
- cuántos documentos ha subido.

**Meta:** responder en menos de 24 horas hábiles. Es lo que le promete la app al médico.

## 2. Cédula profesional (obligatorio · lo haces tú, el médico no sube nada)

1. Entra a **cedulaprofesional.sep.gob.mx** y busca por número de cédula o por nombre.
2. Revisa que coincidan:
   - el **nombre completo**, igual al de su perfil;
   - la **profesión**: Médico Cirujano (o la carrera que corresponda: Psicología, Nutrición…);
   - que la cédula esté **vigente**.
3. Anota la institución y el año. Si te mandó su **Constancia de Situación Profesional**, escanea el QR y anota el folio.
4. Regístralo:

```sql
select * from registrar_verificacion(
  '12345678',            -- cédula del médico
  'cedula_sep',          -- paso
  'aprobado',            -- 'aprobado' o 'rechazado'
  'Arumi',               -- quién revisó
  'SEP: Médico Cirujano, UNAM 2012, cédula vigente. Constancia folio ABC123'  -- evidencia
);
```

Si no coincide, usa `'rechazado'` y agrega un mensaje para el médico como sexto dato:

```sql
select * from registrar_verificacion('12345678','cedula_sep','rechazado','Arumi',
  'El nombre en SEP es Ana López Pérez, en el perfil dice Ana López Ruiz',
  'El nombre de tu cédula no coincide con tu perfil. Corrígelo o escríbenos.');
```

El médico ve ese mensaje en su pantalla.

## 3. Llamada de bienvenida · identidad (obligatorio · 5 minutos)

1. Llama o escribe al teléfono o correo que muestra `medicos_por_verificar()` y agenden una videollamada corta.
2. En la llamada:
   - Pídele que muestre su **INE** a la cámara y compara foto y nombre con la persona y con la cédula. **No guardes foto de la INE**: solo anota que coincidió.
   - Ayúdale a revisar horarios, servicios y precios.
   - Explícale la comisión: 10% de cada consulta atendida, cobrado una vez al mes, y nada si el paciente no llega o cancela.
3. Regístralo:

```sql
select * from registrar_verificacion('12345678','identidad','aprobado','Arumi',
  'Videollamada 12/11/2026, INE coincide con nombre y foto');
```

Cuando **cédula** e **identidad** están aprobadas, la columna `verificado` pasa a `true` sola. En cuanto registre su tarjeta, el médico aparece en el directorio.

## 4. Insignias opcionales (cuando el médico sube un documento)

Los documentos están en Supabase → **Storage → documentos-medicos**, en la carpeta del médico. Es una carpeta privada: solo la ven el médico y quien administra Supabase.

| Insignia | Qué revisas | Paso |
|---|---|---|
| Especialidad verificada | Su **cédula de especialidad** existe en la SEP con su nombre y dice esa especialidad | `especialidad` |
| Certificado por su consejo | Certificado vigente de su consejo (por ejemplo, Consejo Mexicano de Cardiología). Confírmalo en la página del consejo | `consejo` |
| Consultorio verificado | Foto de la placa con su nombre o comprobante de domicilio, y la dirección coincide | `consultorio` |

```sql
select * from registrar_verificacion('12345678','especialidad','aprobado','Arumi',
  'Cédula de especialidad 9988776 en SEP: Cardiología, UNAM 2016');
```

## 5. Reglas automáticas

- Si el médico cambia **nombre o cédula**, vuelve a "en verificación" y deja de verse en el directorio hasta que lo revises otra vez.
- Si cambia de **especialidad**, también pierde las insignias de especialidad y de consejo.
- Si cambia la **dirección o el consultorio**, pierde la insignia de consultorio.
- El médico **no puede** encender ninguna insignia ni su verificación desde la app.

## 6. Ver el historial de un médico

```sql
select paso, resultado, revisor, evidencia, creado
  from verificaciones_medico v join doctores d on d.id = v.doctor_id
 where d.cedula = '12345678' order by creado;
```

Nada de este historial se borra. Si te equivocaste, registra la revisión correcta y la más reciente es la que cuenta.
