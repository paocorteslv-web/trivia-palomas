-- Tests de schema.sql contra Postgres real (con supabase_stub.sql). Lo corre tests/sql/run.sh.
\set ON_ERROR_STOP 1
\set QUIET 1
create schema t; grant usage on schema t to anon, authenticated;
create function t.login(mail text) returns void language sql security definer as
$$ select set_config('request.jwt.claim.sub',coalesce((select id::text from auth.users u where u.email=mail),''),false) $$;
create function t.fails(q text, pat text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then
    if sqlerrm !~* pat then raise exception 'Error inesperado en [%]: % (se esperaba %)', q, sqlerrm, pat; end if;
    raise notice '  ✔ rechazado: %', sqlerrm; return;
  end;
  raise exception 'Debía fallar y no falló: %', q;
end $$;
create function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is distinct from true then raise exception 'FALLA: %', msg; end if; raise notice '  ✔ %', msg; end $$;
create function t.uid(mail text) returns uuid language sql security definer as $$ select id from auth.users u where u.email=mail $$;
grant execute on all functions in schema t to anon, authenticated;
-- esperado de caja visto como superusuario (la función no está expuesta a clientes)
create function t.exp(d date) returns numeric language sql security definer as $$ select public.expected_cash(d) $$;
grant execute on function t.exp(date) to authenticated;

-- usuarios: el primero es ADMIN activo; los siguientes OPERADOR inactivo
insert into auth.users(email) values('admin@x'),('op@x'),('op2@x');
select t.ok((select role='ADMIN' and active from profiles where name='admin@x'),'primer usuario = ADMIN activo');
select t.ok((select role='OPERADOR' and not active from profiles where name='op@x'),'segundo usuario = OPERADOR inactivo');

\echo '— Usuarios y permisos'
set role authenticated;
select t.login('op@x');
select t.ok((select count(*) from records)=0,'OPERADOR inactivo no lee registros');
select t.fails($$insert into records(kind,id,date,data) values('ventas','v0',mza_today(),'{"medio":"EFECTIVO","total":1,"items":[{"qty":1,"price":1}]}')$$,'no está activo');
select t.login('admin@x');
update profiles set active=true where name='op@x';
select t.fails($$update profiles set active=false where name='admin@x'$$,'al menos un ADMIN');
select t.login('op@x');
select t.ok((select count(*) from profiles)=1,'OPERADOR solo ve su propio perfil');
update profiles set role='ADMIN' where name='op@x';
select t.ok(not is_admin(),'OPERADOR no puede ascenderse a ADMIN');
select t.fails($$insert into profiles(id,role,active) values(gen_random_uuid(),'ADMIN',true)$$,'permission denied');

\echo '— I) OPERADOR no modifica configuración, productos, stock ni compromisos'
select t.fails($$insert into records(kind,id,data) values('config','main','{"consumo":0.1,"precio":1,"capital":0}')$$,'Solo un ADMIN');
select t.fails($$insert into records(kind,id,data) values('productos','p1','{"name":"X","price":1}')$$,'Solo un ADMIN');
select t.fails($$insert into records(kind,id,data) values('inventario','i1','{"name":"X","stock0":0,"min":0}')$$,'Solo un ADMIN');
select t.fails($$insert into records(kind,id,date,data) values('futuros','f1',mza_today(),'{"amount":1,"kind":"GASTO","freq":"ONCE"}')$$,'Solo un ADMIN');

\echo '— A) ADMIN crea producto, OPERADOR lo ve y vende, ADMIN ve la venta'
select t.login('admin@x');
insert into records(kind,id,data) values('config','main','{"consumo":0.1,"precio":1000,"capital":5000,"medios":["EFECTIVO","TRANSFERENCIA"]}');
insert into records(kind,id,data) values('productos','p1','{"name":"Café","price":500,"active":true}');
select t.fails($$insert into records(kind,id,data) values('productos','p2','{"name":"Gratis","price":0}')$$,'mayor a 0');
select t.login('op@x');
select t.ok((select count(*) from records where kind='productos')=1,'OPERADOR ve el producto');
select t.fails($$insert into records(kind,id,date,data) values('aperturas',(mza_today()-1)::text,mza_today()-1,'{"open":1}')$$,'caja de hoy');
insert into records(kind,id,date,data) values('aperturas',mza_today()::text,mza_today(),'{"open":10000}');
insert into records(kind,id,date,data,created_by) values('ventas','v1',mza_today(),'{"medio":"EFECTIVO","total":1000,"items":[{"name":"Café","qty":2,"price":500}]}',t.uid('admin@x'));
select t.login('admin@x');
select t.ok((select created_by=t.uid('op@x') from records where id='v1'),'ADMIN ve la venta, autor = OPERADOR (no se puede falsear created_by)');
select t.ok(t.exp(mza_today())=11000,'esperado = apertura + venta en efectivo');

\echo '— Validaciones'
select t.login('op@x');
select t.fails($$insert into records(kind,id,date,data) values('ventas','v2',mza_today(),'{"medio":"EFECTIVO","total":999,"items":[{"qty":2,"price":500}]}')$$,'no coincide');
select t.fails($$insert into records(kind,id,date,data) values('ventas','v3',mza_today(),'{"medio":"EFECTIVO","total":0,"items":[{"qty":0,"price":500}]}')$$,'inválida');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"medio":"EFECTIVO","type":"DIRECT","amount":0}')$$,'mayor a 0');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"medio":"EFECTIVO","type":"DIRECT","amount":-5}')$$,'mayor a 0');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"medio":"EFECTIVO","type":"DIRECT","amount":"100"}')$$,'mayor a 0');
select t.fails($$insert into records(kind,id,date,data) values('retiros','r0',mza_today(),'{"medio":"EFECTIVO","amount":0}')$$,'mayor a 0');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today()+1,'{"medio":"EFECTIVO","type":"DIRECT","amount":5}')$$,'futura');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',null,'{"medio":"EFECTIVO","type":"DIRECT","amount":5}')$$,'Fecha inválida');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0','1999-01-01','{"medio":"EFECTIVO","type":"DIRECT","amount":5}')$$,'Fecha inválida');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"medio":"EFECTIVO","type":"OTRO","amount":5}')$$,'Tipo de gasto');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"type":"DIRECT","amount":5}')$$,'medio de pago');
select t.fails($$insert into records(kind,id,date,data) values('gastos','g0',mza_today(),'{"medio":"ESTIMADO","type":"INDIRECT","amount":5}')$$,'ESTIMADO');
select t.fails($$insert into records(kind,id,date,data) values('revisiones','x',mza_today(),'{}')$$,'sistema');

