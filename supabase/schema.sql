-- =====================================================================
--  KPL AGRO · Base de datos completa (Supabase / PostgreSQL 15+)
--  Sistema de ventas, inventario y exportación · SP BJ SOFTWARE
--
--  Cómo usarlo: Supabase → SQL Editor → pega todo el archivo → Run.
--  Se puede ejecutar más de una vez: no borra datos.
--
--  Qué guarda: TODO lo del negocio (productos, clientes, proveedores,
--  facturas, pagos, cotizaciones, compras, notas de crédito, órdenes de
--  trabajo, lotes, listas de precios, gastos, presupuestos, ajustes,
--  cierres de caja, secuencias NCF, usuarios, roles, bitácora y la
--  configuración de la empresa). En el navegador solo quedan
--  preferencias del dispositivo (tema claro/oscuro, filas por página).
--
--  Trabajo simultáneo:
--   · guardar()      → cada registro tiene versión; si dos personas editan
--                      lo mismo a la vez, el segundo recibe CONFLICTO en
--                      lugar de borrar el cambio del primero.
--   · mover_stock()  → existencias con bloqueo de fila (sin sobreventas).
--   · mover_lotes()  → lotes PEPS con bloqueo de fila.
--   · tomar_numero() → números de factura, compra, cotización, nota y OT
--                      sin repetirse.
--   · tomar_ncf()    → NCF / e-CF sin repetirse.
--   · Realtime       → todos ven los cambios al instante.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) TABLAS
-- ---------------------------------------------------------------------

-- Todos los documentos del sistema. "coleccion" indica el tipo:
-- productos, clientes, proveedores, ventas, compras, cotizaciones, notas,
-- ordenes, lotes, listas, gastos, presupuestos, ajustes, cajas, ncf,
-- usuarios, roles, bitacora, config.
create table if not exists public.registros (
  coleccion  text        not null,
  id         text        not null,
  data       jsonb       not null,
  updated_at timestamptz not null default now(),
  primary key (coleccion, id)
);
create index if not exists registros_coleccion_idx on public.registros (coleccion);
create index if not exists registros_updated_idx   on public.registros (updated_at desc);
create index if not exists registros_email_idx     on public.registros ((lower(data->>'email'))) where coleccion = 'usuarios';
create index if not exists registros_rolnom_idx    on public.registros ((data->>'nombre')) where coleccion = 'roles';
create index if not exists registros_lotes_idx     on public.registros ((data->>'productoId')) where coleccion = 'lotes';
create index if not exists registros_fecha_idx     on public.registros (coleccion, (data->>'fecha'));

-- Para que el tiempo real envíe la fila completa también al borrar
alter table public.registros replica identity full;

-- Contadores de numeración (facturas, compras, cotizaciones, notas, OT)
create table if not exists public.contadores (
  coleccion text   primary key,
  ultimo    bigint not null
);


-- ---------------------------------------------------------------------
-- 2) FUNCIONES DE PERMISOS
-- ---------------------------------------------------------------------

-- Rol del usuario conectado (null si no tiene perfil activo)
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select data->>'rol'
  from public.registros
  where coleccion = 'usuarios'
    and lower(data->>'email') = lower(auth.jwt()->>'email')
    and coalesce((data->>'activo')::boolean, true)
  limit 1;
$$;

-- ¿Todavía no hay usuarios? (permite que el primero se registre como propietario)
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


-- ---------------------------------------------------------------------
-- 3) SEGURIDAD POR FILAS (RLS)
-- ---------------------------------------------------------------------
alter table public.registros  enable row level security;
alter table public.contadores enable row level security;   -- solo se usa a través de tomar_numero()

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

-- Eliminar: quien tenga "Eliminar registros"; usuarios, roles y configuración además requieren "Usuarios y roles"
create policy "eliminar" on public.registros for delete to authenticated
  using (public.tiene_permiso('eliminar')
         and (coleccion not in ('usuarios', 'roles', 'config') or public.tiene_permiso('usuarios')));


