\set ON_ERROR_STOP 0
\pset format unaligned
\pset tuples_only on
\set A '''11111111-1111-1111-1111-111111111111'''
\set B '''22222222-2222-2222-2222-222222222222'''
\set D '''33333333-3333-3333-3333-333333333333'''
reset role; insert into perfiles (id,nombre,aviso_aceptado) values ('22222222-2222-2222-2222-222222222222','Beto Paciente',now()) on conflict (id) do nothing;
update doctores set verificado=true, suspendido=false, tarjeta_ok=true, especialidad='Dermatología' where id='dr-uno';
\echo '--- 1 Beto llega por el enlace del médico: origen enlace_medico, comisión 0 en reglas'
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select origen, reglas->>'comision', anticipo_estado from reservar_cita('dr-uno','s1',hoy_mx()+20,'09:00','Presencial','Beto Paciente',null,false,'idem-b9-0001','enlace_medico');
\echo '--- 2 Ana ya llegó por la app a dr-uno: aunque use el enlace, sigue como app'
select set_config('request.jwt.claim.sub',:A,false);
reset role; insert into citas (user_id,doctor_id,fecha,hora,modalidad,paciente,precio,folio,inicio,fin,origen) values (:A,'dr-uno',hoy_mx()-40,'09:00','Presencial','Ana Paciente',700,'PREV',inicio_cita(hoy_mx()-40,'09:00'),inicio_cita(hoy_mx()-40,'09:30'),'app');
set role authenticated; select set_config('request.jwt.claim.sub',:A,false);
select origen from reservar_cita('dr-uno','s1',hoy_mx()+20,'09:30','Presencial','Ana Paciente',null,false,'idem-a9-0001','enlace_medico');
\echo '--- 3 origen inválido no se acepta como enlace'
select origen from reservar_cita('dr-uno','s1',hoy_mx()+20,'10:00','Presencial','Ana Paciente',null,false,'idem-a9-0002','hackeo');
\echo '--- 4 estado de comisión: paciente propio atendido = paciente_propio (sin comisión)'
reset role;
insert into citas (user_id,doctor_id,fecha,hora,modalidad,paciente,precio,folio,inicio,fin,origen,asistencia_medico) values
 (:B,'dr-uno',hoy_mx()-10,'09:00','Presencial','Beto',1000,'PROPIO',inicio_cita(hoy_mx()-10,'09:00'),inicio_cita(hoy_mx()-10,'09:30'),'enlace_medico','asistio'),
 (:A,'dr-uno',hoy_mx()-10,'10:00','Presencial','Ana',1000,'APPX',inicio_cita(hoy_mx()-10,'10:00'),inicio_cita(hoy_mx()-10,'10:30'),'app','asistio');
select folio, estado_comision(c) from citas c where folio in ('PROPIO','APPX') order by folio;
\echo '--- 5 resumen: comisión 100 + IVA 16 solo por APPX'
select consultas, comisiones, iva from resumen_comisiones(hoy_mx()-11, hoy_mx()-9) where doctor_id='dr-uno';
\echo '--- 6 anticipo encendido: cita queda pendiente con $200; vence a los 20 min y libera el horario'
update config_plataforma set valor='true' where clave='anticipo_activo';
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select anticipo, anticipo_estado from reservar_cita('dr-uno','s1',hoy_mx()+21,'09:00','Presencial','Beto Paciente',null,false,'idem-b9-0002');
reset role;
update citas set creada=now()-interval '25 minutes' where idem_key='idem-b9-0002';
select 'liberadas:', liberar_anticipos_vencidos();
select estado, cancelada_por, anticipo_estado, (select count(*) from ocupados o where o.id=c.slot) from citas c where idem_key='idem-b9-0002';
\echo '--- 7 anticipo pagado (webhook) y luego el paciente cancela con más de 24 h: reembolso pendiente'
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select anticipo_estado from reservar_cita('dr-uno','s1',hoy_mx()+22,'09:00','Presencial','Beto Paciente',null,false,'idem-b9-0003');
reset role; select id as cpag from citas where idem_key='idem-b9-0003' \gset
select anticipo_pagado(:'cpag','cs_test_123');
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select estado, anticipo_estado from cancelar_cita(:'cpag');
reset role; update config_plataforma set valor='false' where clave='anticipo_activo';
\echo '--- 8 nadie de fuera marca anticipos pagados'
set role authenticated; select anticipo_pagado(:'cpag','x');
reset role;
\echo '--- 9 cierre con anticipos pagados: se acreditan al médico'
insert into citas (user_id,doctor_id,fecha,hora,modalidad,paciente,precio,folio,inicio,fin,origen,asistencia_medico,anticipo,anticipo_estado) values
 (:A,'dr-uno',hoy_mx()-60,'09:00','Presencial','Ana',1000,'ANT1',inicio_cita(hoy_mx()-60,'09:00'),inicio_cita(hoy_mx()-60,'09:30'),'app','asistio',200,'pagado');
select (tomar_cobro('dr-uno',hoy_mx()-61,hoy_mx()-59))->>'tomado';
select comisiones, iva, anticipos, neto from congelar_cobro((select id from cobros_medicos where doctor_id='dr-uno' and periodo_inicio=hoy_mx()-61));
\echo '--- 10 médicos que recomiendo: solo verificados, sin uno mismo, máx 12'
set role authenticated; select set_config('request.jwt.claim.sub',:D,false);
update doctores set recomendados=array['dr-uno','dr-tres','no-existe','dr-dos'] where id='dr-uno';
reset role; select recomendados from doctores where id='dr-uno';
set role anon; select 'público ve recomendados:', count(*) from (select recomendados from doctores) x; reset role;
\echo '--- 11 lista de espera: cada quien solo la suya; el resultado de la prueba no es público'
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
insert into lista_espera (plan, precio, grupo, alcaldia) values ('individual',149,'A','Tlalpan');
select count(*) as veo from lista_espera;
select set_config('request.jwt.claim.sub',:A,false);
select count(*) as veo_ajenas from lista_espera;
insert into lista_espera (user_id, plan, precio, grupo) values (:B,'individual',199,'B');
select * from prueba_precio();
reset role; select * from prueba_precio();
