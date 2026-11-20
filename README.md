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
| `supabase/functions/usuarios/` | Crea usuarios, restablece contraseñas y gestiona el cambio obligatorio del primer ingreso |
| `supabase/functions/alerta-stock/` | (Opcional) Envío automático de alertas de stock bajo por correo y WhatsApp |

Sin Supabase configurado, la app arranca en **modo demostración**: carga datos de ejemplo y los guarda solo en ese navegador. Los usuarios de prueba usan la contraseña `demo123`.

## Puesta en marcha desde cero

Sigue los pasos en orden. Al terminar, el sistema arranca vacío (sin datos de ejemplo) y listo para trabajar.

### 1. Crear el proyecto en Supabase
1. Crea la cuenta en [supabase.com](https://supabase.com), idealmente con el correo de KPL AGRO, y luego un proyecto nuevo (región **East US**, la más cercana a RD).
2. Ve a **SQL Editor → New query**, pega **todo** el contenido de `supabase/schema.sql` y pulsa **Run**. Si Supabase avisa de "operaciones destructivas", confirma con **Run this query**: el script no borra datos.
3. Abajo, en **Results**, debe aparecer **INSTALACIÓN COMPLETA** (2 tablas, 18 vistas, 9 funciones). Si dice INCOMPLETA o sale un error, vuelve a ejecutarlo completo.

### 2. Configurar el acceso
1. En **Authentication → Sign In / Providers → Email**, desactiva **Confirm email**.
2. En la misma sección, desactiva **Allow new users to sign up**. Así nadie puede registrarse por su cuenta: los usuarios solo se crean desde el sistema.
3. En **Authentication → Users → Add user → Create new user**, crea tu usuario de proveedor:
   - Email: `bjsoftware@kpl.local` (en el sistema entrarás solo con `bjsoftware`).
   - Password: una contraseña segura tuya.
   - Marca **Auto Confirm User**.

### 3. Instalar las funciones
En **Edge Functions → Deploy a new function → Via Editor**:
1. Nombre **`usuarios`**: pega el contenido de `supabase/functions/usuarios/index.ts` y pulsa **Deploy**. Es la que crea los usuarios y cambia contraseñas. Es obligatoria.
2. (Opcional) Nombre **`alerta-stock`**: solo si se van a enviar alertas automáticas (ver más abajo).

Después de desplegarla, abre la función `usuarios` → **Details** y desactiva **Verify JWT with legacy secret**. Es necesario en los proyectos con claves nuevas (`sb_publishable_` / `sb_secret_`); la función comprueba la sesión por sí misma.

### 4. Conectar el sistema
1. En Supabase, pulsa el botón **Connect** (arriba en el panel del proyecto). Copia el valor de **SUPABASE_URL** y el de **SUPABASE_PUBLISHABLE_KEY**, que empieza con `sb_publishable_`. En proyectos antiguos, usa la clave **anon** (empieza con `eyJ`).
2. Abre `index.html` y pégalas al inicio del script (busca `SUPABASE_URL`):
   ```js
   const SUPABASE_URL = "https://xxxx.supabase.co";
   const SUPABASE_ANON_KEY = "sb_publishable_...";
   ```
   **Nunca** pegues la **secret key** (`sb_secret_...`) ni la `service_role`: esas no van en el navegador. La clave publishable es pública por diseño; la seguridad la dan las reglas del `schema.sql`.

### 5. Publicar
1. Crea un repositorio **privado** en GitHub (por ejemplo `kpl-agro`) y sube el **contenido** de esta carpeta, con `index.html` en la raíz.
2. En Vercel: **Add New → Project**, importa el repositorio, elige **Framework Preset: Other** y pulsa **Deploy**.
3. Cada `git push` vuelve a publicar automáticamente.

### 6. Primer ingreso (tú, como proveedor)
1. Entra con el usuario `bjsoftware` y tu contraseña. Como la base está vacía, el sistema te registra como **Propietario** y crea los roles: Propietario, Vendedor, Contabilidad y Almacén.
2. En **Usuarios y roles**, toca tu nombre y cámbialo a "BJ Software (Soporte)".
3. El panel muestra la guía **Puesta en marcha**: datos de la empresa, comprobantes NCF, usuarios, productos, clientes y proveedores. Desaparece cuando todo está listo.
4. **Inventario inicial:** crea los productos (la existencia arranca en 0 y no se escribe a mano) y luego haz un **Arqueo de inventario** con lo que hay en el almacén. Desde ahí, la existencia sube con las compras y se corrige con nuevos arqueos.
5. En **Configuración**:
   - **Empresa:** RNC, dirección, teléfono, correo y logo reales.
   - **Comprobantes:** las secuencias NCF autorizadas por la DGII.
   - **Funciones:** apaga lo que el cliente no vaya a usar.

### 7. Crear los usuarios del cliente
En **Usuarios y roles → Nuevo usuario**, crea cada acceso con un usuario genérico. El sistema genera una contraseña temporal:

| Para | Usuario genérico | Rol |
|---|---|---|
| Dueño | `propietario` | Propietario |
| Quien factura | `facturacion` | Vendedor (puedes renombrarlo a "Facturación" en Roles y permisos) |
| Contable (más adelante) | `contabilidad` | Contabilidad (ajusta sus permisos cuando definas qué verá) |

Al crearlo aparece una tarjeta con el usuario y la contraseña temporal, para copiarla o enviarla por WhatsApp. La primera vez que cada persona entra, el sistema la obliga a elegir **su propio usuario y contraseña** antes de dejarla pasar. Después puede cambiarlos cuando quiera en **Mi cuenta**: tocando su nombre, abajo a la izquierda.

Si alguien olvida su contraseña, el propietario abre su usuario y usa **Restablecer contraseña**: se genera una nueva temporal y la persona vuelve a elegir la suya al entrar.

### 8. Instalar como app en los equipos

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
| Arqueo de inventario | Conteo físico de todos los productos a la vez: compara contra el sistema, ajusta las diferencias sin hacer compras y guarda el historial imprimible. También sirve para cargar el inventario inicial. |
| Servicios | Productos sin inventario (fletes, empaque, fumigación…): se facturan y se compran sin mover existencias. En el 606 se reportan como servicios. |
| Contabilidad y finanzas | Partida doble automática, estados financieros, CxC, CxP y tablero de decisiones (ver sección propia). |
| Bitácora | Registro de quién hizo qué y cuándo, con filtros y exportación. |

Además, cada cliente tiene su **estado de cuenta** (botón en la ficha del cliente), que se puede imprimir, descargar en PDF o Excel y enviar por WhatsApp.

### Alertas automáticas (opcional)

1. Instala la [CLI de Supabase](https://supabase.com/docs/guides/cli) y ejecuta `supabase functions deploy alerta-stock`.
2. Configura los secretos del canal que vayas a usar: correo con [Resend](https://resend.com) (`RESEND_API_KEY`, `ALERTA_REMITENTE`) y/o WhatsApp Cloud API de Meta (`WA_TOKEN`, `WA_PHONE_ID`, `WA_TEMPLATE`).
3. En la app, ve a **Configuración → Alertas** y activa "Enviar automáticamente".

## Contabilidad y finanzas

El sistema lleva la contabilidad por **partida doble automática**: cada factura, cobro, compra, pago a proveedor, gasto, nota de crédito, ajuste de inventario, arqueo y cierre de caja genera su asiento contable, sin que nadie lo digite. Se encuentra en el grupo **Contabilidad** del menú:

| Pantalla | Contenido |
|---|---|
| Tablero de decisiones | Ventas, utilidad, efectivo, liquidez, capital de trabajo, ciclo de efectivo (días de cobro, inventario y pago), punto de equilibrio, rentabilidad por producto, concentración de clientes, tendencia de 12 meses y alertas con recomendaciones. Compara con el período anterior. |
| Estados financieros | Estado de resultados (con % de ventas y comparación), balance general (verifica que activos = pasivos + patrimonio), balanza de comprobación (con libro mayor por cuenta) y flujo de caja por el método directo (operación, inversión y financiamiento). |
| Cuentas por cobrar / por pagar | Antigüedad de saldos por cliente o proveedor (al día, 1–30, 31–60, 61–90, más de 90 días), días promedio de cobro y de pago, y cobro o pago directo desde el detalle. |
| Libro diario y cuentas | Todos los asientos con filtro por origen, asientos manuales con plantillas (apertura, aporte de capital, préstamo, activo fijo, depreciación, traspaso) y catálogo de cuentas ampliable. |

Todo se puede imprimir, ver en PDF o descargar en Excel.

**Para empezar en producción:**
1. Registra el **asiento de apertura** (Libro diario → Asientos manuales → Nuevo asiento → "Apertura") con los saldos reales de caja, bancos, activos fijos, préstamos y capital.
2. Si el inventario inicial se cargó con un arqueo, abre ese arqueo (Arqueo de inventario → Historial) y marca **"Contabilizar como inventario inicial"**, para que cuente como capital y no como ganancia.
3. Para la contable, marca en **Usuarios y roles → Roles y permisos → Contabilidad** los permisos "Contabilidad y finanzas" y "Registrar asientos contables".

## Notas técnicas

- **Almacenamiento.** Todos los documentos viven en una sola tabla, `registros (coleccion, id, data jsonb)`. Esto permite agregar campos sin migraciones.
- **Sincronización.** Es en tiempo real con Supabase Realtime, y se mantiene una copia local en el navegador.
- **Reportes y listados.** Cada reporte se puede imprimir, ver en PDF o descargar en Excel/CSV. Los listados de ventas, compras, cotizaciones, clientes, proveedores, productos y kardex se exportan a PDF o Excel respetando los filtros aplicados. PDF y Excel se generan en el navegador con jsPDF y SheetJS (cargados desde cdnjs).
- **Respaldo.** **Configuración → Respaldo** descarga todo en JSON, fotos incluidas. Hazlo cada semana.
- **Fotos.** Se comprimen a unos 900 px antes de guardarse.
- **Base de datos.** Todo se guarda en Supabase: productos, clientes, facturas, pagos, lotes, cajas, usuarios, roles, configuración y bitácora. El navegador solo guarda una copia para abrir rápido. El script completo es `supabase/schema.sql`.
- **Varias personas a la vez.** Cada cambio se guarda con control de versión (`guardar`): si dos personas modifican el mismo registro, el segundo cambio no pisa al primero y la app recarga la versión correcta. El stock, los lotes, la numeración de documentos y los NCF se asignan con funciones que bloquean la fila (`mover_stock`, `mover_lotes`, `tomar_numero`, `tomar_ncf`), así nunca se repite un número ni se vende más de lo que hay. Probado con 8 usuarios simultáneos.
- **En vivo.** Los cambios llegan al instante a todos los dispositivos. El propietario ve quién está conectado y en qué pantalla, y recibe un aviso cada vez que alguien factura, compra, emite una nota o cierra la caja.
- **Vistas de consulta.** El script crea vistas (`v_ventas`, `v_ventas_lineas`, `v_pagos`, `v_productos`, `v_clientes`, `v_compras`, `v_pagos_compras`, `v_lotes`, `v_cierres_caja`, etc.) para consultar los datos como tablas normales desde Supabase o conectar Excel o Power BI.