-- ---------------------------------------------------------------------
-- 4) GUARDADO CON CONTROL DE VERSIÓN (trabajo simultáneo seguro)
--    p_ver = versión que la persona tenía en pantalla (0 si es nuevo).
--    Si en la base ya hay otra versión, devuelve CONFLICTO y no pisa nada.
-- ---------------------------------------------------------------------
create or replace function public.guardar(p_col text, p_id text, p_data jsonb, p_ver integer)
returns integer language plpgsql security invoker set search_path = public as $$
declare actual integer; existe boolean;
begin
  if public.mi_rol() is null and not (p_col = 'usuarios' and public.sin_usuarios()) then
    raise exception 'Sin permiso';
  end if;
  select coalesce((data->>'v')::integer, 0), true into actual, existe
    from public.registros where coleccion = p_col and id = p_id for update;
  if existe and actual <> coalesce(p_ver, 0) then
    raise exception 'CONFLICTO: el registro % fue modificado por otra persona (versión % ≠ %)', p_id, actual, p_ver;
  end if;
  if not coalesce(existe, false) and coalesce(p_ver, 0) <> 0 then
    raise exception 'CONFLICTO: el registro % ya no existe', p_id;
  end if;
  p_data := jsonb_set(p_data, '{v}', to_jsonb(coalesce(p_ver, 0) + 1));
  insert into public.registros (coleccion, id, data, updated_at)
       values (p_col, p_id, p_data, now())
  on conflict (coleccion, id) do update set data = excluded.data, updated_at = now();
  return coalesce(p_ver, 0) + 1;
end $$;


-- ---------------------------------------------------------------------
-- 5) EXISTENCIAS ATÓMICAS
--    items: [{ "id": "<producto>", "delta": -5, "costo": 480 }]
--    Si no alcanza el stock, falla todo (STOCK_INSUFICIENTE) y no descuenta nada.
-- ---------------------------------------------------------------------
create or replace function public.mover_stock(items jsonb, permitir_negativo boolean default false)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  it jsonb; d jsonb; st numeric; co numeric; dl numeric; cu numeric; nv integer; res jsonb := '[]'::jsonb;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  -- Bloquea en orden de id para evitar abrazos mortales entre dos ventas
  for it in select value from jsonb_array_elements(items) order by value->>'id' loop
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
    nv := coalesce((d->>'v')::integer, 0) + 1;
    d := jsonb_set(d, '{stock}', to_jsonb(round(st + dl, 3)));
    d := jsonb_set(d, '{costo}', to_jsonb(co));
    d := jsonb_set(d, '{v}', to_jsonb(nv));
    d := jsonb_set(d, '{updated}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
    update public.registros set data = d, updated_at = now() where coleccion = 'productos' and id = it->>'id';
    res := res || jsonb_build_array(jsonb_build_object('id', it->>'id', 'stock', d->'stock', 'costo', d->'costo', 'v', nv));
  end loop;
  return res;
end $$;


-- ---------------------------------------------------------------------
-- 6) LOTES ATÓMICOS (primero en entrar, primero en salir)
--    p_ops: [{ "accion": "consumir", "producto": "<id>", "cant": 10 }]
--           [{ "accion": "devolver", "asig": [{ "id": "<lote>", "cant": 4 }], "cant": 4 }]
--    Devuelve por cada operación: { asig: [{id, codigo, cant}], lotes: [{id, disponible, v}] }
-- ---------------------------------------------------------------------
create or replace function public.mover_lotes(p_ops jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  op jsonb; r record; a jsonb; resto numeric; t numeric; disp numeric; nv integer;
  asig jsonb; lotes jsonb; res jsonb := '[]'::jsonb; d jsonb;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  for op in select value from jsonb_array_elements(p_ops) loop
    asig := '[]'::jsonb; lotes := '[]'::jsonb; resto := coalesce((op->>'cant')::numeric, 0);
    if op->>'accion' = 'consumir' then
      for r in
        select id, data from public.registros
         where coleccion = 'lotes'
           and data->>'productoId' = op->>'producto'
           and coalesce((data->>'disponible')::numeric, 0) > 0
           and not coalesce((data->>'anulado')::boolean, false)
         order by coalesce(data->>'cosecha', data->>'fecha'), data->>'codigo'
         for update
      loop
        exit when resto <= 0;
        disp := (r.data->>'disponible')::numeric;
        t := least(disp, resto); resto := resto - t;
        nv := coalesce((r.data->>'v')::integer, 0) + 1;
        d := jsonb_set(jsonb_set(r.data, '{disponible}', to_jsonb(round(disp - t, 3))), '{v}', to_jsonb(nv));
        update public.registros set data = d, updated_at = now() where coleccion = 'lotes' and id = r.id;
        asig  := asig  || jsonb_build_array(jsonb_build_object('id', r.id, 'codigo', r.data->>'codigo', 'cant', t));
        lotes := lotes || jsonb_build_array(jsonb_build_object('id', r.id, 'disponible', round(disp - t, 3), 'v', nv));
      end loop;
    elsif op->>'accion' = 'devolver' then
      for a in select value from jsonb_array_elements(coalesce(op->'asig', '[]'::jsonb)) loop
        exit when resto <= 0;
        select data into d from public.registros where coleccion = 'lotes' and id = a->>'id' for update;
        continue when d is null;
        t := least((a->>'cant')::numeric, resto); resto := resto - t;
        disp := coalesce((d->>'disponible')::numeric, 0) + t;
        nv := coalesce((d->>'v')::integer, 0) + 1;
        d := jsonb_set(jsonb_set(d, '{disponible}', to_jsonb(round(disp, 3))), '{v}', to_jsonb(nv));
        update public.registros set data = d, updated_at = now() where coleccion = 'lotes' and id = a->>'id';
        lotes := lotes || jsonb_build_array(jsonb_build_object('id', a->>'id', 'disponible', round(disp, 3), 'v', nv));
      end loop;
    end if;
    res := res || jsonb_build_array(jsonb_build_object('asig', asig, 'lotes', lotes));
  end loop;
  return res;
end $$;


-- ---------------------------------------------------------------------
-- 7) NUMERACIÓN DE DOCUMENTOS (sin repetir entre usuarios)
--    La primera vez continúa desde el número más alto que ya exista.
-- ---------------------------------------------------------------------
create or replace function public.tomar_numero(p_col text, p_inicio bigint default 1)
returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  if p_col not in ('ventas', 'compras', 'cotizaciones', 'notas', 'ordenes') then raise exception 'Colección no numerable: %', p_col; end if;
  insert into public.contadores (coleccion, ultimo)
       select p_col, greatest(p_inicio - 1, coalesce(max((data->>'num')::bigint), 0))
         from public.registros where coleccion = p_col
  on conflict (coleccion) do nothing;
  update public.contadores set ultimo = ultimo + 1 where coleccion = p_col returning ultimo into n;
  return n;
