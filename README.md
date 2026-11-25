# MPSHOP

เว็บร้านรับฟาร์ม Genshin Impact — static site ไฟล์เดียว (`index.html`) + Supabase (Auth, Postgres/RLS, Storage, Edge Function สำหรับ Web Push)

- Production: https://nwropp.github.io/MPSHOP/
- Supabase project: `jhntnqqnurljeugujitu`

## โครงไฟล์

| ไฟล์ | หน้าที่ |
|---|---|
| `index.html` | ทั้งเว็บ (หน้าบ้าน + หลังบ้าน) ใช้ Supabase publishable key เท่านั้น |
| `sw.js` | Service Worker รับ Web Push (ไม่มี fetch handler จึงไม่แคช HTML) |
| `manifest.json` | PWA manifest (จำเป็นสำหรับติดตั้งแอปและ Push บน iOS) |
| `016_*.sql`, `017_*.sql`, `018_hardening.sql` | migration ที่ใช้กับโปรเจกต์นี้ |
| `supabase/functions/push-send/index.ts` | Edge Function ระบายคิว `push_outbox` แล้วส่ง Push จริง |

## สิ่งที่ตั้งค่าไว้แล้ว

- **Auth**: Email/Password + Google OAuth, `site_url` = `https://nwropp.github.io/MPSHOP/`, redirect allow list รวม prod และ `http://localhost:3001/**`
- **Cron (`pg_cron`)**
  - `mpshop-push-drain` ทุกนาที → `_push_kick(true)`
  - `mpshop-notif-dispatch` ทุกนาที → `dispatch_due_notifications()` (ส่งแคมเปญที่ตั้งเวลาไว้)
- **Storage**: `avatars` (public read / เขียนเฉพาะโฟลเดอร์ตัวเอง), `service-images` (public read / เขียนเฉพาะแอดมิน), `evidence` (private, อ่านตามออเดอร์)

## งานที่ต้องทำเองใน Dashboard (ทำจาก repo ไม่ได้)

1. **SMTP ของตัวเอง** — Authentication → Emails → SMTP Settings
   ตอนนี้ใช้ mailer ของ Supabase (จำกัด ~2 เมล/ชั่วโมง) ทำให้ลิงก์ยืนยันอีเมลและลิงก์ "ลืมรหัสผ่าน" ถึงช้า/ไม่ถึง
2. **นโยบายรหัสผ่าน** — Authentication → Policies: ตั้ง Minimum length = 8, เปิด "Check against HaveIBeenPwned", เปิด "Require current password when updating"
   (หน้าเว็บตรวจ 8 ตัวแล้ว แต่ฝั่งเซิร์ฟเวอร์ยังเป็น 6)
3. **MFA (TOTP)** — ผูกให้บัญชี owner/admin อย่างน้อย 1 บัญชี
4. **Discord Login** — ต้องสร้างแอปใน Discord Developer Portal ก่อน (ดูหัวข้อถัดไป)

## เปิด Discord Login

1. https://discord.com/developers/applications → New Application
2. OAuth2 → เพิ่ม Redirect `https://jhntnqqnurljeugujitu.supabase.co/auth/v1/callback`
3. คัดลอก Client ID / Client Secret
4. เปิดใน Supabase: Authentication → Providers → Discord (หรือส่งค่าให้ผู้ดูแลระบบตั้งผ่าน Management API)
5. ปุ่ม "เข้าสู่ระบบด้วย Discord" ในหน้าเว็บจะโผล่เองเมื่อ `/auth/v1/settings` รายงานว่า `discord = true`

## Push Notification

- ฝั่งเว็บเรียก RPC `push_subscribe` หลังผู้ใช้อนุญาต; คิวอยู่ที่ `push_outbox`
- Edge Function `push-send` ต้อง deploy ด้วย Supabase CLI: `supabase functions deploy push-send`
- ถ้าต้องการบังคับ shared secret: ตั้ง env `PUSH_DRAIN_SECRET` ของฟังก์ชัน แล้ว
  `update public.push_runtime set drain_secret = '<ค่าเดียวกัน>';`
  (ถ้าไม่ตั้ง ฟังก์ชันจะเปิดรับ POST เหมือนเดิม เพื่อไม่ให้คิวหยุด)
- iOS ต้องติดตั้งเว็บลง Home Screen ก่อน จึงจะรับ Push ได้

## Deploy

GitHub Pages เสิร์ฟจาก branch `main` โดยตรง — push ไฟล์ที่แก้แล้วรอ 1–2 นาที
ไม่มีขั้นตอน build; ถ้าแก้ `index.html` ให้ทดสอบ local ก่อน:

```bash
python3 -m http.server 3001 --bind 0.0.0.0
```
