insert into auth.users values ('33333333-3333-3333-3333-333333333333'),('44444444-4444-4444-4444-444444444444') on conflict do nothing;
insert into doctores (id,user_id,nombre,especialidad,cedula,zona,direccion,modos,dias,horas,servicios,terminos_aceptados,verificado,tarjeta_ok)
values ('dr-uno','33333333-3333-3333-3333-333333333333','Dra. Uno Prueba','Dermatología','12345678','Roma','Calle Falsa 123','["Presencial","Videoconsulta"]','[0,1,2,3,4,5,6]','["09:00","09:30","10:00","10:30"]',
 '[{"id":"s1","n":"Consulta","p":700,"min":30,"mem":true},{"id":"s2","n":"Larga","p":900,"min":50,"mem":false}]',now(),true,true),
       ('dr-dos','44444444-4444-4444-4444-444444444444','Dr. Dos Prueba','Pediatría','87654321','Roma','Calle Falsa 456','["Presencial"]','[0,1,2,3,4,5,6]','["09:00"]',
 '[{"id":"s1","n":"Consulta","p":500,"min":30,"mem":true}]',now(),false,false);
insert into perfiles (id,nombre,aviso_aceptado) values ('11111111-1111-1111-1111-111111111111','Ana Paciente',now()),('22222222-2222-2222-2222-222222222222','Beto Paciente',now());
update perfiles set plan='individual', plan_estado='active', renovacion=now()+interval '20 days' where id='11111111-1111-1111-1111-111111111111';
grant execute on function public.hoy_mx() to anon, authenticated;
