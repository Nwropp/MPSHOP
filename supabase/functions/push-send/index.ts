/**
 * MPSHOP — Web Push sender (Supabase Edge Function)
 * -------------------------------------------------
 * รับงานจากคิว public.push_outbox (ผ่าน RPC push_claim) แล้วส่ง Web Push จริง
 * ตามมาตรฐาน RFC 8291 (aes128gcm) + RFC 8292 (VAPID) ด้วย Web Crypto ล้วน
 * ไม่ต้องพึ่งไลบรารีภายนอก จึง deploy ได้แม้ไม่มีเน็ตตอน bundle
 *
 * เรียกได้ 3 ทาง
 *  1) pg_net จาก trigger ในฐานข้อมูล (ทันทีเมื่อมี notification ใหม่)
 *  2) pg_cron สำรองทุกนาที (ถ้าเปิดไว้)
 *  3) กดตรวจสอบด้วย GET เพื่อดูสถานะคิว
 *
 * ความปลอดภัย: ฟังก์ชันนี้ไม่รับเนื้อหาข้อความจากผู้เรียกเลย
 * จึงเรียกโดยใครก็ได้โดยไม่สามารถส่งข้อความปลอมถึงลูกค้าได้ (ส่งได้เฉพาะงานที่อยู่ในคิวแล้ว)
 */

type Job = {
  id: number;
  title: string | null;
  body: string | null;
  link: string | null;
  image: string | null;
  kind: string | null;
  notification_id: string | null;
  attempts: number;
  endpoint: string;
  p256dh: string;
  auth: string;
  tag: string | null;
};

const enc = new TextEncoder();
const ORDER_KINDS = new Set([
  "order_created", "order_confirmed", "order_doing", "order_waiting",
  "order_done", "order_cancelled", "order_image", "order_update", "order_message",
]);

/* ---------- base64url ---------- */
export const b64u = {
  decode(s: string): Uint8Array {
    const t = String(s || "").replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
    const pad = t.length % 4 ? "=".repeat(4 - (t.length % 4)) : "";
    const raw = atob(t + pad);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  },
  encode(b: Uint8Array): string {
    let s = "";
    for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
};

function b64decode(s: string): Uint8Array {
  const t = String(s || "").replace(/\s+/g, "");
  return /[-_]/.test(t) ? b64u.decode(t) : b64u.decode(t.replace(/\+/g, "-").replace(/\//g, "_"));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const n = parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/* ---------- env ---------- */
function env(name: string): string {
  const g = globalThis as any;
  if (g.Deno && g.Deno.env && typeof g.Deno.env.get === "function") {
    const v = g.Deno.env.get(name);
    if (v) return v;
  }
  if (g.process && g.process.env && g.process.env[name]) return String(g.process.env[name]);
  return "";
}

function mustEnv(name: string): string {
  const v = env(name);
  if (!v) throw new Error("missing_env_" + name);
  return v;
}

/**
 * Shared secret สำหรับ POST: ถ้าตั้ง env PUSH_DRAIN_SECRET ไว้ จะบังคับ header x-mpshop-key
 * (ฝั่งฐานข้อมูลส่งมาให้เองจาก public.push_runtime.drain_secret) ถ้าไม่ตั้ง จะเปิดเหมือนเดิม
 * เพื่อไม่ให้คิวหยุดส่งระหว่างที่ยังไม่ได้ redeploy
 */
function drainSecret(): string {
  return env("PUSH_DRAIN_SECRET").trim();
}

/* ---------- HKDF ---------- */
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, len * 8);
  return new Uint8Array(bits);
}

/* ---------- RFC 8291: เข้ารหัสเนื้อหา ---------- */
export async function encryptPayload(sub: { p256dh: string; auth: string }, plaintext: Uint8Array): Promise<Uint8Array> {
  const uaPub = b64u.decode(sub.p256dh);
  const authSecret = b64u.decode(sub.auth);
  if (uaPub.length !== 65 || authSecret.length !== 16) throw new Error("bad_subscription_keys");

  const eph = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, eph.privateKey, 256));

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const keyInfo = concat(enc.encode("WebPush: info\0"), uaPub, asPub);
  const prk = await hkdf(authSecret, shared, keyInfo, 32);
  const cek = await hkdf(salt, prk, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, prk, enc.encode("Content-Encoding: nonce\0"), 12);

  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const plain = concat(plaintext, new Uint8Array([2]));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aes, plain));

  const header = new Uint8Array(16 + 4 + 1 + asPub.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096, false);
  header[20] = asPub.length;
  header.set(asPub, 21);
  return concat(header, ct);
}