end $$;


-- ---------------------------------------------------------------------
-- 8) NCF / e-CF (sin repetir entre usuarios)
-- ---------------------------------------------------------------------
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
  d := jsonb_set(d, '{v}', to_jsonb(coalesce((d->>'v')::integer, 0) + 1));
  d := jsonb_set(d, '{updated}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
  update public.registros set data = d, updated_at = now() where coleccion = 'ncf' and id = seq_id;
  return n;
end $$;

grant execute on function public.guardar(text, text, jsonb, integer) to authenticated;
grant execute on function public.mover_stock(jsonb, boolean)          to authenticated;
grant execute on function public.mover_lotes(jsonb)                   to authenticated;
grant execute on function public.tomar_numero(text, bigint)           to authenticated;
grant execute on function public.tomar_ncf(text)                      to authenticated;


-- ---------------------------------------------------------------------
-- 9) TIEMPO REAL (el propietario ve todo en vivo)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'registros') then
    alter publication supabase_realtime add table public.registros;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 10) VISTAS DE CONSULTA
--     Tablas "normales" para ver, filtrar o exportar los datos desde
--     Supabase (Table Editor / SQL) o conectar Excel, Power BI, etc.
--     Respetan los mismos permisos (security_invoker).
-- ---------------------------------------------------------------------
create or replace view public.v_productos with (security_invoker = true) as
select id, data->>'sku' as sku, data->>'nombre' as nombre, data->>'categoria' as categoria, data->>'unidad' as unidad,
       (data->>'costo')::numeric as costo, (data->>'precio')::numeric as precio,
       (data->>'stock')::numeric as existencia, (data->>'minimo')::numeric as minimo,
       nullif(data->>'pesoKg', '')::numeric as peso_neto_kg, nullif(data->>'pesoBrutoKg', '')::numeric as peso_bruto_kg,
       data->>'hs' as codigo_hs, coalesce((data->>'activo')::boolean, true) as activo, updated_at
  from public.registros where coleccion = 'productos';

create or replace view public.v_clientes with (security_invoker = true) as
select id, data->>'nombre' as nombre, data->>'tipo' as tipo, data->>'rnc' as rnc, data->>'pais' as pais, data->>'ciudad' as ciudad,
       data->>'telefono' as telefono, data->>'email' as correo, data->>'contacto' as contacto,
       data->>'listaId' as lista_precios_id, data->>'tipoNCF' as tipo_ncf, updated_at
  from public.registros where coleccion = 'clientes';

create or replace view public.v_proveedores with (security_invoker = true) as
select id, data->>'nombre' as nombre, data->>'rnc' as rnc, data->>'ciudad' as ciudad, data->>'telefono' as telefono,
       data->>'email' as correo, data->>'suministra' as suministra, data->>'tipo606' as tipo_606, updated_at
  from public.registros where coleccion = 'proveedores';

