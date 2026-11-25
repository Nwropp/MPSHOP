/**
 * MPSHOP · Discord @everyone Notification Function
 * -------------------------------------------------
 * ส่ง @everyone ลงใน Discord ผ่าน Webhook โดยใช้ allowed_ments เพื่อให้ Discord
 * จับการ Mention จริงแท้ (ไม่ให้ escape เป็นข้อความธรรมดา)
 * 
 * เรียกใช้ได้ 2 ทาง:
 *  1) จาก RPC ในฐานข้อมูล (service_role เท่านั้น)
 *  2) จาก Edge Function โดยตรง (POST)
 * 
 * ความปลอดภัย: Webhook URL เก็บไว้ในฐานข้อมูล/Env เท่านั้น ไม่ ever เข้ามาในฝั่ง Client
 */

const DISCORD_WEBHOOK_URL = env.DISCORD_WEBHOOK_URL;

/** ตรวจสอบว่า Webhook URL มีอยู่จริง */
function mustEnv(name: string): string {
  const g: any = globalThis;
  if (g.Deno && g.Deno.env && typeof g.Deno.env.get === "function") {
    const v = g.Deno.env.get(name);
    if (v) return v;
  }
  if (g.process && g.process.env && g.process.env[name]) return String(g.process.env[name]);
  const v = (g as any).SUPABASE_FUNCTIONS_ENV?.[name];
  if (v) return String(v);
  return "";
}

function mustWebhook(): string {
  const v = mustEnv("DISCORD_WEBHOOK_URL");
  if (!v) throw new Error("missing_discord_webhook_url");
  return v;
}

/** สร้าง payload สำหรับ Discord kพร้อม allowed_mentions */
function makeDiscordPayload(
  orderId: string,
  customerName: string,
  serviceName: string,
  price: string,
  bookedAt: string
): object {
  const content = `@everyone\n🔔 มีลูกค้าจองคิวใหม่!\n👤 ลูกค้า: ${customerName}\n📦 งาน: ${serviceName}\n💰 ราคา: ${price}\n🕐 เวลา: ${bookedAt}\n🆔 เลขที่งาน: ${orderId}`;

  return {
    content: content,
    allowed_mentions: {
      parse: ["everyone"] as const,
    },
  };
}

/** ส่งไป Discord Webhook */
async function sendToDiscord(payload: object): Promise<{ ok: boolean; status?: number; error?: string }> {
  const url = mustWebhook();
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (res.ok || res.status === 204) {
      return { ok: true, status: res.status };
    }

    const text = await res.text().catch(() => "ไม่สามารถอ่านได้");
    console.error(`Discord Webhook error ${res.status}: ${text}`);
    return { ok: false, status: res.status, error: text.slice(0, 300) };
  } catch (e: any) {
    console.error("Discord Webhook exception:", e.message);
    return { ok: false, error: e.message.slice(0, 300) };
  }
}

export default async function handler(req: Request): Promise<Response> {
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    if (req.method !== "POST") {
      return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), {
        status: 405,
        headers: { "Content-Type": "application/json; charset=utf-8" },
      });
    }

    const body = await req.json();

    const {
      orderId,
      customerName,
      serviceName,
      price,
      bookedAt,
    } = body;

    // ยืนยังข้อมูลครบถ้วน
    if (!orderId || !customerName) {
      return new Response(
        JSON.stringify({ ok: false, error: "missing_required_fields" }),
        { status: 400, headers: { "Content-Type": "application/json; charset=utf-8" } }
      );
    }

    // สร้างและส่ง payload
    const payload = makeDiscordPayload(
      String(orderId),
      String(customerName),
      String(serviceName || "บริการจองคิว"),
      String(price || "0"),
      String(bookedAt || new Date().toLocaleString())
    );

    const result = await sendToDiscord(payload);

    if (result.ok) {
      return new Response(
        JSON.stringify({ ok: true, sent: true }),
        {
          status: 200,
          headers: { "Content-Type": "application/json; charset=utf-8" },
        }
      );
    } else {
      return new Response(
        JSON.stringify({ ok: false, error: result.error }),
        {
          status: 502,
          headers: { "Content-Type": "application/json; charset=utf-8" },
        }
      );
    }
  } catch (e: any) {
    return new Response(
      JSON.stringify({ ok: false, error: String((e && e.message) || e).slice(0, 400) }),
      { status: 500, headers: { "Content-Type": "application/json; charset=utf-8" } }
    );
  }
}

/* ---------- สำหรับการเรียกใช้จาก RPC ---------- */
/** 
 * ฟังก์ชัน RPC สำหรับส่ง Discord @everyone notification
 * ใช้ได้เฉพาะ service_role หรือ admin ที่มีสิทธิ์
 */
export async function sendDiscordNotificationRpc(
  p_order_id: string,
  p_customer_name: string,
  p_service_name: string,
  p_price: string,
  p_booked_at: string
): Promise<{ ok: boolean; discord_status?: number; error?: string }> {
  const webhook = mustWebhook();
  const payload = makeDiscordPayload(
    String(p_order_id),
    String(p_customer_name),
    String(p_service_name || "บริการจองคิว"),
    String(p_price || "0"),
    String(p_booked_at || new Date().toLocaleString())
  );

  const url = webhook;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (res.ok || res.status === 204) {
      return { ok: true, discord_status: res.status };
    }

    const text = await res.text().catch(() => "ไม่สามารถอ่านได้");
    return { ok: false, error: `HTTP ${res.status}: ${text.slice(0, 200)}` };
  } catch (e: any) {
    return { ok: false, error: e.message.slice(0, 300) };
  }
}