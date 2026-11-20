-- Verificación de la base de datos de KPL AGRO
-- Pégala en Supabase → SQL Editor → Run. Todo debe salir OK (19 vistas, 9 funciones, 4 reglas).

select 'Tabla registros' as revision, case when to_regclass('public.registros') is not null then 'OK' else 'FALTA' end as estado
union all select 'Tabla contadores', case when to_regclass('public.contadores') is not null then 'OK' else 'FALTA' end
union all select 'Vistas (deben ser 19)', (select count(*) from information_schema.views where table_schema = 'public' and table_name like 'v\_%')::text
union all select 'Funciones (deben ser 9)', (select count(distinct p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('mi_rol','sin_usuarios','tiene_permiso','puede_escribir','guardar','mover_stock','mover_lotes','tomar_numero','tomar_ncf'))::text
union all select 'Seguridad RLS activa', coalesce((select case when relrowsecurity then 'OK' else 'FALTA' end from pg_class where oid = to_regclass('public.registros')), 'FALTA')
union all select 'Reglas de acceso (deben ser 4)', (select count(*) from pg_policies where schemaname = 'public' and tablename = 'registros')::text
union all select 'Tiempo real', case when exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'registros') then 'OK' else 'FALTA' end;
