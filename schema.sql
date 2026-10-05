-- CARRITO · Supabase. Pegar completo en SQL Editor y ejecutar (se puede re-ejecutar: no borra datos).
-- El PRIMER usuario que se registre queda ADMIN activo; los demás quedan OPERADOR inactivo hasta que un ADMIN los active (Config > Usuarios).
-- Todas las reglas de negocio se validan acá (trigger records_guard); el navegador solo repite las validaciones para dar mensajes rápidos.
-- "Hoy" = fecha de America/Argentina/Mendoza.

-- ───────────── utilidades ─────────────
create or replace function public.mza_today() returns date language sql stable set search_path=public as
$$ select (now() at time zone 'America/Argentina/Mendoza')::date $$;
-- número desde jsonb; null si falta o no es numérico (evita errores de conversión en inglés)
create or replace function public.jnum(j jsonb, k text) returns numeric language plpgsql immutable set search_path=public as
$$ begin if jsonb_typeof(j->k)<>'number' then return null; end if; return (j->>k)::numeric; end $$;
create or replace function public.jtxt(j jsonb, k text) returns text language sql immutable set search_path=public as
$$ select nullif(btrim(coalesce(j->>k,'')),'') $$;

-- ───────────── usuarios ─────────────
create table if not exists public.profiles(
  id uuid primary key references auth.users on delete cascade, name text,
  role text not null default 'OPERADOR' check(role in('ADMIN','OPERADOR')),
  active boolean not null default false, created_at timestamptz default now());
create or replace function public.is_active() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and active) $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and active and role='ADMIN') $$;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare first_user boolean;
begin
  perform pg_advisory_xact_lock(hashtext('carrito_first_user'));   -- dos registros simultáneos no pueden ser ambos "el primero"
  first_user := not exists(select 1 from profiles);
  insert into profiles(id,name,role,active) values(new.id,new.email,case when first_user then 'ADMIN' else 'OPERADOR' end,first_user);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.profiles_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.id:=old.id; new.created_at:=old.created_at;
  if not (new.role='ADMIN' and new.active) and not exists(select 1 from profiles where role='ADMIN' and active and id<>old.id) then
    raise exception 'Debe quedar al menos un ADMIN activo';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles for each row execute function public.profiles_guard();

alter table public.profiles enable row level security;
drop policy if exists p_sel on public.profiles; drop policy if exists p_upd on public.profiles;
create policy p_sel on public.profiles for select to authenticated using (id=auth.uid() or is_admin());   -- un OPERADOR solo ve su propio perfil
create policy p_upd on public.profiles for update to authenticated using (is_admin()) with check (is_admin());
revoke all on public.profiles from anon;
revoke insert, delete, truncate on public.profiles from authenticated;

-- ───────────── registros ─────────────
create table if not exists public.records(
  kind text not null,
  id text not null, date date, data jsonb not null default '{}', deleted boolean not null default false,
  created_at timestamptz default now(), updated_at timestamptz default now(), created_by uuid, updated_by uuid,
  primary key(kind,id));   -- aperturas/cierres usan id = fecha → unicidad real por fecha (dos aperturas simultáneas: una falla con 23505)
alter table public.records drop constraint if exists records_kind_check;
alter table public.records add constraint records_kind_check check(kind in('ventas','gastos','retiros','viajes','aperturas','cierres','productos','futuros','config','compras','inventario','ajustes','revisiones'));
create index if not exists records_kind_date_idx on public.records(kind,date);
create index if not exists records_updated_idx on public.records(updated_at);

-- Efectivo esperado = apertura + ventas EFECTIVO − gastos, compras y retiros EFECTIVO (null si no hubo apertura)
create or replace function public.expected_cash(d date) returns numeric language sql stable security definer set search_path=public as $$
  select (select jnum(data,'open') from records where kind='aperturas' and id=d::text and not deleted)
       + coalesce(sum(case when kind='ventas' then jnum(data,'total') else -jnum(data,'amount') end),0)
  from records where date=d and not deleted and data->>'medio'='EFECTIVO' and kind in('ventas','gastos','compras','retiros') $$;

