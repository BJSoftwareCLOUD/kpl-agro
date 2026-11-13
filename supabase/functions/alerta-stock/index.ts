// Supabase Edge Function: alerta-stock
// Envía la alerta de stock bajo por correo (Resend) y/o WhatsApp (API de WhatsApp Cloud de Meta).
// Despliegue:  supabase functions deploy alerta-stock
// Secretos (solo los del canal que uses):
//   supabase secrets set RESEND_API_KEY=re_xxx ALERTA_REMITENTE="KPL AGRO <alertas@tudominio.com>"
//   supabase secrets set WA_TOKEN=EAAG... WA_PHONE_ID=1234567890 WA_TEMPLATE=alerta_stock
// Nota sobre WhatsApp: para escribir a un número que no te ha escrito en las últimas 24 h,
// Meta exige una plantilla aprobada (WA_TEMPLATE) con un parámetro de texto.

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!req.headers.get("authorization")) return new Response("Unauthorized", { status: 401, headers: cors });
  const { empresa = "", whatsapp = "", correo = "", texto = "", productos = [] } = await req.json().catch(() => ({}));
  const out: Record<string, unknown> = {};

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const correos = String(correo).split(/[,;\s]+/).filter(Boolean);
  if (resendKey && correos.length) {
    const filas = (productos as any[]).map(p => `<tr><td>${p.nombre}</td><td>${p.sku}</td><td style="text-align:right">${p.stock}</td><td style="text-align:right">${p.minimo}</td><td>${p.unidad}</td></tr>`).join("");
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: Deno.env.get("ALERTA_REMITENTE") ?? "Alertas <onboarding@resend.dev>", to: correos, subject: `Stock bajo · ${empresa}`,
        html: `<h2>Alerta de inventario · ${empresa}</h2><table border="1" cellpadding="6" style="border-collapse:collapse"><tr><th>Producto</th><th>SKU</th><th>Quedan</th><th>Mínimo</th><th>Unidad</th></tr>${filas}</table>` }),
    });
    out.correo = r.status;
  }

  const waToken = Deno.env.get("WA_TOKEN"), waPhone = Deno.env.get("WA_PHONE_ID");
  const tels = String(whatsapp).split(/[,;\s]+/).map(t => t.replace(/\D/g, "")).filter(Boolean).map(t => t.length === 10 ? "1" + t : t);
  if (waToken && waPhone && tels.length) {
    const tpl = Deno.env.get("WA_TEMPLATE");
    out.whatsapp = await Promise.all(tels.map(to => fetch(`https://graph.facebook.com/v20.0/${waPhone}/messages`, {
      method: "POST", headers: { Authorization: `Bearer ${waToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(tpl
        ? { messaging_product: "whatsapp", to, type: "template", template: { name: tpl, language: { code: "es" }, components: [{ type: "body", parameters: [{ type: "text", text: String(texto).slice(0, 1000) }] }] } }
        : { messaging_product: "whatsapp", to, type: "text", text: { body: String(texto).slice(0, 4000) } }),
    }).then(r => r.status)));
  }
  return new Response(JSON.stringify({ ok: true, ...out }), { headers: { ...cors, "Content-Type": "application/json" } });
});