create or replace view public.v_ventas with (security_invoker = true) as
select r.id, (r.data->>'num')::bigint as numero, (r.data->>'fecha')::date as fecha, r.data->>'ncf' as ncf,
       r.data->>'clienteId' as cliente_id, c.data->>'nombre' as cliente, r.data->>'tipo' as tipo,
       r.data->>'moneda' as moneda, (r.data->>'tasa')::numeric as tasa, r.data->>'condicion' as condicion,
       nullif(r.data->>'vence', '')::date as vence, (r.data->>'subtotal')::numeric as subtotal, (r.data->>'itbis')::numeric as itbis,
       (r.data->>'total')::numeric as total, coalesce((r.data->>'pagado')::numeric, 0) as pagado,
       coalesce((r.data->>'creditos')::numeric, 0) as notas_aplicadas,
       (r.data->>'total')::numeric - coalesce((r.data->>'pagado')::numeric, 0) - coalesce((r.data->>'creditos')::numeric, 0) as saldo,
       r.data->>'estado' as estado, r.data->>'usuario' as vendedor, r.updated_at
  from public.registros r
  left join public.registros c on c.coleccion = 'clientes' and c.id = r.data->>'clienteId'
 where r.coleccion = 'ventas';

create or replace view public.v_ventas_lineas with (security_invoker = true) as
select r.id as venta_id, (r.data->>'num')::bigint as factura, (r.data->>'fecha')::date as fecha, r.data->>'estado' as estado,
       l->>'productoId' as producto_id, l->>'nombre' as producto, (l->>'cant')::numeric as cantidad, l->>'unidad' as unidad,
       (l->>'precio')::numeric as precio, (l->>'cant')::numeric * (l->>'precio')::numeric as importe,
       coalesce((l->>'costo')::numeric, 0) as costo_unitario, coalesce((l->>'devuelto')::numeric, 0) as devuelto, r.data->>'moneda' as moneda
  from public.registros r, jsonb_array_elements(r.data->'lineas') l
 where r.coleccion = 'ventas';

create or replace view public.v_pagos with (security_invoker = true) as
select r.id as venta_id, (r.data->>'num')::bigint as factura, (a->>'fecha')::date as fecha, a->>'metodo' as metodo,
       (a->>'monto')::numeric as monto, r.data->>'moneda' as moneda, a->>'usuario' as usuario
  from public.registros r, jsonb_array_elements(coalesce(r.data->'abonos', '[]'::jsonb)) a
 where r.coleccion = 'ventas' and r.data->>'estado' <> 'Anulada';

drop view if exists public.v_compras;
create or replace view public.v_compras with (security_invoker = true) as
select r.id, (r.data->>'num')::bigint as numero, (r.data->>'fecha')::date as fecha, r.data->>'documento' as ncf_suplidor,
       r.data->>'proveedorId' as proveedor_id, p.data->>'nombre' as proveedor, r.data->>'condicion' as condicion,
       (r.data->>'subtotal')::numeric as subtotal, (r.data->>'itbis')::numeric as itbis, (r.data->>'total')::numeric as total,
       pg.pagado,
       case when r.data->>'estado' = 'Anulada' then 0 else greatest(0, (r.data->>'total')::numeric - pg.pagado) end as saldo,
       r.data->>'estado' as estado, r.data->>'usuario' as usuario, r.updated_at
  from public.registros r
  left join public.registros p on p.coleccion = 'proveedores' and p.id = r.data->>'proveedorId'
  cross join lateral (
    select case
             when r.data ? 'pagos' then coalesce((select sum((x->>'monto')::numeric) from jsonb_array_elements(r.data->'pagos') x), 0)
             when r.data->>'estado' = 'Pagada' then (r.data->>'total')::numeric
             else 0 end as pagado
  ) pg
 where r.coleccion = 'compras';

-- Pagos hechos a proveedores (uno por fila)
create or replace view public.v_pagos_compras with (security_invoker = true) as
select r.id as compra_id, (r.data->>'num')::bigint as compra, p.data->>'nombre' as proveedor,
       (x->>'fecha')::date as fecha, x->>'metodo' as metodo, x->>'referencia' as referencia,
       (x->>'monto')::numeric as monto, x->>'usuario' as usuario
  from public.registros r
  left join public.registros p on p.coleccion = 'proveedores' and p.id = r.data->>'proveedorId'
  cross join lateral jsonb_array_elements(coalesce(r.data->'pagos', '[]'::jsonb)) x
 where r.coleccion = 'compras' and r.data->>'estado' <> 'Anulada';

