-- MPSHOP · Discord @everyone เมื่อมีการจองคิวสำเร็จ (018)
-- ---------------------------------------------------------------------------
-- ใช้ Webhook เดิมของร้านที่ตั้งค่าไว้ใน public.integrations (หน้าแอดมิน)
-- ไม่ต้องตั้งค่า secret เพิ่ม และไม่ส่ง Webhook URL ออกไปฝั่ง client
--
-- สิ่งที่ทำ:
--   1) ตาราง discord_notifications กันส่งซ้ำต่อออเดอร์ (order_id เป็น PK)
--   2) ฟังก์ชัน send_discord_everyone() ส่งข้อความพร้อม mention @everyone จริง
--   3) notify_order_event(): ส่ง @everyone เฉพาะตอนสร้างออเดอร์ (order_created)
--      ส่วนการเปลี่ยนสถานะอื่นยังใช้ send_discord() แบบเดิม (ไม่ mention)
-- ---------------------------------------------------------------------------

-- ───────── 1) ตารางกันแจ้งซ้ำ + log สำหรับแอดมิน ─────────
create table if not exists public.discord_notifications (
  order_id uuid primary key references public.orders(id) on delete cascade,
  status text not null default 'pending',
  error text,
  sent_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists discord_notifications_status_idx
  on public.discord_notifications (status);

-- ───────── 2) ส่งข้อความพร้อม @everyone จริง ─────────
-- allowed_mentions.parse = ['everyone'] ทำให้ Discord มองเป็น mention ไม่ใช่ตัวอักษร
create or replace function public.send_discord_everyone(p_msg text)
returns boolean
language plpgsql security definer set search_path = public, extensions as $fn$
declare i public.integrations;
begin
  select * into i from public.integrations where id = 1;
  if i.discord_enabled is not true or i.discord_webhook is null or length(i.discord_webhook) = 0 then
    return false;
  end if;
  perform net.http_post(
    url := i.discord_webhook,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object(
      'content', left(p_msg, 1800),
      'allowed_mentions', jsonb_build_object('parse', jsonb_build_array('everyone'))
    )
  );
  return true;
exception when others then
  return false;
end $fn$;

revoke execute on function public.send_discord_everyone(text) from public, anon, authenticated;

-- ───────── 3) ส่ง @everyone เฉพาะตอนจองสำเร็จ ─────────
create or replace function public.notify_order_event() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  ev text; t text; b text; n3 text := '#' || lpad(new.no::text, 3, '0');
  v_first boolean := false;
  v_ok boolean := false;
  v_msg text;
begin
  if tg_op = 'INSERT' then
    ev := 'order_created';
    t  := 'จองคิวสำเร็จ 🎉';
    b  := 'ออเดอร์ ' || n3 || ' ได้รับการยืนยันแล้ว' ||
          case when coalesce(new.items, '') <> '' then ' · ' || left(new.items, 120) else '' end ||
          ' กดเพื่อดูรายละเอียดงาน';
  elsif new.status is distinct from old.status then
    case new.status
      when 'confirmed' then ev := 'order_confirmed'; t := 'ยืนยันออเดอร์แล้ว ✅'; b := 'ออเดอร์ ' || n3 || ' ได้รับการยืนยันแล้ว ทีมงานจะเริ่มดำเนินการเร็ว ๆ นี้';
      when 'doing'     then ev := 'order_doing';     t := 'ทีมงานรับงานแล้ว 🛠️'; b := 'ออเดอร์ ' || n3 || ' กำลังดำเนินการอยู่ กดเพื่อติดตามความคืบหน้า';
      when 'waiting'   then ev := 'order_waiting';   t := 'งานของคุณพักชั่วคราว ⏸'; b := 'ออเดอร์ ' || n3 || ' รอดำเนินการต่อ ทีมงานจะกลับมาทำให้เร็วที่สุด';
      when 'done'      then ev := 'order_done';      t := 'งานเสร็จสมบูรณ์ 🎉'; b := 'ออเดอร์ ' || n3 || ' เสร็จสิ้นแล้ว กดเพื่อดูหลักฐานและรายละเอียดงาน';
      when 'cancelled' then ev := 'order_cancelled'; t := 'ออเดอร์ถูกยกเลิก 🔴'; b := 'ออเดอร์ ' || n3 || ' ถูกยกเลิก หากมีข้อสงสัยติดต่อร้านได้เลย';
      else return null;
    end case;
  else
    return null;
  end if;

  insert into public.notifications (user_id, order_id, event, title, body, kind, link_url, link_label, meta)
  values (new.user_id, new.id, ev, t, b, ev, '#order', 'ดูรายละเอียดงาน',
          jsonb_build_object('no', new.no, 'status', new.status, 'items', new.items, 'total', new.total));

  if ev = 'order_created' then
    -- กันซ้ำ: order_id เป็น PK → แถวเดิมจะไม่ถูก insert และ found = false
    insert into public.discord_notifications (order_id, status)
    values (new.id, 'pending')
    on conflict (order_id) do nothing;
    v_first := found;

    if v_first then
      v_msg := '@everyone' || E'\n' ||
               '🔔 มีลูกค้าจองคิวใหม่!' || E'\n' ||
               '👤 ลูกค้า: ' || coalesce(nullif(btrim(coalesce(new.name, '')), ''), '-') || E'\n' ||
               '📦 งาน: ' || coalesce(nullif(btrim(coalesce(new.items, '')), ''), '-') || E'\n' ||
               '💰 ราคา: ' || coalesce(new.total, 0) || ' ฿' || E'\n' ||
               '🕐 เวลา: ' || to_char(coalesce(new.created_at, now()) at time zone 'Asia/Bangkok', 'DD/MM/YYYY HH24:MI') || E'\n' ||
               '🆔 เลขที่งาน: ' || n3;

      v_ok := public.send_discord_everyone(v_msg);

      update public.discord_notifications
         set status = case when v_ok then 'sent' else 'failed' end,
             error  = case when v_ok then null else 'webhook_not_configured_or_request_failed' end,
             sent_at = case when v_ok then now() else sent_at end,
             updated_at = now()
       where order_id = new.id;
    end if;
  else
    -- สถานะอื่น ๆ: แจ้งแบบเดิม ไม่ mention @everyone
    perform public.send_discord('[' || ev || '] ' || n3 || ' · ' || new.items || ' · ' || new.total || ' ฿ — ' || t);
  end if;

  return null;
end $fn$;