/* ---------- RFC 8292: VAPID ---------- */
let vapidCache: { priv: CryptoKey; pub: string; subject: string } | null = null;
const DEFAULT_SUBJECT = "mailto:noreply@mpshop.shop";

export function resetVapidCache() { vapidCache = null; }

/**
 * กุญแจ VAPID: ใช้ env ถ้าตั้งไว้ (สำหรับ rotation) ไม่งั้นสร้างครั้งแรกแล้วเก็บในฐานข้อมูล
 * private key ไม่ต้องผ่านคน ไม่ต้องตั้ง secret มือ และไม่ถูกพิมพ์ที่ไหน
 */
async function vapidKeys(): Promise<{ priv: CryptoKey; pub: string; subject: string }> {
  if (vapidCache) return vapidCache;

  let pub = env("VAPID_PUBLIC_KEY").trim();
  let privRaw = env("VAPID_PRIVATE_KEY").trim();
  let subject = env("VAPID_SUBJECT").trim() || DEFAULT_SUBJECT;

  if (!pub || !privRaw) {
    let row: any = await rpc("push_vapid_get", {});
    if (!row || !row.public_key) {
      const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
      const privB64 = b64u.encode(new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey)));
      const pubB64 = b64u.encode(new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey)));
      row = await rpc("push_vapid_set", { p_public: pubB64, p_private: privB64, p_subject: subject });
    }
    if (!row || !row.public_key || !row.private_key) throw new Error("vapid_unavailable");
    pub = String(row.public_key);
    privRaw = String(row.private_key);
    subject = String(row.subject || DEFAULT_SUBJECT);
  }

  let priv: CryptoKey;
  try {
    priv = await crypto.subtle.importKey("pkcs8", b64decode(privRaw), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch (e) {
    // เผื่อคีย์ถูกเก็บเป็น raw scalar 32 ไบต์ (JWK d)
    const d = b64decode(privRaw);
    if (d.length !== 32) throw new Error("invalid_vapid_private_key");
    const raw = b64u.decode(pub);
    priv = await crypto.subtle.importKey(
      "jwk",
      { kty: "EC", crv: "P-256", x: b64u.encode(raw.slice(1, 33)), y: b64u.encode(raw.slice(33, 65)), d: b64u.encode(d) },
      { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
    );
  }
  vapidCache = { priv, pub, subject };
  return vapidCache;
}

export async function vapidHeader(endpoint: string, nowMs?: number): Promise<string> {
  const { priv, pub, subject } = await vapidKeys();
  const aud = new URL(endpoint).origin;
  const header = { typ: "JWT", alg: "ES256" };
  const claims = {
    aud,
    exp: Math.floor((nowMs == null ? Date.now() : nowMs) / 1000) + 12 * 3600,
    sub: subject || DEFAULT_SUBJECT,
  };
  const input = b64u.encode(enc.encode(JSON.stringify(header))) + "." + b64u.encode(enc.encode(JSON.stringify(claims)));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, enc.encode(input)));
  return "vapid t=" + input + "." + b64u.encode(sig) + ", k=" + pub;
}

/* ---------- ส่ง 1 งาน ---------- */
export type SendResult = { status: "sent" | "gone" | "retry" | "failed"; http?: number; error?: string };

