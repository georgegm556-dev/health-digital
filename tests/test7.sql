\set ON_ERROR_STOP 0
\set A '''11111111-1111-1111-1111-111111111111'''
\set B '''22222222-2222-2222-2222-222222222222'''
\set D '''33333333-3333-3333-3333-333333333333'''
\pset format unaligned
\pset tuples_only on
\echo '--- 1 Ana reserva Consulta 09:00 (ok, precio 700 del servidor, cubierta=false con bandera apagada)'
set role authenticated; select set_config('request.jwt.claim.sub',:A,false);
select precio, cubierta, duracion_min, servicio from reservar_cita('dr-uno','s1',hoy_mx()+7,'09:00','Presencial','Ana Paciente',null,false,'idem-ana-0001');
\echo '--- 2 mismo idem_key (doble clic) devuelve la misma cita, no crea otra'
select count(*) from (select reservar_cita('dr-uno','s1',hoy_mx()+7,'09:00','Presencial','Ana Paciente',null,false,'idem-ana-0001')) x;
select 'citas de Ana:', count(*) from citas where user_id=auth.uid();
\echo '--- 3 Beto mismo horario -> horario_ocupado'
select set_config('request.jwt.claim.sub',:B,false);
select reservar_cita('dr-uno','s1',hoy_mx()+7,'09:00','Presencial','Beto Paciente',null,false,'idem-beto-001');
\echo '--- 4 solapamiento: Ana servicio de 50 min a las 09:00 del día+8; Beto 09:30 ese día -> horario_ocupado'
select set_config('request.jwt.claim.sub',:A,false);
select fin-inicio from reservar_cita('dr-uno','s2',hoy_mx()+8,'09:00','Presencial','Ana Paciente',null,false,'idem-ana-0002');
select set_config('request.jwt.claim.sub',:B,false);
select reservar_cita('dr-uno','s1',hoy_mx()+8,'09:30','Presencial','Beto Paciente',null,false,'idem-beto-002');
select 'Beto 10:00 (ok):', hora from reservar_cita('dr-uno','s1',hoy_mx()+8,'10:00','Presencial','Beto Paciente',null,false,'idem-beto-003');
\echo '--- 5 escritura directa bloqueada (insert, update de precio, delete)'
insert into citas (doctor_id,fecha,hora,modalidad,paciente,precio,folio) values ('dr-uno',hoy_mx()+9,'09:00','Presencial','Beto',0,'X');
update citas set precio=0 where user_id=auth.uid();
delete from citas where user_id=auth.uid();
insert into ocupados (id,doctor_id,fecha,hora,tipo,inicio,fin) values ('dr-uno_x','dr-uno',hoy_mx()+9,'09:00','cita',now(),now());
\echo '--- 6 validaciones: médico inexistente, no verificado, servicio ajeno, fuera de agenda, pasado, modalidad, paciente ajeno'
select reservar_cita('dr-nadie','s1',hoy_mx()+7,'09:00','Presencial','Beto Paciente',null,false,'idem-beto-010');
select reservar_cita('dr-dos','s1',hoy_mx()+7,'09:00','Presencial','Beto Paciente',null,false,'idem-beto-011');
select reservar_cita('dr-uno','sX',hoy_mx()+7,'09:30','Presencial','Beto Paciente',null,false,'idem-beto-012');
select reservar_cita('dr-uno','s1',hoy_mx()+7,'11:00','Presencial','Beto Paciente',null,false,'idem-beto-013');
select reservar_cita('dr-uno','s1',hoy_mx()-1,'09:00','Presencial','Beto Paciente',null,false,'idem-beto-014');
select reservar_cita('dr-uno','s1',hoy_mx()+7,'09:30','Domicilio','Beto Paciente',null,false,'idem-beto-015');
select reservar_cita('dr-uno','s1',hoy_mx()+7,'09:30','Presencial','Otra Persona',null,false,'idem-beto-016');
\echo '--- 7 membresía con bandera apagada -> sin_cobertura'
select set_config('request.jwt.claim.sub',:A,false);
select reservar_cita('dr-uno','s1',hoy_mx()+7,'09:30','Presencial','Ana Paciente',null,true,'idem-ana-0003');
reset role; update config_plataforma set valor='true' where clave='cobertura_membresia'; set role authenticated;
\echo '    bandera encendida: primera cubierta ok, segunda rechazada (cupo 1), servicio no elegible rechazado'
select cubierta, precio from reservar_cita('dr-uno','s1',hoy_mx()+7,'09:30','Presencial','Ana Paciente',null,true,'idem-ana-0004');
select reservar_cita('dr-uno','s1',hoy_mx()+7,'10:00','Presencial','Ana Paciente',null,true,'idem-ana-0005');
select reservar_cita('dr-uno','s2',hoy_mx()+9,'09:00','Presencial','Ana Paciente',null,true,'idem-ana-0006');
reset role; update config_plataforma set valor='false' where clave='cobertura_membresia'; set role authenticated;
\echo '--- 8 privacidad: anónimo no lee user_id/cita_id; sí lo público'
reset role; set role anon;
select user_id from ocupados limit 1;
select cita_id from ocupados limit 1;
select * from resenas limit 1;
select user_id from doctores limit 1;
select 'anon ocupados públicos:', count(*) from (select id,doctor_id,fecha,hora,inicio,fin from ocupados) x;
select 'anon reseñas públicas:', count(*) from (select id,doctor_id,estrellas,texto from resenas) x;
select 'anon citas visibles:', count(*) from citas;
\echo '--- 9 Beto no ve ni toca citas de Ana'
reset role; set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select 'Beto ve citas ajenas:', count(*) from citas where user_id<>auth.uid();
select cancelar_cita((select id from citas where folio is not null limit 0));
reset role; select id as cita_ana from citas where user_id=:A and hora='09:00' and fecha=hoy_mx()+7 \gset
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select cancelar_cita(:'cita_ana');
select reprogramar_cita(:'cita_ana', hoy_mx()+10, '09:00', 'Presencial');
\echo '--- 10 reprogramar a horario ocupado falla y conserva la cita anterior'
select set_config('request.jwt.claim.sub',:A,false);
select reprogramar_cita(:'cita_ana', hoy_mx()+8, '10:00', 'Presencial');
select 'cita sigue igual:', fecha=hoy_mx()+7, hora, (select count(*) from ocupados o where o.id=c.slot) from citas c where id=:'cita_ana';
select 'reprograma a libre:', hora from reprogramar_cita(:'cita_ana', hoy_mx()+10, '10:30', 'Presencial');
select 'slot viejo liberado:', count(*) from ocupados where fecha=hoy_mx()+7 and hora='09:00';
\echo '--- 11 cancelar: futura ok; pasada no (sin cancelación retroactiva)'
select estado, cancelada_por from cancelar_cita(:'cita_ana');
select 'slot liberado:', count(*) from ocupados where fecha=hoy_mx()+10 and hora='10:30';
reset role;
insert into citas (user_id,doctor_id,fecha,hora,modalidad,paciente,precio,folio,inicio,fin,servicio_id) values (:A,'dr-uno',hoy_mx()-3,'09:00','Presencial','Ana Paciente',700,'HDPAST',inicio_cita(hoy_mx()-3,'09:00'),inicio_cita(hoy_mx()-3,'09:00')+interval '30 min','s1') returning id as cita_pasada \gset
set role authenticated; select set_config('request.jwt.claim.sub',:A,false);
select cancelar_cita(:'cita_pasada');
\echo '--- 12 opiniones: sin evidencia de asistencia -> rechazada; con confirmación del paciente -> ok'
insert into resenas (doctor_id,cita_id,estrellas,texto) values ('dr-uno',:'cita_pasada',5,'Muy bien');
select confirmar_asistencia(:'cita_pasada','asistio');
insert into resenas (doctor_id,cita_id,estrellas,texto) values ('dr-uno',:'cita_pasada',5,'Muy bien');
select 'mis_resenas:', count(*) from mis_resenas();
\echo '--- 13 médico: bloquear (ok), paciente no puede; editar perfil ok; cambiar especialidad -> vuelve a revisión'
select bloquear_horario(hoy_mx()+11,'09:00');
select set_config('request.jwt.claim.sub',:D,false);
select 'bloqueo médico:', bloquear_horario(hoy_mx()+11,'09:00');
update doctores set bio='Nueva bio' where id='dr-uno';
select 'verificado tras editar bio:', verificado from doctores where id='dr-uno';
update doctores set especialidad='Cardiología' where id='dr-uno';
reset role; select 'verificado tras cambiar especialidad:', verificado, especialidad from doctores where id='dr-uno';
update doctores set verificado=true, especialidad='Dermatología' where id='dr-uno';
select 'admin re-verifica (sin auth.uid):', verificado from doctores where id='dr-uno';
\echo '--- 14 borrar mis datos (Beto): futuras canceladas, perfil fuera, citas conservadas y anonimizadas'
set role authenticated; select set_config('request.jwt.claim.sub',:B,false);
select borrar_mis_datos();
reset role;
select 'Beto citas:', estado, paciente from citas where user_id=:B;
select 'Beto perfil:', count(*) from perfiles where id=:B;
select 'Beto ocupados:', count(*) from ocupados where user_id=:B;
