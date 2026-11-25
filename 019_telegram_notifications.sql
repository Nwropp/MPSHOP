-- 019_telegram_notifications.sql
-- แจ้งเตือน Telegram เมื่อลูกค้าจองคิวสำเร็จ (ทำงานคู่กับ Discord @everyone ใน 018)
-- หลักการ:
--   * ส่งจากฐานข้อมูลเท่านั้น (pg_net) — ไม่มี token ฝั่ง client เลย
--   * 1 ออเดอร์ส่ง 1 ครั้ง กันซ้ำด้วย primary key ของ telegram_notifications(order_id)
--   * ส่งไม่สำเร็จ = บันทึก error ไว้ แต่ไม่ rollback order (exception ถูกกลืนใน trigger)

-- 1) เก็บค่า token/chat id ไว้ที่ integrations เหมือนฝั่ง Discord (RLS: admin เท่านั้น)
alter table public.integrations add column if not exists telegram_bot_token text;
alter table public.integrations add column if not exists telegram_chat_id text;

-- 2) ตารางกันแจ้งซ้ำ + เก็บ log สำหรับแอดมิน
create table if not exists public.telegram_notifications (
	order_id uuid primary key references public.orders(id) on delete cascade,
	status text default 'pending' check (status in ('pending', 'sent', 'failed')),
	error text,
	sent_at timestamp with time zone,
	updated_at timestamp with time zone
);

create index if not exists telegram_notifications_status_idx
	on public.telegram_notifications (status);

alter table public.telegram_notifications enable row level security;

-- ดู log ได้เฉพาะแอดมิน (ไม่ให้ลูกค้าอ่าน)
drop policy if exists "telegram notifications admin only" on public.telegram_notifications;
create policy "telegram notifications admin only"
	on public.telegram_notifications
	for all
	to authenticated
	using (public.is_admin())
	with check (public.is_admin());

-- 3) ฟังก์ชันส่งข้อความ (ต้องมี "bot" นำหน้า token ไม่งั้น Telegram ตอบ 404)
create or replace function public.send_telegram(p_msg text) returns boolean as $$
declare
	i public.integrations;
begin
	select * into i from public.integrations where id = 1;
	if i.telegram_bot_token is null or i.telegram_bot_token not like '%:%' or coalesce(i.telegram_chat_id, '') = '' then
		return false;
	end if;
	perform net.http_post(
		url := 'https://api.telegram.org/bot' || i.telegram_bot_token || '/sendMessage',
		headers := '{"Content-Type":"application/json"}'::jsonb,
		body := jsonb_build_object('chat_id', i.telegram_chat_id, 'text', left(p_msg, 4096))
	);
	return true;
exception
	when others then
		return false;
end;
$$ language plpgsql security definer set search_path = public, net;

revoke all on function public.send_telegram(text) from anon, authenticated;

-- 4) trigger เฉพาะ INSERT (จองคิวสำเร็จ) — ไม่ผูกกับ status change อื่น
create or replace function public.notify_order_telegram() returns trigger as $$
declare
	i public.integrations;
	v_msg text;
	v_ok boolean := false;
	v_first boolean := false;
	n3 text := '#' || lpad(new.no::text, 3, '0');
begin
	if tg_op <> 'INSERT' then
		return new;
	end if;

	-- กันซ้ำ: ถ้ามีแถวอยู่แล้ว (retry/refresh/insert ซ้ำ) จะไม่ส่งอีก
	insert into public.telegram_notifications (order_id, status)
	values (new.id, 'pending')
	on conflict (order_id) do nothing;
	v_first := found;
	if v_first is not true then
		return new;
	end if;

	select * into i from public.integrations where id = 1;

	v_msg := '🚨 มีลูกค้าจองคิวใหม่!' || chr(10) || chr(10)
		|| '👤 ลูกค้า: ' || coalesce(nullif(btrim(coalesce(new.name, '')), ''), '-') || chr(10)
		|| '📦 บริการ: ' || coalesce(nullif(btrim(coalesce(new.items, '')), ''), '-') || chr(10)
		|| '💰 ราคา: ' || coalesce(new.total, 0) || ' ฿' || chr(10)
		|| '🕐 เวลา: ' || to_char(coalesce(new.created_at, now()) at time zone 'Asia/Bangkok', 'DD/MM/YYYY HH24:MI') || chr(10)
		|| '🆔 Order ID: ' || n3 || chr(10) || chr(10)
		|| '📋 สถานะ: รอตรวจสอบ' || chr(10) || chr(10)
		|| 'กรุณาเข้าหลังบ้านเพื่อตรวจสอบงาน';

	if i.telegram_bot_token is null or i.telegram_bot_token not like '%:%' or coalesce(i.telegram_chat_id, '') = '' then
		update public.telegram_notifications
			set status = 'failed', error = 'telegram_not_configured', updated_at = now()
			where order_id = new.id;
		return new;
	end if;

	v_ok := public.send_telegram(v_msg);

	update public.telegram_notifications
		set status = case when v_ok then 'sent' else 'failed' end,
			error = case when v_ok then null else 'request_not_queued' end,
			sent_at = case when v_ok then now() else sent_at end,
			updated_at = now()
		where order_id = new.id;

	return new;
exception
	when others then
		-- ห้ามทำให้การจองล้มเหลว: เก็บ error แล้วไปต่อ
		update public.telegram_notifications
			set status = 'failed', error = left(sqlerrm, 500), updated_at = now()
			where order_id = new.id;
		return new;
end;
$$ language plpgsql security definer set search_path = public, net;

drop trigger if exists orders_telegram on public.orders;
create trigger orders_telegram
	after insert on public.orders
	for each row execute function public.notify_order_telegram();

-- 5) ตรวจว่ายังมี trigger แจ้งเตือนเดิม (Discord @everyone + in-app) อยู่คู่กัน
--    ถ้าหลุด ให้สร้างคืน:
--    create trigger orders_notify after insert or update of status on public.orders
--      for each row execute function public.notify_order_event();

-- หมายเหตุการใช้งาน:
--   ตั้ง token ด้วย (ทำครั้งเดียว, อย่า commit ค่าจริงลง git):
--   update public.integrations set telegram_bot_token = '<BOT_TOKEN>', telegram_chat_id = '-5177687099' where id = 1;
