-- CARRITO · Supabase. Pegar completo en SQL Editor y ejecutar una vez.
-- El PRIMER usuario que se registre queda ADMIN activo; los demás quedan OPERADOR inactivo hasta que un ADMIN los active (Config > Usuarios).
create table profiles(id uuid primary key references auth.users on delete cascade, name text, role text not null default 'OPERADOR' check(role in('ADMIN','OPERADOR')), active boolean not null default false, created_at timestamptz default now());
create function is_active() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and active) $$;
create function is_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and active and role='ADMIN') $$;
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare first_user boolean := not exists(select 1 from profiles);
begin insert into profiles(id,name,role,active) values(new.id,new.email,case when first_user then 'ADMIN' else 'OPERADOR' end,first_user); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();
alter table profiles enable row level security;
create policy p_sel on profiles for select to authenticated using (id=auth.uid() or is_active());
create policy p_upd on profiles for update to authenticated using (is_admin()) with check (is_admin());

create table records(
  kind text not null check(kind in('ventas','gastos','retiros','viajes','aperturas','cierres','productos','futuros','config','compras','inventario','ajustes')),
  id text not null, date date, data jsonb not null default '{}', deleted boolean not null default false,
  created_at timestamptz default now(), updated_at timestamptz default now(), created_by uuid, updated_by uuid,
  primary key(kind,id));   -- aperturas/cierres usan id = fecha → unicidad real por fecha
create index on records(kind,date);

create function records_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare adm boolean := is_admin(); d jsonb := new.data; today date := (now() at time zone 'America/Argentina/Mendoza')::date; ign text[] := array['updated_at','updated_by','deleted'];
begin
 if not is_active() then raise exception 'No autorizado'; end if;
 if tg_op='INSERT' then new.created_by:=auth.uid(); new.created_at:=now();
 else new.kind:=old.kind; new.id:=old.id; new.created_by:=old.created_by; new.created_at:=old.created_at; end if;
 new.updated_at:=now(); new.updated_by:=auth.uid();
 if new.kind in('productos','config','inventario','futuros') and not adm then raise exception 'Solo un ADMIN puede modificar esto'; end if;
 if new.kind not in('productos','config','inventario') and new.date is null then raise exception 'Fecha inválida'; end if;
 if new.kind in('aperturas','cierres') then
   if new.id<>new.date::text then raise exception 'El id debe ser la fecha'; end if;
   if tg_op='UPDATE' and not adm then raise exception 'Solo un ADMIN puede modificar caja/arqueos'; end if;
   if new.kind='aperturas' and coalesce((d->>'open')::numeric,-1)<0 then raise exception 'Efectivo inicial inválido'; end if;
   if new.kind='cierres' then
     if coalesce((d->>'counted')::numeric,-1)<0 then raise exception 'Efectivo contado inválido'; end if;
     if tg_op='INSERT' and not exists(select 1 from records where kind='aperturas' and id=new.id and not deleted) then raise exception 'No hay apertura para esa fecha'; end if;
   end if;
 end if;
 if new.kind in('gastos','retiros','compras','futuros') and coalesce((d->>'amount')::numeric,0)<=0 then raise exception 'El importe debe ser mayor a 0'; end if;
 if new.kind='compras' and coalesce((d->>'qty')::numeric,0)<=0 then raise exception 'La cantidad debe ser mayor a 0'; end if;
 if new.kind='productos' and coalesce((d->>'price')::numeric,0)<=0 then raise exception 'El precio debe ser mayor a 0'; end if;
 if new.kind='ventas' then
   if coalesce((d->>'total')::numeric,0)<=0 or jsonb_typeof(d->'items')<>'array' or jsonb_array_length(d->'items')=0 then raise exception 'Venta inválida'; end if;
   if exists(select 1 from jsonb_array_elements(d->'items') i where coalesce((i->>'qty')::numeric,0)<=0 or coalesce((i->>'price')::numeric,0)<=0) then raise exception 'Cantidades y precios deben ser mayores a 0'; end if;
   if abs((d->>'total')::numeric-(select sum((i->>'qty')::numeric*(i->>'price')::numeric) from jsonb_array_elements(d->'items') i))>0.005 then raise exception 'El total no coincide con los ítems'; end if;
 end if;
 if new.kind in('ventas','gastos','retiros','compras') and not adm and exists(select 1 from records where kind='cierres' and id=new.date::text and not deleted) then raise exception 'Ese día ya está cerrado: solo un ADMIN puede modificarlo'; end if;
 if tg_op='UPDATE' and not adm then
   if old.created_by is distinct from auth.uid() or old.date is distinct from today then raise exception 'Solo podés borrar lo que cargaste hoy'; end if;
   if (new.data - ign) is distinct from (old.data - ign) or new.date is distinct from old.date then raise exception 'No se pueden editar movimientos'; end if;
 end if;
 return new;
end $$;
create trigger records_guard before insert or update on records for each row execute function records_guard();
alter table records enable row level security;   -- sin policy de DELETE: no se puede borrar, solo soft delete
create policy r_sel on records for select to authenticated using (is_active());
create policy r_ins on records for insert to authenticated with check (is_active());
create policy r_upd on records for update to authenticated using (is_active()) with check (is_active());
alter publication supabase_realtime add table records;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('comprobantes','comprobantes',false,5242880,array['image/jpeg','image/png','application/pdf']);
create policy c_sel on storage.objects for select to authenticated using (bucket_id='comprobantes' and is_active());
create policy c_ins on storage.objects for insert to authenticated with check (bucket_id='comprobantes' and is_active());