\echo '— B/C/D) gasto efectivo baja caja; transferencia no; retiro baja caja y no es gasto'
insert into records(kind,id,date,data) values('gastos','g1',mza_today(),'{"medio":"EFECTIVO","type":"DIRECT","amount":200,"desc":"x"}');
select t.ok(t.exp(mza_today())=10800,'B gasto en efectivo baja el esperado');
insert into records(kind,id,date,data) values('gastos','g2',mza_today(),'{"medio":"TRANSFERENCIA","type":"INDIRECT","amount":300,"desc":"y"}');
select t.ok(t.exp(mza_today())=10800,'C gasto por transferencia no cambia el efectivo');
insert into records(kind,id,date,data) values('retiros','r1',mza_today(),'{"medio":"EFECTIVO","amount":100,"person":"p"}');
select t.ok(t.exp(mza_today())=10700,'D retiro en efectivo baja el esperado');
select t.ok((select count(*) from records where kind='gastos' and data->>'desc' is null)=0,'D el retiro no se guarda como gasto');

\echo '— E) combustible estimado: entra al resultado, no toca efectivo'
select t.fails($$insert into records(kind,id,date,data) values('viajes','t0',mza_today(),'{"ini":100,"dest":150,"ret":200,"km":100,"l":10,"cost":5,"consumo":0.1,"precio":1000}')$$,'Cálculo de combustible');
select t.fails($$insert into records(kind,id,date,data) values('viajes','t0',mza_today(),'{"ini":200,"dest":150,"ret":100,"km":-100,"l":-10,"cost":-10000,"consumo":0.1,"precio":1000}')$$,'Kilometraje');
-- viaje y gasto en un solo INSERT (atómico)
insert into records(kind,id,date,data) values
 ('viajes','t1',mza_today(),'{"ini":100,"dest":150,"ret":200,"km":100,"l":10,"cost":10000,"consumo":0.1,"precio":1000}'),
 ('gastos','comb-t1',mza_today(),'{"medio":"ESTIMADO","type":"INDIRECT","estimated":true,"trip":"t1","amount":10000,"desc":"Combustible estimado"}');
select t.ok(t.exp(mza_today())=10700,'E el combustible estimado no cambia el efectivo');
select t.ok((select sum((data->>'amount')::numeric) from records where kind='gastos' and not deleted)=10500,'E el combustible estimado entra a los gastos del resultado');
select t.fails($$insert into records(kind,id,date,data) values('gastos','comb-x',mza_today(),'{"medio":"ESTIMADO","type":"INDIRECT","estimated":true,"trip":"t1","amount":1}')$$,'sin viaje válido');

\echo '— H) compra suma stock y mueve caja/banco según medio'
select t.login('admin@x');
insert into records(kind,id,data) values('inventario','i1','{"name":"Harina","unit":"kg","stock0":0,"min":20}');
select t.login('op@x');
select t.fails($$insert into records(kind,id,date,data) values('compras','c0',mza_today(),'{"medio":"EFECTIVO","item":"nada","qty":1,"amount":1}')$$,'Ítem');
select t.fails($$insert into records(kind,id,date,data) values('compras','c0',mza_today(),'{"medio":"EFECTIVO","item":"i1","qty":0,"amount":1}')$$,'cantidad');
insert into records(kind,id,date,data) values('compras','c1',mza_today(),'{"medio":"EFECTIVO","item":"i1","qty":10,"amount":1000}');
select t.ok(t.exp(mza_today())=9700,'H compra en efectivo baja el esperado');
insert into records(kind,id,date,data) values('compras','c2',mza_today(),'{"medio":"TRANSFERENCIA","item":"i1","qty":5,"amount":500}');
select t.ok(t.exp(mza_today())=9700,'H compra por transferencia no toca el efectivo');
select t.ok((select sum((data->>'qty')::numeric) from records where kind='compras' and data->>'item'='i1')=15,'H el stock suma las compras');