create or replace view public.v_compras_lineas with (security_invoker = true) as
select r.id as compra_id, (r.data->>'num')::bigint as compra, (r.data->>'fecha')::date as fecha, l->>'productoId' as producto_id,
       l->>'nombre' as producto, (l->>'cant')::numeric as cantidad, (l->>'precio')::numeric as costo_unitario,
       l->>'lote' as lote, l->>'finca' as finca, nullif(l->>'cosecha', '')::date as cosecha
  from public.registros r, jsonb_array_elements(r.data->'lineas') l
 where r.coleccion = 'compras';

create or replace view public.v_cotizaciones with (security_invoker = true) as
select id, (data->>'num')::bigint as numero, (data->>'fecha')::date as fecha, nullif(data->>'valida', '')::date as valida_hasta,
       data->>'clienteId' as cliente_id, data->>'moneda' as moneda, (data->>'total')::numeric as total, data->>'estado' as estado,
       data->>'usuario' as usuario, updated_at
  from public.registros where coleccion = 'cotizaciones';

create or replace view public.v_notas_credito with (security_invoker = true) as
select id, (data->>'num')::bigint as numero, (data->>'fecha')::date as fecha, data->>'ncf' as ncf, data->>'ncfModificado' as ncf_modificado,
       (data->>'ventaNum')::bigint as factura, data->>'clienteId' as cliente_id, data->>'moneda' as moneda,
       (data->>'subtotal')::numeric as subtotal, (data->>'itbis')::numeric as itbis, (data->>'total')::numeric as total,
       (data->>'reembolso')::numeric as reembolso, data->>'motivo' as motivo, (data->>'reingresa')::boolean as volvio_al_inventario,
       data->>'estado' as estado, data->>'usuario' as usuario, updated_at
  from public.registros where coleccion = 'notas';

create or replace view public.v_ordenes_trabajo with (security_invoker = true) as
select id, (data->>'num')::bigint as numero, data->>'titulo' as trabajo, data->>'clienteId' as cliente_id,
       (data->>'fecha')::date as creada, (data->>'entrega')::date as entrega, data->>'estado' as etapa,
       data->>'prioridad' as prioridad, data->>'responsable' as responsable, nullif(data->>'despachada', '')::date as despachada, updated_at
  from public.registros where coleccion = 'ordenes';

create or replace view public.v_lotes with (security_invoker = true) as
select id, data->>'codigo' as lote, data->>'productoId' as producto_id, data->>'finca' as finca,
       nullif(data->>'cosecha', '')::date as cosecha, (data->>'compraNum')::bigint as compra,
       (data->>'cantidad')::numeric as recibido, (data->>'disponible')::numeric as disponible,
       coalesce((data->>'anulado')::boolean, false) as anulado, updated_at
  from public.registros where coleccion = 'lotes';

create or replace view public.v_gastos with (security_invoker = true) as
select id, (data->>'fecha')::date as fecha, data->>'categoria' as categoria, data->>'descripcion' as descripcion,
       (data->>'monto')::numeric as monto, data->>'metodo' as pagado_con, data->>'rnc' as rnc_suplidor, data->>'ncf' as ncf,
       data->>'usuario' as usuario, updated_at
  from public.registros where coleccion = 'gastos';

create or replace view public.v_cierres_caja with (security_invoker = true) as
select id, (data->>'fecha')::date as fecha, (data->>'fondo')::numeric as fondo, (data->>'esperado')::numeric as esperado,
       (data->>'contado')::numeric as contado, (data->>'diferencia')::numeric as diferencia,
       data->>'cerradoPor' as cerrado_por, data->>'hora' as hora, data->>'notas' as observaciones
  from public.registros where coleccion = 'cajas';

create or replace view public.v_ncf_secuencias with (security_invoker = true) as
select id, data->>'tipo' as tipo, (data->>'desde')::bigint as desde, (data->>'hasta')::bigint as hasta,
       (data->>'actual')::bigint as proximo, (data->>'hasta')::bigint - (data->>'actual')::bigint + 1 as quedan,
       nullif(data->>'vence', '')::date as vence, coalesce((data->>'activo')::boolean, true) as activa
  from public.registros where coleccion = 'ncf';

create or replace view public.v_usuarios with (security_invoker = true) as
select id, data->>'nombre' as nombre, lower(data->>'email') as correo, data->>'rol' as rol,
       coalesce((data->>'activo')::boolean, true) as activo, updated_at
  from public.registros where coleccion = 'usuarios';

create or replace view public.v_bitacora with (security_invoker = true) as
select id, (data->>'fecha')::timestamptz as fecha, data->>'usuario' as usuario, data->>'accion' as accion,
       data->>'modulo' as modulo, data->>'detalle' as detalle
  from public.registros where coleccion = 'bitacora';

-- Fin del script
