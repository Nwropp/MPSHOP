-- 018: Security & performance hardening
--
-- สิ่งที่แก้ (ต่อยอดของเดิม ไม่ลบข้อมูล ไม่เปลี่ยน schema ที่หน้าเว็บใช้):
--  1) cron รายนาทีสำหรับแจ้งเตือนที่ตั้งเวลาไว้ (เดิมพึ่งเบราว์เซอร์ของใครก็ได้ที่เปิดเว็บอยู่)
--  2) index ของตารางที่ถูก query บ่อย (เดิมมีแค่ primary key)
--  3) revoke EXECUTE ของฟังก์ชัน trigger ภายในไม่ให้ anon/authenticated เรียกผ่าน RPC
--  4) แทนที่ view public_queue (SECURITY DEFINER view) ด้วยฟังก์ชันที่คุมจำนวนแถว/คอลัมน์ได้
--  5) ห้ามลบออเดอร์แบบถาวร (เดิม cascadel้าง transactions/order_finance/order_history)
--  6) ช่องทางใส่ shared secret ให้ push-send (edge function) แบบไม่ต้อง redeploy ตอนเปิดใช้

-- ───────── 1) แจ้งเตือนตั้งเวลา: ใช้ cron ทุกนาที ─────────
do $$
begin
  if exists (select 1 from cron.job where jobname = 'mpshop-notif-dispatch') then
    perform cron.unschedule('mpshop-notif-dispatch');
  end if;
end $$;

select cron.schedule(
  'mpshop-notif-dispatch',
  '* * * * *',
  $cron$select public.dispatch_due_notifications()$cron$
);

-- ───────── 2) index ─────────
create index if not exists orders_user_idx          on public.orders (user_id);
create index if not exists orders_assigned_idx      on public.orders (assigned_to) where assigned_to is not null;
create index if not exists orders_created_idx       on public.orders (created_at desc);
create index if not exists orders_status_idx        on public.orders (status);
create index if not exists order_history_order_idx  on public.order_history (order_id);
create index if not exists order_items_order_idx    on public.order_items (order_id);
create index if not exists order_notes_order_idx    on public.order_notes (order_id);
create index if not exists order_updates_order_idx  on public.order_updates (order_id);
create index if not exists order_evidence_order_idx on public.order_evidence (order_id);
create index if not exists order_finance_order_idx  on public.order_finance (order_id);
create index if not exists reviews_order_idx        on public.reviews (order_id);
create index if not exists points_ledger_user_idx   on public.points_ledger (user_id);
create index if not exists coupon_redemptions_order_idx on public.coupon_redemptions (order_id);
create index if not exists profiles_role_idx        on public.profiles (role);
create index if not exists notif_campaign_status_idx on public.notification_campaigns (status, scheduled_at);

-- ───────── 3) ฟังก์ชันภายใน (trigger helpers) ไม่ต้องเปิดให้เรียกผ่าน RPC ─────────
revoke execute on function public._push_enqueue() from anon, authenticated, public;
revoke execute on function public._notifications_enrich() from anon, authenticated, public;
revoke execute on function public._trg_notify_order_update() from anon, authenticated, public;
revoke execute on function public._trg_notify_order_evidence() from anon, authenticated, public;

-- ───────── 4) คิวสาธารณะ: ฟังก์ชันแทน view (คุมคอลัมน์ + จำนวนแถว + ไม่ขึ้น advisor) ─────────
create or replace function public.public_queue_list(p_limit integer default 50)
returns table (no integer, name text, items text, status text, mine boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select o.no,
         left(o.name, greatest(1, least(4, length(o.name) - 1))) || '***' as name,
         o.items,
         o.status,
         o.user_id = auth.uid() as mine
    from public.orders o
   where o.status <> 'cancelled'
   order by o.no
   limit greatest(1, least(200, coalesce(p_limit, 50)));
$fn$;

revoke all on function public.public_queue_list(integer) from public;
grant execute on function public.public_queue_list(integer) to anon, authenticated;

drop view if exists public.public_queue;

-- ───────── 5) ห้ามลบออเดอร์ถาวร (ใช้ยกเลิกแทน) ─────────
revoke delete on public.orders from anon, authenticated;

-- ───────── 6) push drain: ส่ง shared secret ได้ถ้าตั้งค่าไว้ ─────────
alter table public.push_runtime add column if not exists drain_secret text;

create or replace function public._push_kick(p_force boolean default false)
returns bigint
language plpgsql
security definer
set search_path = public
as $fn$
declare u text; sec text; req bigint;
begin
  update public.push_runtime
     set last_kick_at = now(), kick_count = push_runtime.kick_count + 1
   where push_runtime.id
     and (p_force or push_runtime.last_kick_at is null or push_runtime.last_kick_at < now() - interval '3 seconds')
  returning drain_url, drain_secret into u, sec;

  if u is null then return null; end if;

  begin
    select net.http_post(
      url := u,
      body := jsonb_build_object('source', 'db'),
      params := '{}'::jsonb,
      headers := case
                   when coalesce(btrim(sec), '') = '' then jsonb_build_object('Content-Type', 'application/json')
                   else jsonb_build_object('Content-Type', 'application/json', 'x-mpshop-key', sec)
                 end,
      timeout_milliseconds := 8000
    ) into req;
  exception when others then
    raise warning 'push kick skipped: %', sqlerrm;
    req := null;
  end;

  return req;
end
$fn$;

-- ให้ PostgREST เห็น schema ใหม่ทันที
notify pgrst, 'reload schema';
