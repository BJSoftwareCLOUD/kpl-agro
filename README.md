# KPL AGRO · Sistema de ventas y exportación

Aplicación web y web-app instalable para la facturación, las cotizaciones, el inventario, las compras, las órdenes de trabajo, el presupuesto y los reportes de KPL AGRO (ajíes y productos agrícolas).

Desarrollado por **SP BJ SOFTWARE** · Instagram @bjsoftware · 849-473-3173.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `index.html` | Toda la aplicación (HTML, CSS y JavaScript en un solo archivo) |
| `manifest.webmanifest`, `icon-192.png`, `icon-512.png` | Permiten instalarla como app en el celular y en la computadora |
| `sw.js` | Hace que abra rápido y funcione sin internet (los datos sí necesitan conexión) |
| `vercel.json` | Encabezados para Vercel |
| `supabase/schema.sql` | Tabla, permisos por rol, tiempo real y funciones atómicas de stock y NCF |
| `supabase/functions/alerta-stock/` | (Opcional) Envío automático de alertas de stock bajo por correo y WhatsApp |

Sin Supabase configurado, la app arranca en **modo demostración**: carga datos de ejemplo y los guarda solo en ese navegador. Los usuarios de prueba usan la contraseña `demo123`.

## 1. Supabase

1. Crea un proyecto en [supabase.com](https://supabase.com).
2. Abre **SQL Editor**, pega el contenido de `supabase/schema.sql` y pulsa **Run**.
3. En **Authentication → Sign In / Providers → Email**, desactiva **Confirm email**. Así los usuarios que crees desde el panel entran de inmediato.
4. En **Authentication → Users → Add user**, crea el usuario del **propietario** con su correo y contraseña.
5. En **Project Settings → API**, copia la **Project URL** y la clave **anon public**.

## 2. Conectar la app

Tienes dos formas de hacerlo.

- **Opción A (recomendada).** Abre `index.html` y pega los valores al inicio del script:
  ```js
  const SUPABASE_URL = "https://xxxx.supabase.co";
  const SUPABASE_ANON_KEY = "eyJhbGciOi...";
  ```
- **Opción B.** Desde la app: **Configuración → Nube**. Pega la URL y la clave y pulsa **Conectar y recargar**. Esta opción solo aplica en ese dispositivo.

La clave *anon* es pública por diseño. La seguridad la dan las reglas RLS del `schema.sql`.

## 3. GitHub y Vercel

1. Crea un repositorio privado en GitHub (por ejemplo `kpl-agro`) y sube **todos** los archivos de esta carpeta.
2. En Vercel, entra a **Add New → Project**, importa el repositorio y elige **Framework Preset: Other**. No hace falta comando de compilación. Pulsa **Deploy**.
3. Cada `git push` vuelve a publicar la app automáticamente.

## 4. Primer uso

1. Entra con el correo del propietario. Al ser el primer usuario, el sistema lo registra como **Propietario**.
2. Ve a **Configuración → Empresa** para poner el nombre, el RNC, el logo, el ITBIS y la tasa del dólar.
3. Si quieres probar con datos, usa **Configuración → Nube → Cargar datos de ejemplo**. Si no, empieza a crear productos, clientes y proveedores.

## 5. Agregar empleados

1. En Supabase: **Authentication → Users → Add user**, con el correo y la contraseña del empleado.
2. En la app: **Usuarios y roles → Nuevo usuario**, con el **mismo correo** y su rol (Vendedor o Almacén).

Los roles se administran en **Usuarios y roles → Roles y permisos**: puedes crear roles nuevos (por ejemplo "Supervisor") y marcar qué módulos abre y qué acciones hace cada uno. Vienen tres de fábrica: **Propietario** (siempre todo, no se puede quitar), **Vendedor** y **Almacén**. Los permisos también se aplican en la base de datos mediante las reglas RLS del `schema.sql`.

Para quitarle el acceso a alguien, desactívalo en **Usuarios y roles**. También puedes borrarlo en Supabase.

## 6. Instalar como app

- **Android / Chrome:** menú ⋮ → *Instalar aplicación*.
- **iPhone (Safari):** Compartir → *Agregar a inicio*.
- **Computadora (Chrome o Edge):** ícono de instalar en la barra de direcciones.

## Funciones opcionales

En **Configuración → Funciones**, el cliente activa solo lo que va a usar. Lo desactivado se oculta del menú y de los formularios, y los datos ya guardados se conservan.

| Función | Qué hace |
|---|---|
| Comprobantes fiscales | Asigna NCF (B01, B02, B14, B15, B16, B04) o e-CF (E31, E32, E34, E44, E45, E46) según el cliente. Controla las secuencias autorizadas y su vencimiento, y avisa cuando se agotan. Genera los formatos **606 y 607** en TXT y Excel (Reportes → DGII). El envío de e-CF a la DGII requiere un proveedor de facturación electrónica autorizado. |
| Documentos de exportación | Datos de embarque en la factura, **Commercial Invoice** en inglés y **Packing List** con pesos netos y brutos. |
| Lotes y trazabilidad | Cada compra crea un lote con su finca y fecha de cosecha. Las ventas descuentan por lote (primero en entrar, primero en salir), y cada lote muestra a qué clientes se vendió. |
| Notas de crédito | Devoluciones parciales con NCF B04/E34. Rebajan el saldo o se reembolsan, y la mercancía vuelve al inventario o se registra como merma. |
| Listas de precios | Precios especiales por cliente, en pesos o dólares. |
| Conversión de unidades | Se vende y se compra por caja, libra o kilo usando el peso de cada producto. |
| Cierre de caja | Cuadre diario por efectivo, transferencia, tarjeta y cheque, con faltantes, sobrantes e historial. |
| Alertas de stock bajo | Aviso con botones para enviarlo por WhatsApp o correo. Con la función `alerta-stock` instalada, el envío es automático. |
| Bitácora | Registro de quién hizo qué y cuándo, con filtros y exportación. |

Además, cada cliente tiene su **estado de cuenta** (botón en la ficha del cliente), que se puede imprimir, descargar en PDF o Excel y enviar por WhatsApp.

### Alertas automáticas (opcional)

1. Instala la [CLI de Supabase](https://supabase.com/docs/guides/cli) y ejecuta `supabase functions deploy alerta-stock`.
2. Configura los secretos del canal que vayas a usar: correo con [Resend](https://resend.com) (`RESEND_API_KEY`, `ALERTA_REMITENTE`) y/o WhatsApp Cloud API de Meta (`WA_TOKEN`, `WA_PHONE_ID`, `WA_TEMPLATE`).
3. En la app, ve a **Configuración → Alertas** y activa "Enviar automáticamente".

## Notas técnicas

- **Almacenamiento.** Todos los documentos viven en una sola tabla, `registros (coleccion, id, data jsonb)`. Esto permite agregar campos sin migraciones.
- **Sincronización.** Es en tiempo real con Supabase Realtime, y se mantiene una copia local en el navegador.
- **Reportes y listados.** Cada reporte se puede imprimir, ver en PDF o descargar en Excel/CSV. Los listados de ventas, compras, cotizaciones, clientes, proveedores, productos y kardex se exportan a PDF o Excel respetando los filtros aplicados. PDF y Excel se generan en el navegador con jsPDF y SheetJS (cargados desde cdnjs).
- **Respaldo.** **Configuración → Respaldo** descarga todo en JSON, fotos incluidas. Hazlo cada semana.
- **Fotos.** Se comprimen a unos 900 px antes de guardarse.
- **Base de datos.** Todo se guarda en Supabase: productos, clientes, facturas, pagos, lotes, cajas, usuarios, roles, configuración y bitácora. El navegador solo guarda una copia para abrir rápido. El script completo es `supabase/schema.sql`.
- **Varias personas a la vez.** Cada cambio se guarda con control de versión (`guardar`): si dos personas modifican el mismo registro, el segundo cambio no pisa al primero y la app recarga la versión correcta. El stock, los lotes, la numeración de documentos y los NCF se asignan con funciones que bloquean la fila (`mover_stock`, `mover_lotes`, `tomar_numero`, `tomar_ncf`), así nunca se repite un número ni se vende más de lo que hay. Probado con 8 usuarios simultáneos.
- **En vivo.** Los cambios llegan al instante a todos los dispositivos. El propietario ve quién está conectado y en qué pantalla, y recibe un aviso cada vez que alguien factura, compra, emite una nota o cierra la caja.
- **Vistas de consulta.** El script crea vistas (`v_ventas`, `v_ventas_lineas`, `v_pagos`, `v_productos`, `v_clientes`, `v_compras`, `v_lotes`, `v_cierres_caja`, etc.) para consultar los datos como tablas normales desde Supabase o conectar Excel o Power BI.