\echo '— Solo soft delete; el OPERADOR no edita ni borra lo ajeno'
select t.fails($$delete from records where id='g1'$$,'permission denied');
select t.fails($$update records set data=data||'{"amount":1}' where kind='gastos' and id='g1'$$,'No se pueden editar');
select t.login('op2@x');
select t.ok((select count(*) from records)=0,'OPERADOR no activado no ve nada');
select t.login('admin@x'); update profiles set active=true where name='op2@x';
select t.login('op2@x');
select t.fails($$update records set deleted=true where kind='gastos' and id='g1'$$,'lo que cargaste hoy');
select t.login('op@x');
update records set deleted=true where kind='gastos' and id='g2';
select t.ok((select deleted from records where id='g2'),'OPERADOR borra (lógico) lo propio de hoy');
select t.fails($$update records set deleted=false where kind='gastos' and id='g2'$$,'restaurar');
update records set deleted=true where kind='viajes' and id='t1';
select t.ok((select deleted from records where kind='gastos' and id='comb-t1'),'anular un viaje anula su gasto estimado');

\echo '— F) arqueo: el esperado lo calcula la base; venta modificada → REQUIERE REVISIÓN; solo ADMIN recalcula'
insert into records(kind,id,date,data) values('cierres',mza_today()::text,mza_today(),'{"counted":9700,"expected":1,"diff":0}');
select t.ok((select (data->>'expected')::numeric=9700 and (data->>'diff')::numeric=0 and data->>'review'='false' from records where kind='cierres'),'esperado del cierre calculado en la base (ignora el del navegador)');
select t.fails($$insert into records(kind,id,date,data) values('ventas','v9',mza_today(),'{"medio":"EFECTIVO","total":500,"items":[{"qty":1,"price":500}]}')$$,'cerrado');
select t.fails($$update records set deleted=true where kind='ventas' and id='v1'$$,'cerrado');
select t.fails($$update records set data=data||'{"recalc":true}' where kind='cierres'$$,'Solo un ADMIN');
select t.login('admin@x');
update records set deleted=true where kind='ventas' and id='v1';
select t.ok((select data->>'review'='true' from records where kind='cierres'),'venta anulada después del cierre → REQUIERE REVISIÓN');
update records set data=data||'{"recalc":true}' where kind='cierres';
select t.ok((select (data->>'expected')::numeric=9700 and (data->>'expected_rev')::numeric=8700 and data->>'review'='false' and (data->>'diff')::numeric=1000 from records where kind='cierres'),'ADMIN recalcula: conserva el esperado al cierre y guarda el nuevo');
select t.ok((select count(*) from records where kind='revisiones')=1,'el recálculo queda registrado');

\echo '— G) dos aperturas del mismo día: la segunda falla'
select t.fails($$insert into records(kind,id,date,data) values('aperturas',mza_today()::text,mza_today(),'{"open":1}')$$,'duplicate key');
select t.fails($$insert into records(kind,id,date,data) values('aperturas','otra',mza_today(),'{"open":1}')$$,'id debe ser la fecha');

\echo '— J) comprobantes: bucket privado, cada uno sube a su carpeta, solo usuarios activos leen'
reset role;
select t.ok((select not public from storage.buckets where id='comprobantes'),'bucket privado');
set role authenticated; select t.login('op@x');
insert into storage.objects(bucket_id,name) values('comprobantes',auth.uid()||'/a.pdf');
select t.fails($$insert into storage.objects(bucket_id,name) values('comprobantes','otro/a.pdf')$$,'row-level security');
select t.ok((select count(*) from storage.objects)=1,'usuario activo ve el comprobante');
select t.login('admin@x'); update profiles set active=false where name='op2@x';
select t.login('op2@x');
select t.ok((select count(*) from storage.objects)=0,'usuario desactivado no ve comprobantes');
select t.fails($$insert into storage.objects(bucket_id,name) values('comprobantes',auth.uid()||'/b.pdf')$$,'row-level security');
reset role; set role anon; select t.login('');
select t.ok((select count(*) from storage.objects)=0,'sin sesión no se ven comprobantes');
select t.fails($$select * from records$$,'permission denied');
select t.fails($$select * from profiles$$,'permission denied');
reset role;
select t.ok(mza_today()=(now() at time zone 'America/Argentina/Mendoza')::date,'"hoy" en hora de Mendoza');
\echo 'SQL: TODOS OK'