create or replace function public.records_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare
  adm boolean; d jsonb; today date := mza_today(); x numeric; v record;
  mov text[] := array['ventas','gastos','retiros','compras','viajes','ajustes','aperturas','cierres'];
  closable text[] := array['ventas','gastos','retiros','compras','viajes'];
  ign text[] := array['updated_at','updated_by','deleted'];
begin
  -- actualizaciones internas hechas por records_after (marcar arqueo / anular gasto de combustible)
  if pg_trigger_depth()>1 and current_setting('carrito.interno',true)='1' then return new; end if;
  if not is_active() then raise exception 'No autorizado: tu usuario no está activo'; end if;
  adm := is_admin();
  if tg_op='INSERT' then new.created_by:=auth.uid(); new.created_at:=now(); new.deleted:=coalesce(new.deleted,false);
  else new.kind:=old.kind; new.id:=old.id; new.created_by:=old.created_by; new.created_at:=old.created_at; end if;
  new.updated_at:=now(); new.updated_by:=auth.uid();
  if new.data is null or jsonb_typeof(new.data)<>'object' then raise exception 'Datos inválidos'; end if;
  -- la fecha de la columna es la verdad; se copia al JSON
  if new.date is not null then new.data := new.data || jsonb_build_object('date',new.date::text); end if;
  d := new.data;

  if new.kind='revisiones' then raise exception 'Las revisiones de arqueo las genera el sistema'; end if;
  if new.kind in('productos','config','inventario','futuros') and not adm then raise exception 'Solo un ADMIN puede modificar esto'; end if;
  if new.kind not in('productos','config','inventario') and new.date is null then raise exception 'Fecha inválida'; end if;
  if new.kind = any(mov) then
    if new.date>today then raise exception 'La fecha no puede ser futura'; end if;
    if new.date<date '2020-01-01' then raise exception 'Fecha inválida'; end if;
  end if;

  -- borrado: solo lógico; un OPERADOR solo borra lo propio de hoy y no puede editar ni restaurar
  if tg_op='UPDATE' and not adm then
    if new.kind in('aperturas','cierres') then raise exception 'Solo un ADMIN puede modificar caja/arqueos'; end if;
    if old.created_by is distinct from auth.uid() or old.date is distinct from today then raise exception 'Solo podés borrar lo que cargaste hoy'; end if;
    if (new.data - ign) is distinct from (old.data - ign) or new.date is distinct from old.date then raise exception 'No se pueden editar movimientos: borralo y cargalo de nuevo'; end if;
    if old.deleted and not new.deleted then raise exception 'Solo un ADMIN puede restaurar registros'; end if;
  end if;
  -- día cerrado: solo ADMIN carga/modifica movimientos de ese día (y el arqueo queda REQUIERE REVISIÓN)
  if new.kind = any(closable) and not adm and exists(select 1 from records where kind='cierres' and id in(new.date::text, (case when tg_op='UPDATE' then old.date::text end)) and not deleted) then
    raise exception 'Ese día ya está cerrado: solo un ADMIN puede modificarlo';
  end if;
  if new.deleted then return new; end if;   -- anular un registro no necesita revalidar su contenido

  if new.kind in('ventas','gastos','retiros','compras') then
    if jtxt(d,'medio') is null then raise exception 'Falta el medio de pago'; end if;
    if (d->>'medio'='ESTIMADO') <> (new.kind='gastos' and coalesce(d->'estimated'='true'::jsonb,false)) then raise exception 'Medio ESTIMADO solo para combustible estimado'; end if;
  end if;
  case new.kind
  when 'aperturas' then
    if new.id<>new.date::text then raise exception 'El id debe ser la fecha'; end if;
    if not adm and new.date<>today then raise exception 'Solo se puede abrir la caja de hoy'; end if;
    if coalesce(jnum(d,'open'),-1)<0 then raise exception 'Efectivo inicial inválido'; end if;
  when 'cierres' then
    if new.id<>new.date::text then raise exception 'El id debe ser la fecha'; end if;
    if not adm and new.date<>today then raise exception 'Solo se puede cerrar la caja de hoy'; end if;
    if coalesce(jnum(d,'counted'),-1)<0 then raise exception 'Efectivo contado inválido'; end if;
    x := expected_cash(new.date);
    if x is null then raise exception 'No hay apertura para esa fecha'; end if;
    if tg_op='INSERT' then   -- el esperado lo calcula la base, no el navegador
      new.data := d || jsonb_build_object('expected',x,'diff',jnum(d,'counted')-x,'closed_at',now(),'review',false) - 'expected_rev' - 'revised_at' - 'revised_by';
    else                      -- recalcular (solo ADMIN): conserva el esperado al cierre y deja registro
      new.data := d || jsonb_build_object('expected',old.data->'expected','closed_at',old.data->'closed_at','expected_rev',x,'diff',jnum(d,'counted')-x,'review',false,'revised_at',now(),'revised_by',auth.uid()) - 'recalc';
      perform set_config('carrito.interno','1',true);
      insert into records(kind,id,date,data,created_by,updated_by) values('revisiones',gen_random_uuid()::text,new.date,
        jsonb_build_object('date',new.date::text,'expected_before',coalesce(old.data->'expected_rev',old.data->'expected'),'expected',x,'at',now(),'by',auth.uid()),auth.uid(),auth.uid());
      perform set_config('carrito.interno','',true);
    end if;
  when 'ventas' then
    if coalesce(jnum(d,'total'),0)<=0 or jsonb_typeof(d->'items') is distinct from 'array' or jsonb_array_length(d->'items')=0 then raise exception 'Venta inválida'; end if;
    if exists(select 1 from jsonb_array_elements(d->'items') i where coalesce(jnum(i,'qty'),0)<=0 or coalesce(jnum(i,'price'),0)<=0) then raise exception 'Cantidades y precios deben ser mayores a 0'; end if;
    if abs(jnum(d,'total')-(select sum(jnum(i,'qty')*jnum(i,'price')) from jsonb_array_elements(d->'items') i))>0.005 then raise exception 'El total no coincide con los ítems'; end if;
  when 'gastos' then
    if coalesce(jnum(d,'amount'),0)<=0 then raise exception 'El importe debe ser mayor a 0'; end if;
    if coalesce(d->>'type','') not in('DIRECT','INDIRECT') then raise exception 'Tipo de gasto inválido'; end if;
    if coalesce(d->'estimated'='true'::jsonb,false) then   -- combustible estimado: debe coincidir con un viaje
      select * into v from records where kind='viajes' and id=d->>'trip' and not deleted;
      if not found or v.date<>new.date or abs(jnum(v.data,'cost')-jnum(d,'amount'))>0.01 or d->>'type'<>'INDIRECT' then raise exception 'Gasto estimado sin viaje válido'; end if;
    end if;
  when 'retiros' then
    if coalesce(jnum(d,'amount'),0)<=0 then raise exception 'El importe debe ser mayor a 0'; end if;
  when 'compras' then
    if coalesce(jnum(d,'amount'),0)<=0 then raise exception 'El importe debe ser mayor a 0'; end if;
    if coalesce(jnum(d,'qty'),0)<=0 then raise exception 'La cantidad debe ser mayor a 0'; end if;
    if not exists(select 1 from records where kind='inventario' and id=d->>'item' and not deleted) then raise exception 'Ítem de stock inválido'; end if;
  when 'ajustes' then
    if coalesce(jnum(d,'delta'),0)=0 then raise exception 'El ajuste debe ser distinto de 0'; end if;
    if not exists(select 1 from records where kind='inventario' and id=d->>'item' and not deleted) then raise exception 'Ítem de stock inválido'; end if;
  when 'viajes' then   -- km total = vuelta − inicio; litros = km × consumo; costo = litros × precio
    if not (jnum(d,'ini')>=0 and jnum(d,'dest')>=jnum(d,'ini') and jnum(d,'ret')>=jnum(d,'dest') and jnum(d,'ret')>jnum(d,'ini')) then raise exception 'Kilometraje inválido'; end if;
    if not (jnum(d,'consumo')>0 and jnum(d,'precio')>0) then raise exception 'Consumo y precio deben ser mayores a 0'; end if;
    if abs(jnum(d,'km')-(jnum(d,'ret')-jnum(d,'ini')))>0.001 or abs(jnum(d,'l')-jnum(d,'km')*jnum(d,'consumo'))>0.001
       or abs(jnum(d,'cost')-round(jnum(d,'km')*jnum(d,'consumo')*jnum(d,'precio'),2))>0.01 then raise exception 'Cálculo de combustible inválido'; end if;
  when 'futuros' then
    if coalesce(jnum(d,'amount'),0)<=0 then raise exception 'El importe debe ser mayor a 0'; end if;
    if coalesce(d->>'kind','') not in('GASTO','COMPRA','SUELDO','RETIRO','INGRESO') or coalesce(d->>'freq','') not in('ONCE','WEEKLY','MONTHLY') then raise exception 'Tipo o frecuencia inválidos'; end if;
  when 'productos' then
    if jtxt(d,'name') is null then raise exception 'Falta el nombre'; end if;
    if coalesce(jnum(d,'price'),0)<=0 then raise exception 'El precio debe ser mayor a 0'; end if;
  when 'inventario' then
    if jtxt(d,'name') is null or coalesce(jnum(d,'stock0'),-1)<0 or coalesce(jnum(d,'min'),-1)<0 then raise exception 'Ítem de stock inválido'; end if;
  when 'config' then
    if new.id<>'main' then raise exception 'Configuración inválida'; end if;
    if coalesce(jnum(d,'consumo'),-1)<0 or coalesce(jnum(d,'precio'),-1)<0 or coalesce(jnum(d,'capital'),-1)<0 then raise exception 'Valores de configuración inválidos'; end if;
  else null;
  end case;
  return new;