export async function sendOne(job: Job): Promise<SendResult> {
  const payload = {
    id: job.notification_id || String(job.id),
    title: job.title || "MPSHOP",
    body: job.body || "",
    link: job.link || "",
    image: job.image || "",
    kind: job.kind || "system",
    tag: job.tag || "mp-" + job.id,
  };
  try {
    const body = await encryptPayload({ p256dh: job.p256dh, auth: job.auth }, enc.encode(JSON.stringify(payload)));
    const res = await fetch(job.endpoint, {
      method: "POST",
      headers: {
        Authorization: await vapidHeader(job.endpoint),
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: "86400",
        Urgency: ORDER_KINDS.has(payload.kind) ? "high" : "normal",
      },
      body,
      signal: AbortSignal.timeout(12000),
    });
    if (res.status === 200 || res.status === 201 || res.status === 202) return { status: "sent", http: res.status };
    if (res.status === 404 || res.status === 410) return { status: "gone", http: res.status };
    const text = await res.text().catch(() => "");
    if (res.status === 429 || res.status >= 500) {
      return { status: job.attempts >= 4 ? "failed" : "retry", http: res.status, error: (text || "HTTP " + res.status).slice(0, 300) };
    }
    return { status: "failed", http: res.status, error: (text || "HTTP " + res.status).slice(0, 300) };
  } catch (e: any) {
    const msg = String((e && e.message) || e).slice(0, 300);
    return { status: job.attempts >= 4 ? "failed" : "retry", error: msg };
  }
}

/* ---------- REST (service role) ---------- */
async function rpc(name: string, args: Record<string, unknown>): Promise<any> {
  const base = mustEnv("SUPABASE_URL").replace(/\/+$/, "");
  const key = mustEnv("SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(base + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify(args || {}),
    signal: AbortSignal.timeout(15000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error("rpc_" + name + "_" + res.status + ": " + text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}

/* ---------- ระบายคิว ---------- */
export type DrainResult = {
  sent: number; failed: number; gone: number; retry: number; claimed: number; batches: number;
};

export async function drain(limitPerBatch = 50, maxBatches = 25): Promise<DrainResult> {
  const out: DrainResult = { sent: 0, failed: 0, gone: 0, retry: 0, claimed: 0, batches: 0 };

  for (let b = 0; b < maxBatches; b++) {
    const jobs = await rpc("push_claim", { p_limit: limitPerBatch });
    const list: Job[] = Array.isArray(jobs) ? jobs : [];
    if (!list.length) break;
    out.batches++;
    out.claimed += list.length;

    // ทีละชุดเล็ก ๆ เพื่อไม่ให้ push service มองว่าเป็นสแปม
    const CONCURRENCY = 10;
    for (let i = 0; i < list.length; i += CONCURRENCY) {
      const slice = list.slice(i, i + CONCURRENCY);
      const results = await Promise.all(slice.map((j) => sendOne(j)));
      const reports = slice.map((j, k) => {
        const r = results[k];
        out[r.status]++;
        return { p_outbox: j.id, p_status: r.status, p_error: r.error || null, p_http: r.http || null };
      });
      await rpc("push_report", { p_results: reports });
    }
    if (list.length < limitPerBatch) break;
  }
  return out;
}

/* ---------- HTTP ---------- */
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
}

export async function handler(req: Request): Promise<Response> {
  try {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { "Access-Control-Allow-Origin": "*" } });
    if (req.method === "GET") {
      // เรียกครั้งแรกจะสร้างกุญแจ VAPID ให้เอง — ไม่คืนสถานะคิวให้คนนอกแล้ว
      const keys = await vapidKeys();
      return json({ ok: true, service: "mpshop-push", vapid_public_key: keys.pub });
    }
    if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

    const need = drainSecret();
    if (need && req.headers.get("x-mpshop-key") !== need) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    const started = Date.now();
    const res = await drain();
    return json({ ok: true, ...res, ms: Date.now() - started });
  } catch (e: any) {
    return json({ ok: false, error: String((e && e.message) || e).slice(0, 400) }, 500);
  }
}

if (typeof (globalThis as any).Deno !== "undefined" && typeof (globalThis as any).Deno.serve === "function") {
  (globalThis as any).Deno.serve(handler);
}
