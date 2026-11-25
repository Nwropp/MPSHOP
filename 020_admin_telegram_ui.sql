-- 020: ควบคุมการแจ้งเตือน Telegram จากหน้าหลังบ้าน
-- token ถูกเขียนเข้าฐานข้อมูลเท่านั้น ฝั่งเบราว์เซอร์อ่านกลับไม่ได้ (RPC คืนแค่สถานะ)

alter table public.integrations
  add column if not exists telegram_enabled boolean not null default true;

create or replace function public.admin_telegram_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare i public.integrations;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select * into i from public.integrations where id = 1;
  return jsonb_build_object(
    'has_token', coalesce(i.telegram_bot_token, '') <> '',
    'chat_id', coalesce(i.telegram_chat_id, ''),
    'enabled', coalesce(i.telegram_enabled, true)
  );
end $$;

create or replace function public.admin_set_telegram(p_token text default null, p_chat_id text default null, p_enabled boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare i public.integrations;
        t text := nullif(btrim(coalesce(p_token, '')), '');
        c text := nullif(btrim(coalesce(p_chat_id, '')), '');
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if t is not null and t !~ '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$' then raise exception 'invalid_token'; end if;
  if c is not null and c !~ '^-?[0-9]{4,20}$' then raise exception 'invalid_chat_id'; end if;
  update public.integrations
     set telegram_bot_token = coalesce(t, telegram_bot_token),
         telegram_chat_id = coalesce(c, telegram_chat_id),
         telegram_enabled = coalesce(p_enabled, telegram_enabled)
   where id = 1;
  select * into i from public.integrations where id = 1;
  if coalesce(i.telegram_enabled, false)
     and (coalesce(i.telegram_bot_token, '') = '' or coalesce(i.telegram_chat_id, '') = '') then
    raise exception 'telegram_not_configured';
  end if;
  return jsonb_build_object(
    'has_token', coalesce(i.telegram_bot_token, '') <> '',
    'chat_id', coalesce(i.telegram_chat_id, ''),
    'enabled', coalesce(i.telegram_enabled, true)
  );
end $$;

create or replace function public.admin_clear_telegram()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  update public.integrations
     set telegram_bot_token = null, telegram_enabled = false
   where id = 1;
  return jsonb_build_object(
    'has_token', false,
    'chat_id', coalesce((select telegram_chat_id from public.integrations where id = 1), ''),
    'enabled', false
  );
end $$;

create or replace function public.admin_test_telegram()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare ok boolean;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if not exists (
    select 1 from public.integrations
     where id = 1
       and coalesce(telegram_enabled, false)
       and coalesce(telegram_bot_token, '') <> ''
       and coalesce(telegram_chat_id, '') <> ''
  ) then
    raise exception 'telegram_not_configured';
  end if;
  ok := public.send_telegram('✅ ทดสอบการเชื่อมต่อ Telegram Bot จาก MPSHOP สำเร็จ');
  if not ok then raise exception 'telegram_send_failed'; end if;
end $$;

create or replace function public.notify_order_telegram()
returns trigger
language plpgsql
security definer
set search_path = public, net
as $$
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
	if coalesce(i.telegram_enabled, true) is not true then
		update public.telegram_notifications
			set status = 'failed', error = 'telegram_disabled', updated_at = now()
			where order_id = new.id;
		return new;
	end if;
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
		update public.telegram_notifications
			set status = 'failed', error = left(sqlerrm, 500), updated_at = now()
			where order_id = new.id;
		return new;
end;
$$;