end $$;
drop trigger if exists records_guard on public.records;
create trigger records_guard before insert or update on public.records for each row execute function public.records_guard();

-- Después de guardar: arqueo cerrado → REQUIERE REVISIÓN si cambia un movimiento de ese día; anular viaje anula su gasto estimado
create or replace function public.records_after() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and new.data is not distinct from old.data and new.deleted=old.deleted and new.date is not distinct from old.date then return null; end if;
  perform set_config('carrito.interno','1',true);
  update records set data=data||'{"review":true}' where kind='cierres' and not deleted and coalesce(data->'review'='true'::jsonb,false)=false
    and id in(new.date::text, (case when tg_op='UPDATE' then old.date::text end));
  if new.kind='viajes' and new.deleted then
    update records set deleted=true, updated_at=now(), updated_by=auth.uid() where kind='gastos' and data->>'trip'=new.id and not deleted;
  end if;
  perform set_config('carrito.interno','',true);
  return null;
end $$;
drop trigger if exists records_after on public.records;
create trigger records_after after insert or update on public.records for each row
  when (new.kind in('ventas','gastos','retiros','compras','viajes')) execute function public.records_after();

alter table public.records enable row level security;   -- sin policy de DELETE: no se puede borrar, solo soft delete
drop policy if exists r_sel on public.records; drop policy if exists r_ins on public.records; drop policy if exists r_upd on public.records;
create policy r_sel on public.records for select to authenticated using (is_active());
create policy r_ins on public.records for insert to authenticated with check (is_active());
create policy r_upd on public.records for update to authenticated using (is_active()) with check (is_active());
revoke all on public.records from anon;
revoke delete, truncate on public.records from authenticated;
-- funciones internas: no se exponen como RPC
revoke execute on function public.records_guard(), public.records_after(), public.handle_new_user(), public.profiles_guard() from public, anon, authenticated;
revoke execute on function public.expected_cash(date) from public, anon, authenticated;

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='records') then
    alter publication supabase_realtime add table public.records;
  end if;
end $$;

-- ───────────── comprobantes (bucket privado: solo URL firmada con sesión activa) ─────────────
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('comprobantes','comprobantes',false,5242880,array['image/jpeg','image/png','application/pdf'])
  on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists c_sel on storage.objects; drop policy if exists c_ins on storage.objects;
create policy c_sel on storage.objects for select to authenticated using (bucket_id='comprobantes' and public.is_active());
create policy c_ins on storage.objects for insert to authenticated with check (bucket_id='comprobantes' and public.is_active() and (storage.foldername(name))[1]=auth.uid()::text);
