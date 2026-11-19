\set ON_ERROR_STOP 0
\pset format unaligned
\pset tuples_only on
\echo '--- 1 médico nuevo: sin verificar, sin insignias'
insert into auth.users (id) values ('55555555-5555-5555-5555-555555555555') on conflict do nothing;
insert into doctores (id,user_id,nombre,especialidad,cedula,zona,direccion,modos,dias,horas,servicios,terminos_aceptados,tarjeta_ok)
values ('dr-tres','55555555-5555-5555-5555-555555555555','Dra. Tres Prueba','Cardiología','11112222','Roma','Calle 1','["Presencial"]','[1,2,3]','["09:00"]','[{"id":"s1","n":"Consulta","p":800,"min":30,"mem":false}]',now(),true);
select verificado, esp_verificada, consejo_verificado from doctores where id='dr-tres';
select 'por verificar:', count(*) from medicos_por_verificar() where cedula='11112222';
\echo '--- 2 solo cédula aprobada -> sigue sin verificar (falta identidad)'
select verificado from registrar_verificacion('11112222','cedula_sep','aprobado','Arumi','SEP: Médico Cirujano, UNAM, cédula activa. Constancia folio ABC123');
\echo '--- 3 identidad aprobada -> verificado'
select verificado from registrar_verificacion('11112222','identidad','aprobado','Arumi','Videollamada 12/11, INE coincide');
\echo '--- 4 especialidad y consejo -> insignias'
select especialidad, consejo from registrar_verificacion('11112222','especialidad','aprobado','Arumi','Cédula de especialidad 998877 en SEP');
select especialidad, consejo from registrar_verificacion('11112222','consejo','aprobado','Arumi','Certificado del Consejo Mexicano de Cardiología vigente');
\echo '--- 5 datos inválidos rechazados'
select registrar_verificacion('99999999','cedula_sep','aprobado','Arumi','no existe');
select registrar_verificacion('11112222','otra_cosa','aprobado','Arumi','paso inválido');
select registrar_verificacion('11112222','identidad','aprobado','A','corto');
\echo '--- 6 el médico no puede encenderse insignias ni ver revisor/evidencia; ve su avance'
set role authenticated; select set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',false);
update doctores set esp_verificada=true where id='dr-tres';
update doctores set verificado=true where id='dr-tres';
select revisor from verificaciones_medico limit 1;
select 'avance visible:', count(*) from (select paso, resultado, creado from verificaciones_medico) x;
select registrar_verificacion('11112222','consultorio','aprobado','Yo mismo','me autoverifico');
select 'nota vía mi_doctor:', coalesce(verificacion_nota,'(sin nota)') from mi_doctor();
\echo '--- 7 cambiar especialidad apaga verificación e insignias de especialidad'
update doctores set especialidad='Pediatría' where id='dr-tres';
reset role;
select verificado, esp_verificada, consejo_verificado, verificacion_nota from doctores where id='dr-tres';
\echo '--- 8 público: ve insignias, no la nota ni verificaciones'
set role anon;
select 'anon insignias:', count(*) from (select esp_verificada, consejo_verificado, consultorio_verificado from doctores) x;
select verificacion_nota from doctores limit 1;
select count(*) from verificaciones_medico;
reset role;
\echo '--- 9 otro médico no ve las revisiones de este'
set role authenticated; select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select 'dr-uno ve revisiones de dr-tres:', count(*) from (select paso from verificaciones_medico where doctor_id='dr-tres') x;
reset role;
\echo '--- 10 rechazo deja nota para el médico'
select verificado from registrar_verificacion('11112222','cedula_sep','rechazado','Arumi','El nombre en SEP no coincide','El nombre de tu cédula no coincide con tu perfil. Escríbenos.');
select verificacion_nota from doctores where id='dr-tres';
