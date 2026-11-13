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

-- 3) Seguridad por filas (RLS)
alter table public.registros enable row level security;

drop policy if exists "leer"       on public.registros;
drop policy if exists "crear"      on public.registros;
drop policy if exists "modificar"  on public.registros;
drop policy if exists "eliminar"   on public.registros;

-- Leer: cualquier usuario activo del sistema (o el primero, para darse de alta)
create policy "leer" on public.registros for select to authenticated
  using (public.mi_rol() is not null or public.sin_usuarios());

-- Crear: empleados activos crean documentos; usuarios y configuración solo el propietario.
-- El primer usuario que entra puede crear su propio perfil (queda como propietario).
create policy "crear" on public.registros for insert to authenticated
  with check (
    (public.mi_rol() is not null and coleccion not in ('usuarios', 'config'))
    or public.mi_rol() = 'Propietario'
    or (coleccion = 'usuarios' and public.sin_usuarios()
        and lower(data->>'email') = lower(auth.jwt()->>'email')
        and data->>'rol' = 'Propietario')
  );

-- Modificar: igual que crear (las ventas descuentan stock de productos)
create policy "modificar" on public.registros for update to authenticated
  using      ((public.mi_rol() is not null and coleccion not in ('usuarios', 'config')) or public.mi_rol() = 'Propietario')
  with check ((public.mi_rol() is not null and coleccion not in ('usuarios', 'config')) or public.mi_rol() = 'Propietario');

-- Eliminar: solo el propietario
create policy "eliminar" on public.registros for delete to authenticated
  using (public.mi_rol() = 'Propietario');

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
