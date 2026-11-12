\set ON_ERROR_STOP 0
\pset format unaligned
\pset tuples_only on
-- periodo de prueba: mes pasado
select (date_trunc('month', hoy_mx()) - interval '1 month')::date as d1, (date_trunc('month', hoy_mx()) - interval '1 day')::date as d2 \gset
insert into citas (user_id,doctor_id,fecha,hora,modalidad,paciente,precio,folio,inicio,fin,asistencia_medico,asistencia_paciente) values
 ('11111111-1111-1111-1111-111111111111','dr-uno',:'d1'::date+2,'09:00','Presencial','Ana',700,'P1',inicio_cita(:'d1'::date+2,'09:00'),inicio_cita(:'d1'::date+2,'09:30'),'asistio',null),
 ('11111111-1111-1111-1111-111111111111','dr-uno',:'d1'::date+3,'09:00','Presencial','Ana',700,'P2',inicio_cita(:'d1'::date+3,'09:00'),inicio_cita(:'d1'::date+3,'09:30'),'no_asistio','asistio');
\echo '--- 1 tomar dos veces: la segunda no lo toma'
select (tomar_cobro('dr-uno',:'d1',:'d2'))->>'tomado';
select (tomar_cobro('dr-uno',:'d1',:'d2'))->>'motivo';
select id as cobro from cobros_medicos where doctor_id='dr-uno' and periodo_inicio=:'d1' \gset
\echo '--- 2 congelar con una consulta en revisión -> no se cobra'
select estado, error from congelar_cobro(:'cobro');
\echo '--- 3 se resuelve a favor del médico; congelar -> 70 de comisión'
update citas set asistencia_paciente='no_asistio' where folio='P2';
select estado, comisiones, neto, congelado from congelar_cobro(:'cobro');
select 'congelar otra vez no duplica:', count(*) from (select congelar_cobro(:'cobro')) x;
select 'movimientos:', string_agg(tipo||'='||monto, ', ') from movimientos_medico where cobro_id=:'cobro';
select 'citas liquidadas:', count(*) from citas where doctor_id='dr-uno' and liquidada;
\echo '--- 4 paciente no puede cancelar/cambiar una cita liquidada (aunque fuera futura)'
\echo '--- 5 pagado dos veces = un movimiento de pago; un fallido después no lo despaga'
select estado from cerrar_cobro(:'cobro','pagado','pi_123');
select estado from cerrar_cobro(:'cobro','pagado','pi_123');
select estado from cerrar_cobro(:'cobro','fallido',null,'tarde');
select 'pagos registrados:', count(*) from movimientos_medico where cobro_id=:'cobro' and tipo='pago';
\echo '--- 6 saldo menor al mínimo se arrastra al siguiente periodo'
insert into cobros_medicos (doctor_id,periodo_inicio,periodo_fin,estado,neto,congelado) values ('dr-uno',:'d1'::date-31,:'d1'::date-1,'arrastrado',5,true) returning id as viejo \gset
insert into cobros_medicos (doctor_id,periodo_inicio,periodo_fin) values ('dr-uno',:'d2'::date+1,:'d2'::date+30) returning id as nuevo \gset
select 'a procesar incluye saldo:', count(*) from medicos_a_procesar(:'d2'::date+1,:'d2'::date+30) x where x='dr-uno';
select 'nuevo periodo con saldo:', saldo_anterior, neto from congelar_cobro(:'nuevo');
select 'el saldo no se vuelve a usar:', count(*) from movimientos_medico where tipo='arrastre' and nota=:'viejo';
\echo '--- 7 dos rechazos seguidos pausan el perfil; un pago lo reactiva'
select estado, reintento_pago from cerrar_cobro(:'nuevo','fallido',null,'card_declined');
select 'suspendido tras 1:', suspendido from doctores where id='dr-uno';
select estado, reintento_pago from cerrar_cobro(:'nuevo','fallido',null,'card_declined');
select 'suspendido tras 2:', suspendido from doctores where id='dr-uno';
select estado from cerrar_cobro(:'nuevo','pagado','pi_456');
select 'suspendido tras pago:', suspendido from doctores where id='dr-uno';
\echo '--- 8 bandeja de Stripe: el mismo evento solo se procesa una vez'
select evento_stripe_tomar('evt_1','invoice.paid');
select evento_stripe_cerrar('evt_1',true);
select evento_stripe_tomar('evt_1','invoice.paid');
\echo '--- 9 el médico ve sus movimientos; otro usuario no; nadie llama funciones de cobro'
set role authenticated; select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select 'médico ve movimientos:', count(*) from movimientos_medico;
select tomar_cobro('dr-uno',:'d1',:'d2');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select 'otro ve movimientos:', count(*) from movimientos_medico;
reset role;
