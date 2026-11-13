-- =====================================================================
--  KPL AGRO · Esquema de Supabase
--  Ejecuta este archivo completo en Supabase → SQL Editor → Run.
--  Se puede ejecutar más de una vez sin dañar datos.
-- =====================================================================

-- 1) Tabla única: cada registro guarda un documento (producto, factura, cliente…)
create table if not exists public.registros (
  coleccion  text        not null,
  id         text        not null,
  data       jsonb       not null,
  updated_at timestamptz not null default now(),
  primary key (coleccion, id)
);
create index if not exists registros_coleccion_idx on public.registros (coleccion);
create index if not exists registros_email_idx on public.registros ((lower(data->>'email'))) where coleccion = 'usuarios';

-- Para que el tiempo real envíe la fila completa también al borrar
alter table public.registros replica identity full;

-- 2) Funciones de apoyo para los permisos (leen el perfil del usuario conectado)
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select data->>'rol'
  from public.registros
  where coleccion = 'usuarios'
    and lower(data->>'email') = lower(auth.jwt()->>'email')
    and coalesce((data->>'activo')::boolean, true)
  limit 1;
$$;

create or replace function public.sin_usuarios() returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.registros where coleccion = 'usuarios');
$$;

-- ¿El rol del usuario conectado tiene este permiso? (el Propietario siempre sí)
create or replace function public.tiene_permiso(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.mi_rol() = 'Propietario'
      or exists (select 1 from public.registros r
                 where r.coleccion = 'roles'
                   and r.data->>'nombre' = public.mi_rol()
                   and (r.data->'permisos') ? p);
$$;

-- Regla de escritura compartida por crear y modificar
create or replace function public.puede_escribir(col text, d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select
    -- Documentos del negocio: cualquier usuario activo
    (public.mi_rol() is not null and col not in ('usuarios', 'roles', 'config'))
    -- Usuarios y roles: quien tenga el permiso; solo un propietario toca propietarios o el rol del sistema
    or (col in ('usuarios', 'roles') and public.tiene_permiso('usuarios')
        and (public.mi_rol() = 'Propietario'
             or (coalesce(d->>'rol', '') <> 'Propietario' and coalesce((d->>'sistema')::boolean, false) = false)))
    -- Configuración de la empresa
    or (col = 'config' and public.tiene_permiso('config'))
    -- Arranque: el primer usuario se registra como propietario
    or (col = 'usuarios' and public.sin_usuarios()
        and lower(d->>'email') = lower(auth.jwt()->>'email') and d->>'rol' = 'Propietario');
$$;

-- 3) Seguridad por filas (RLS)
alter table public.registros enable row level security;

drop policy if exists "leer"       on public.registros;
drop policy if exists "crear"      on public.registros;
drop policy if exists "modificar"  on public.registros;
drop policy if exists "eliminar"   on public.registros;

create policy "leer" on public.registros for select to authenticated
  using (public.mi_rol() is not null or public.sin_usuarios());

create policy "crear" on public.registros for insert to authenticated
  with check (public.puede_escribir(coleccion, data));

create policy "modificar" on public.registros for update to authenticated
  using (public.puede_escribir(coleccion, data))
  with check (public.puede_escribir(coleccion, data));

-- Eliminar: quien tenga el permiso "Eliminar registros"; usuarios, roles y configuración además requieren "Usuarios y roles"
create policy "eliminar" on public.registros for delete to authenticated
  using (public.tiene_permiso('eliminar')
         and (coleccion not in ('usuarios', 'roles', 'config') or public.tiene_permiso('usuarios')));

-- 4) Tiempo real: cambios visibles al instante en todos los dispositivos
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'registros'
  ) then
    alter publication supabase_realtime add table public.registros;
  end if;
end $$;

-- 5) Existencias atómicas: suma o resta stock dentro de una transacción,
--    con bloqueo de fila, para que dos ventas simultáneas no se pisen.
create or replace function public.mover_stock(items jsonb, permitir_negativo boolean default false)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  it jsonb; d jsonb; st numeric; co numeric; dl numeric; cu numeric; res jsonb := '[]'::jsonb;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  for it in select * from jsonb_array_elements(items) loop
    select data into d from public.registros where coleccion = 'productos' and id = it->>'id' for update;
    if d is null then raise exception 'Producto no encontrado: %', it->>'id'; end if;
    st := coalesce((d->>'stock')::numeric, 0);
    co := coalesce((d->>'costo')::numeric, 0);
    dl := (it->>'delta')::numeric;
    cu := nullif(it->>'costo', '')::numeric;
    if not permitir_negativo and st + dl < 0 then
      raise exception 'STOCK_INSUFICIENTE:%:%', d->>'nombre', st;
    end if;
    if cu is not null and dl > 0 then
      co := round((greatest(st, 0) * co + dl * cu) / nullif(greatest(st, 0) + dl, 0), 2);
    end if;
    d := jsonb_set(d, '{stock}', to_jsonb(round(st + dl, 3)));
    d := jsonb_set(d, '{costo}', to_jsonb(co));
    d := jsonb_set(d, '{updated}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
    update public.registros set data = d, updated_at = now() where coleccion = 'productos' and id = it->>'id';
    res := res || jsonb_build_array(jsonb_build_object('id', it->>'id', 'stock', d->'stock', 'costo', d->'costo'));
  end loop;
  return res;
end $$;

-- 6) Numeración NCF / e-CF atómica: entrega el siguiente número de una secuencia
create or replace function public.tomar_ncf(seq_id text)
returns bigint language plpgsql security invoker set search_path = public as $$
declare d jsonb; n bigint;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  select data into d from public.registros where coleccion = 'ncf' and id = seq_id for update;
  if d is null then raise exception 'Secuencia no encontrada'; end if;
  n := (d->>'actual')::bigint;
  if n > (d->>'hasta')::bigint then raise exception 'La secuencia % está agotada', d->>'tipo'; end if;
  if coalesce(d->>'vence', '') <> '' and (d->>'vence')::date < current_date then raise exception 'La secuencia % está vencida', d->>'tipo'; end if;
  d := jsonb_set(d, '{actual}', to_jsonb(n + 1));
  d := jsonb_set(d, '{updated}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
  update public.registros set data = d, updated_at = now() where coleccion = 'ncf' and id = seq_id;
  return n;
end $$;

grant execute on function public.mover_stock(jsonb, boolean) to authenticated;
grant execute on function public.tomar_ncf(text) to authenticated;
