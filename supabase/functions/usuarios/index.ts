// Supabase Edge Function: usuarios
// Permite administrar los accesos desde el propio sistema, sin entrar al panel de Supabase:
//   crear        → crea el acceso y el perfil con usuario y contraseña temporales
//   restablecer  → asigna una contraseña temporal y obliga a cambiarla al entrar
//   credenciales → el propio usuario cambia su usuario y su contraseña (primer ingreso)
//   eliminar     → borra el acceso y el perfil (los documentos se conservan)
//
// Despliegue (una de dos):
//   • Panel de Supabase → Edge Functions → Deploy a new function → Via Editor,
//     nombre "usuarios", pega este archivo y pulsa Deploy.
//   • CLI: supabase functions deploy usuarios
// No necesita secretos: SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY
// los pone Supabase automáticamente. La clave de servicio NUNCA sale de este servidor.

import { createClient } from "jsr:@supabase/supabase-js@2";

const DOMINIO = Deno.env.get("USUARIOS_DOMINIO") ?? "kpl.local"; // debe coincidir con USUARIO_DOMINIO en index.html
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const aEmail = (u: string) => { const s = String(u ?? "").trim().toLowerCase(); return s.includes("@") ? s : `${s}@${DOMINIO}`; };
const usuarioValido = (u: string) => { const s = String(u ?? "").trim().toLowerCase(); return s.includes("@") ? /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) : /^[a-z0-9][a-z0-9._-]{2,39}$/.test(s); };
const claveValida = (c: string) => typeof c === "string" && c.length >= 8 && /[a-zA-Z]/.test(c) && /\d/.test(c);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const comoUsuario = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await comoUsuario.auth.getUser();
    if (!user?.email) return json({ error: "Tu sesión no es válida. Vuelve a entrar." }, 401);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

    const perfilPorEmail = async (email: string) => (await admin.from("registros").select("id, data").eq("coleccion", "usuarios").eq("data->>email", email.toLowerCase()).maybeSingle()).data;
    const perfilPorId = async (id: string) => (await admin.from("registros").select("id, data").eq("coleccion", "usuarios").eq("id", id).maybeSingle()).data;
    const guardarPerfil = (p: Record<string, unknown>) => admin.from("registros").upsert({ coleccion: "usuarios", id: p.id, data: p, updated_at: new Date().toISOString() });
    const authIdDe = async (p: Record<string, any>) => {
      if (p.authId) return p.authId as string;
      for (let page = 1; page <= 20; page++) {
        const { data } = await admin.auth.admin.listUsers({ page, perPage: 200 });
        const u = data?.users?.find((x) => x.email?.toLowerCase() === String(p.email).toLowerCase());
        if (u) return u.id;
        if (!data?.users?.length || data.users.length < 200) break;
      }
      return null;
    };

    const yo = await perfilPorEmail(user.email);
    if (!yo || yo.data.activo === false) return json({ error: "Tu usuario no tiene un perfil activo en el sistema." }, 403);
    const esPropietario = yo.data.rol === "Propietario";
    const rol = (await admin.from("registros").select("data").eq("coleccion", "roles").eq("data->>nombre", yo.data.rol).maybeSingle()).data;
    const puedeUsuarios = esPropietario || (rol?.data?.permisos ?? []).includes("usuarios");
    const bitacora = (accion: string, detalle: string) => { const id = crypto.randomUUID(); return admin.from("registros").insert({ coleccion: "bitacora", id, data: { id, fecha: new Date().toISOString(), usuario: yo.data.nombre, email: yo.data.email, accion, modulo: "Usuarios", detalle, v: 1 } }); };

    const b = await req.json().catch(() => ({}));

    if (b.accion === "crear") {
      if (!puedeUsuarios) return json({ error: "Tu rol no puede crear usuarios." }, 403);
      if (b.rol === "Propietario" && !esPropietario) return json({ error: "Solo un propietario puede crear otro propietario." }, 403);
      if (!b.nombre || !b.rol) return json({ error: "Faltan el nombre o el rol." }, 400);
      if (!usuarioValido(b.usuario)) return json({ error: "Usuario no válido: usa letras, números, punto o guion (mínimo 3), o un correo." }, 400);
      if (!claveValida(b.clave)) return json({ error: "La contraseña temporal debe tener al menos 8 caracteres, con letras y números." }, 400);
      const email = aEmail(b.usuario);
      if (await perfilPorEmail(email)) return json({ error: "Ya existe un usuario con ese nombre de usuario." }, 409);
      const { data: cu, error } = await admin.auth.admin.createUser({ email, password: b.clave, email_confirm: true, user_metadata: { nombre: b.nombre } });
      if (error) return json({ error: error.message.includes("already") ? "Ese usuario ya existe en Supabase." : error.message }, 400);
      const id = crypto.randomUUID();
      const perfil = { id, nombre: String(b.nombre).trim(), email, usuario: String(b.usuario).trim().toLowerCase(), rol: b.rol, activo: true, debeCambiar: b.debeCambiar !== false, authId: cu.user.id, v: 1, updated: Date.now() };
      const r = await guardarPerfil(perfil);
      if (r.error) { await admin.auth.admin.deleteUser(cu.user.id); return json({ error: r.error.message }, 500); }
      await bitacora("Creó", `${perfil.nombre} (${perfil.usuario}) · rol ${perfil.rol}`);
      return json({ perfil });
    }

    if (b.accion === "restablecer") {
      if (!puedeUsuarios) return json({ error: "Tu rol no puede restablecer contraseñas." }, 403);
      if (!claveValida(b.clave)) return json({ error: "La contraseña temporal debe tener al menos 8 caracteres, con letras y números." }, 400);
      const p = await perfilPorId(b.id); if (!p) return json({ error: "Usuario no encontrado." }, 404);
      if (p.data.rol === "Propietario" && !esPropietario) return json({ error: "Solo un propietario puede restablecer a otro propietario." }, 403);
      const aid = await authIdDe(p.data); if (!aid) return json({ error: "No se encontró el acceso de este usuario en Supabase." }, 404);
      const { error } = await admin.auth.admin.updateUserById(aid, { password: b.clave });
      if (error) return json({ error: error.message }, 400);
      const nuevo = { ...p.data, authId: aid, debeCambiar: true, v: (p.data.v ?? 0) + 1, updated: Date.now() };
      await guardarPerfil(nuevo); await bitacora("Restableció", `contraseña de ${p.data.nombre} (${p.data.usuario ?? p.data.email})`);
      return json({ perfil: nuevo });
    }

    if (b.accion === "credenciales") {
      if (!claveValida(b.clave)) return json({ error: "La contraseña debe tener al menos 8 caracteres, con letras y números." }, 400);
      const quiere = b.usuario ? String(b.usuario).trim().toLowerCase() : (yo.data.usuario ?? yo.data.email);
      if (!usuarioValido(quiere)) return json({ error: "Usuario no válido: usa letras, números, punto o guion (mínimo 3), o un correo." }, 400);
      const email = aEmail(quiere);
      if (email !== yo.data.email) { const otro = await perfilPorEmail(email); if (otro && otro.id !== yo.id) return json({ error: "Ese usuario ya está en uso. Elige otro." }, 409); }
      const { error } = await admin.auth.admin.updateUserById(user.id, { email, password: b.clave, email_confirm: true });
      if (error) return json({ error: error.message.includes("already") ? "Ese usuario ya está en uso. Elige otro." : error.message }, 400);
      const nuevo = { ...yo.data, email, usuario: quiere, authId: user.id, debeCambiar: false, v: (yo.data.v ?? 0) + 1, updated: Date.now() };
      await guardarPerfil(nuevo); await bitacora("Cambió", "su usuario y contraseña de acceso");
      return json({ email, perfil: nuevo });
    }

    if (b.accion === "eliminar") {
      if (!puedeUsuarios) return json({ error: "Tu rol no puede eliminar usuarios." }, 403);
      const p = await perfilPorId(b.id); if (!p) return json({ error: "Usuario no encontrado." }, 404);
      if (p.id === yo.id) return json({ error: "No puedes eliminar tu propio usuario." }, 400);
      if (p.data.rol === "Propietario" && !esPropietario) return json({ error: "Solo un propietario puede eliminar a otro propietario." }, 403);
      const aid = await authIdDe(p.data); if (aid) await admin.auth.admin.deleteUser(aid);
      await admin.from("registros").delete().eq("coleccion", "usuarios").eq("id", p.id);
      await bitacora("Eliminó", `${p.data.nombre} (${p.data.usuario ?? p.data.email})`);
      return json({ ok: true });
    }

    return json({ error: "Acción no reconocida." }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
