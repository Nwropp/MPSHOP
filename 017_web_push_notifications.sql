-- MPSHOP · Web Push Notification (017)
-- ---------------------------------------------------------------------------
-- ต่อยอดระบบแจ้งเตือนเดิม (public.notifications / notification_campaigns / profiles)
-- ไม่ลบหรือแก้ข้อมูลเดิม: เพิ่มคอลัมน์ ตาราง และฟังก์ชันใหม่ทั้งหมด
-- ทุก notification ที่ถูกสร้างจากทางใดก็ตาม (orders trigger เดิม / order_evidence /
-- order_updates / แคมเปญแอดมิน / โปรโมชั่น) จะถูกคัดลอกเข้าคิว push_outbox อัตโนมัติ
-- แล้วส่งออกด้วย Edge Function "push-send" (Web Push มาตรฐาน RFC 8291 + VAPID)
-- ---------------------------------------------------------------------------

-- ───────── 1) การตั้งค่าประเภทการแจ้งเตือนของลูกค้า ─────────
alter table public.profiles add column if not exists push_orders boolean not null default true;
alter table public.profiles add column if not exists push_promos boolean not null default true;
alter table public.profiles add column if not exists push_news   boolean not null default true;

-- ───────── 2) อุปกรณ์ที่สมัครรับการแจ้งเตือน (1 บัญชี = หลายอุปกรณ์) ─────────
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  ua text,
  platform text,
  enabled boolean not null default true,
  fail_count integer not null default 0,
  last_error text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_subscriptions_endpoint_len check (char_length(endpoint) between 20 and 2000),
  constraint push_subscriptions_p256dh_len check (char_length(p256dh) between 40 and 200),
  constraint push_subscriptions_auth_len check (char_length(auth) between 8 and 120)
);
create unique index if not exists push_subscriptions_endpoint_uidx on public.push_subscriptions (endpoint);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
-- ลูกค้าอ่าน/เขียนตารางนี้ตรง ๆ ไม่ได้เลย (ต้องผ่าน RPC ที่ผูกกับ auth.uid() เท่านั้น)
-- จึงไม่มีทางเห็น endpoint ของคนอื่น
revoke all on public.push_subscriptions from anon, authenticated;

-- ───────── 3) คิวส่ง push (1 แถว = 1 อุปกรณ์ของ 1 แจ้งเตือน) ─────────
create table if not exists public.push_outbox (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  subscription_id uuid references public.push_subscriptions(id) on delete set null,
  notification_id uuid references public.notifications(id) on delete cascade,
  campaign_id uuid references public.notification_campaigns(id) on delete set null,
  kind text not null default 'system',
  title text not null,
  body text not null default '',
  link_url text,
  image_url text,
  tag text,
  status text not null default 'pending'
    check (status in ('pending','sending','sent','failed','gone','skipped','expired')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  sent_at timestamptz,
  clicked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);
create index if not exists push_outbox_pending_idx on public.push_outbox (next_attempt_at) where status = 'pending';
create index if not exists push_outbox_user_idx on public.push_outbox (user_id, created_at desc);
create index if not exists push_outbox_campaign_idx on public.push_outbox (campaign_id);

alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

-- ───────── 4) ที่อยู่ของตัวส่ง + ตัวกันเรียกซ้ำถี่เกินไป ─────────
create table if not exists public.push_runtime (
  id boolean primary key default true,
  drain_url text not null,
  last_kick_at timestamptz,
  last_drain_at timestamptz,
  kick_count bigint not null default 0,
  created_at timestamptz not null default now(),
  constraint push_runtime_single check (id)
);
alter table public.push_runtime enable row level security;
revoke all on public.push_runtime from anon, authenticated;

insert into public.push_runtime (id, drain_url)
values (true, 'https://jhntnqqnurljeugujitu.supabase.co/functions/v1/push-send')
on conflict (id) do update set drain_url = excluded.drain_url;

-- กุญแจ VAPID: ตัวส่งสร้างเองครั้งแรกแล้วเก็บที่นี่ (อ่านได้เฉพาะ service_role)
-- public key เปิดให้เว็บเรียกได้ เพราะต้องใช้ตอนขออนุญาตแจ้งเตือน
create table if not exists public.push_vapid (
  id boolean primary key default true,
  public_key text not null,
  private_key text not null,
  subject text not null default 'mailto:noreply@mpshop.shop',
  created_at timestamptz not null default now(),
  constraint push_vapid_single check (id)
);
alter table public.push_vapid enable row level security;
revoke all on public.push_vapid from anon, authenticated;

create or replace function public.push_vapid_get() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public_key', v.public_key, 'private_key', v.private_key, 'subject', v.subject)
  from public.push_vapid v where v.id;
$$;
revoke execute on function public.push_vapid_get() from public, anon, authenticated;
grant execute on function public.push_vapid_get() to service_role;

create or replace function public.push_vapid_set(p_public text, p_private text, p_subject text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.push_vapid (id, public_key, private_key, subject)
  values (true, p_public, p_private,
          coalesce(nullif(btrim(coalesce(p_subject, '')), ''), 'mailto:noreply@mpshop.shop'))
  on conflict (id) do nothing;
  return public.push_vapid_get();
end $$;
revoke execute on function public.push_vapid_set(text,text,text) from public, anon, authenticated;
grant execute on function public.push_vapid_set(text,text,text) to service_role;

create or replace function public.push_public_key() returns text
language sql stable security definer set search_path = public as $$
  select public_key from public.push_vapid where id;
$$;
revoke execute on function public.push_public_key() from public;
grant execute on function public.push_public_key() to anon, authenticated;

-- ───────── 5) ปลุกตัวส่งทันทีผ่าน pg_net (จำกัด 1 ครั้ง / 3 วินาที) ─────────
create or replace function public._push_kick(p_force boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare u text; req bigint;
begin
  update public.push_runtime
     set last_kick_at = now(), kick_count = push_runtime.kick_count + 1
   where push_runtime.id
     and (p_force or push_runtime.last_kick_at is null
          or push_runtime.last_kick_at < now() - interval '3 seconds')
  returning drain_url into u;
  if u is null then return null; end if;
  begin
    select net.http_post(
      url := u,
      body := jsonb_build_object('source', 'db'),
      params := '{}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 8000
    ) into req;
  exception when others then
    -- ถ้า pg_net ใช้ไม่ได้ งานจะยังอยู่ในคิวและถูกส่งรอบถัดไป (cron / การเปิดเว็บของลูกค้า)
    raise warning 'push kick skipped: %', sqlerrm;
    req := null;
  end;
  return req;
end $$;
revoke execute on function public._push_kick(boolean) from public, anon, authenticated;

-- ───────── 6) ทุก notification ใหม่ → เข้าคิว push ตามอุปกรณ์และประเภทที่ลูกค้าเปิดรับ ─────────
create or replace function public._push_enqueue() returns trigger
language plpgsql security definer set search_path = public as $$
declare prefs record; allow boolean := true; n int := 0;
begin
  begin
    select p.push_orders, p.push_promos, p.push_news into prefs
      from public.profiles p where p.id = new.user_id;
    if not found then return new; end if;

    -- ออเดอร์ต้องแจ้งเสมอถ้าลูกค้าเปิดหมวดออเดอร์ไว้ (ปิดโปรโมชั่นไม่กระทบงาน)
    if new.kind like 'order%' then allow := prefs.push_orders;
    elsif new.kind = 'promotion' then allow := prefs.push_promos;
    else allow := prefs.push_news;
    end if;
    if not allow then return new; end if;

    insert into public.push_outbox
      (user_id, subscription_id, notification_id, campaign_id, kind, title, body, link_url, image_url, tag)
    select s.user_id, s.id, new.id, new.campaign_id,
           coalesce(nullif(new.kind, ''), 'system'),
           coalesce(nullif(new.title, ''), 'MPSHOP'),
           coalesce(new.body, ''),
           new.link_url, new.image_url,
           'mp-' || substr(md5(coalesce(new.order_id::text, new.campaign_id::text, new.id::text)), 1, 16)
      from public.push_subscriptions s
     where s.user_id = new.user_id and s.enabled and s.fail_count < 5;

    get diagnostics n = row_count;
    if n > 0 then perform public._push_kick(); end if;
  exception when others then
    -- ห้ามให้ระบบ push ทำให้การจอง/อัปเดตงานของร้านล้มเหลว
    raise warning 'push enqueue skipped: %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists notifications_push_trg on public.notifications;
create trigger notifications_push_trg after insert on public.notifications
  for each row execute function public._push_enqueue();

-- ───────── 7) ฝั่งลูกค้า: ลงทะเบียน/ยกเลิกอุปกรณ์, ตั้งค่า, นับคลิก ─────────
create or replace function public.my_push_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'devices', coalesce((select count(*) from public.push_subscriptions s
                          where s.user_id = auth.uid() and s.enabled), 0),
    'devices_total', coalesce((select count(*) from public.push_subscriptions s
                                where s.user_id = auth.uid()), 0),
    'orders', coalesce(p.push_orders, true),
    'promos', coalesce(p.push_promos, true),
    'news',   coalesce(p.push_news, true)
  )
  from (select 1) one
  left join public.profiles p on p.id = auth.uid();
$$;
revoke execute on function public.my_push_state() from public, anon;
grant execute on function public.my_push_state() to authenticated;

create or replace function public.push_subscribe(
  p_endpoint text, p_p256dh text, p_auth text,
  p_ua text default null, p_platform text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ep text := btrim(coalesce(p_endpoint, '')); r public.push_subscriptions;
begin
  if uid is null then raise exception 'unauthorized'; end if;
  if char_length(ep) not between 20 and 2000 then raise exception 'invalid_endpoint'; end if;
  if coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_+/=-]{40,200}$' then raise exception 'invalid_key'; end if;
  if coalesce(p_auth, '') !~ '^[A-Za-z0-9_+/=-]{8,120}$' then raise exception 'invalid_auth'; end if;

  -- อุปกรณ์เดียวกันเคยผูกกับบัญชีอื่น: ยกเลิกงานค้างของบัญชีเดิมก่อนโอนเครื่องมาให้บัญชีนี้
  update public.push_outbox o
     set status = 'skipped', subscription_id = null, locked_until = null
   where o.status in ('pending','sending')
     and o.subscription_id in (select s.id from public.push_subscriptions s
                                where s.endpoint = ep and s.user_id <> uid);

  insert into public.push_subscriptions
    (user_id, endpoint, p256dh, auth, ua, platform, enabled, fail_count, last_seen_at, updated_at)
  values
    (uid, ep, p_p256dh, p_auth, left(coalesce(p_ua, ''), 300), left(coalesce(p_platform, ''), 40),
     true, 0, now(), now())
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        ua = excluded.ua,
        platform = excluded.platform,
        enabled = true,
        fail_count = 0,
        last_error = null,
        last_seen_at = now(),
        updated_at = now()
  returning * into r;

  return public.my_push_state();
end $$;
revoke execute on function public.push_subscribe(text,text,text,text,text) from public, anon;
grant execute on function public.push_subscribe(text,text,text,text,text) to authenticated;

create or replace function public.push_unsubscribe(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ep text := btrim(coalesce(p_endpoint, ''));
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  delete from public.push_subscriptions
   where user_id = auth.uid() and endpoint = ep;
  return public.my_push_state();
end $$;
revoke execute on function public.push_unsubscribe(text) from public, anon;
grant execute on function public.push_unsubscribe(text) to authenticated;

create or replace function public.push_set_prefs(
  p_orders boolean default null, p_promos boolean default null, p_news boolean default null
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  update public.profiles
     set push_orders = coalesce(p_orders, push_orders),
         push_promos = coalesce(p_promos, push_promos),
         push_news   = coalesce(p_news, push_news)
   where id = auth.uid();
  return public.my_push_state();
end $$;
revoke execute on function public.push_set_prefs(boolean,boolean,boolean) from public, anon;
grant execute on function public.push_set_prefs(boolean,boolean,boolean) to authenticated;

-- ลูกค้ากดเปิดจาก push → นับเป็น "เปิด/คลิก" ของแคมเปญนั้น
create or replace function public.push_mark_click(p_notification uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if auth.uid() is null or p_notification is null then return 0; end if;
  update public.push_outbox
     set clicked_at = now()
   where user_id = auth.uid() and notification_id = p_notification and clicked_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.push_mark_click(uuid) from public, anon;
grant execute on function public.push_mark_click(uuid) to authenticated;

-- ───────── 8) ฝั่งตัวส่ง (service_role เท่านั้น) ─────────
create or replace function public.push_claim(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_limit int := greatest(1, least(100, coalesce(p_limit, 50))); ids bigint[]; v jsonb;
begin
  -- งานที่ตัวส่งตายกลางทาง → คืนเข้าคิว
  update public.push_outbox
     set status = 'pending', locked_until = null
   where status = 'sending' and locked_until is not null and locked_until < now();

  -- งานเก่าเกิน 1 วันไม่ควรเด้งอีก
  update public.push_outbox
     set status = 'expired', locked_until = null
   where status in ('pending','sending') and created_at < now() - interval '24 hours';

  -- จองงานแบบไม่ให้ตัวส่งสองตัวแย่งชิ้นเดียวกัน (ต้องแยกเป็นอีก statement
  -- เพราะ PostgreSQL ไม่ให้ data-modifying CTE อยู่ใน sub-expression)
  select array_agg(t.id) into ids from (
    select o.id
      from public.push_outbox o
      join public.push_subscriptions s
        on s.id = o.subscription_id and s.user_id = o.user_id
     where o.status = 'pending'
       and o.next_attempt_at <= now()
       and s.enabled
       and s.fail_count < 5
     order by o.id
     limit v_limit
     for update of o skip locked
  ) t;
  if ids is null or coalesce(array_length(ids, 1), 0) = 0 then return '[]'::jsonb; end if;

  with upd as (
    update public.push_outbox o
       set status = 'sending',
           locked_until = now() + interval '5 minutes',
           attempts = o.attempts + 1
     where o.id = any (ids)
    returning o.*
  )
  select jsonb_agg(jsonb_build_object(
           'id', u.id,
           'title', u.title,
           'body', u.body,
           'link', u.link_url,
           'image', u.image_url,
           'kind', u.kind,
           'notification_id', u.notification_id,
           'attempts', u.attempts,
           'tag', u.tag,
           'endpoint', s.endpoint,
           'p256dh', s.p256dh,
           'auth', s.auth,
           'subscription_id', s.id
         ) order by u.id)
    into v
    from upd u
    join public.push_subscriptions s on s.id = u.subscription_id;
  return coalesce(v, '[]'::jsonb);
end $$;
revoke execute on function public.push_claim(integer) from public, anon, authenticated;
grant execute on function public.push_claim(integer) to service_role;

create or replace function public.push_report(p_results jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare it jsonb; oid bigint; st text; err text; sid uuid; n int := 0;
begin
  for it in select value from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    oid := nullif(it->>'p_outbox', '')::bigint;
    if oid is null then continue; end if;
    st  := coalesce(nullif(it->>'p_status', ''), 'failed');
    err := left(coalesce(nullif(it->>'p_error', ''), ''), 300);

    select o.subscription_id into sid from public.push_outbox o where o.id = oid;
    if sid is null then
      update public.push_outbox set status = 'skipped', locked_until = null where id = oid;
      continue;
    end if;

    if st = 'sent' then
      update public.push_outbox
         set status = 'sent', sent_at = now(), last_error = null, locked_until = null
       where id = oid;
      update public.push_subscriptions
         set last_seen_at = now(), fail_count = 0, last_error = null, updated_at = now()
       where id = sid;
    elsif st = 'gone' then
      -- endpoint หมดอายุ/ถอนการติดตั้งแล้ว → ปิด subscription ทิ้ง
      update public.push_outbox
         set status = 'gone', locked_until = null,
             last_error = coalesce(nullif(err, ''), 'subscription_expired')
       where id = oid;
      update public.push_outbox
         set status = 'gone', subscription_id = null, locked_until = null
       where subscription_id = sid and status in ('pending','sending');
      delete from public.push_subscriptions where id = sid;
      update public.push_outbox set subscription_id = null where subscription_id = sid;
    elsif st = 'retry' then
      update public.push_outbox
         set status = 'pending',
             locked_until = null,
             last_error = err,
             next_attempt_at = now() + (case least(attempts, 4)
                 when 1 then interval '30 seconds'
                 when 2 then interval '2 minutes'
                 when 3 then interval '10 minutes'
                 else interval '30 minutes' end)
       where id = oid and attempts < 5;
      update public.push_outbox
         set status = 'failed', locked_until = null, last_error = err
       where id = oid and status = 'sending';
      update public.push_subscriptions
         set fail_count = fail_count + 1, last_error = err, updated_at = now()
       where id = sid;
    else
      update public.push_outbox
         set status = 'failed', locked_until = null, last_error = err
       where id = oid;
      update public.push_subscriptions
         set fail_count = fail_count + 1, last_error = err, updated_at = now()
       where id = sid;
    end if;
    n := n + 1;
  end loop;

  update public.push_runtime set last_drain_at = now() where id;
  return n;
end $$;
revoke execute on function public.push_report(jsonb) from public, anon, authenticated;
grant execute on function public.push_report(jsonb) to service_role;

create or replace function public.push_admin_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'pending', (select count(*) from public.push_outbox where status = 'pending'),
    'sending', (select count(*) from public.push_outbox where status = 'sending'),
    'sent_24h', (select count(*) from public.push_outbox
                  where status = 'sent' and sent_at >= now() - interval '24 hours'),
    'failed_24h', (select count(*) from public.push_outbox
                    where status in ('failed','gone') and created_at >= now() - interval '24 hours'),
    'devices', (select count(*) from public.push_subscriptions where enabled),
    'customers', (select count(distinct user_id) from public.push_subscriptions where enabled),
    'last_drain_at', (select last_drain_at from public.push_runtime where id)
  );
$$;
revoke execute on function public.push_admin_state() from public, anon, authenticated;
grant execute on function public.push_admin_state() to service_role;

-- ───────── 9) กลุ่มผู้รับใหม่: ลูกค้าที่เปิดรับ Push ─────────
create or replace function public._notification_audience(p_audience text, p_ids uuid[])
returns setof uuid language plpgsql stable security definer set search_path = public as $$
begin
  if p_audience = 'all' then
    return query select p.id from public.profiles p;
  elsif p_audience = 'customers' then
    return query select p.id from public.profiles p
      where exists (select 1 from public.orders o where o.user_id = p.id);
  elsif p_audience = 'active' then
    return query select p.id from public.profiles p
      where exists (select 1 from public.orders o where o.user_id = p.id
                      and o.status in ('pending','confirmed','doing','waiting'));
  elsif p_audience = 'push' then
    return query select distinct s.user_id
      from public.push_subscriptions s
      join public.profiles p on p.id = s.user_id
     where s.enabled and s.fail_count < 5;
  elsif p_audience = 'selected' then
    return query select p.id from public.profiles p where p.id = any (coalesce(p_ids, '{}'::uuid[]));
  end if;
  return;
end $$;
revoke execute on function public._notification_audience(text,uuid[]) from public, anon, authenticated;

-- ───────── 10) ส่งแคมเปญ: คงพฤติกรรมเดิม + นับจำนวน push ที่เข้าคิว ─────────
create or replace function public._notification_send(p_campaign uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.notification_campaigns; n int := 0; p int := 0;
begin
  select * into c from public.notification_campaigns where id = p_campaign for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if c.status not in ('scheduled','sending') then
    return jsonb_build_object('ok', false, 'reason', 'campaign_locked', 'status', c.status);
  end if;
  update public.notification_campaigns set status = 'sending' where id = c.id;
  insert into public.notifications (user_id, title, body, kind, image_url, link_url, link_label, campaign_id, meta)
  select u, c.title, c.body, c.kind, c.image_url, c.button_url, c.button_label, c.id,
         jsonb_build_object('campaign', c.id, 'promotion', c.promotion_id, 'audience', c.audience)
    from public._notification_audience(c.audience, c.recipient_ids) as u;
  get diagnostics n = row_count;

  update public.notification_campaigns
     set status = 'sent', recipients = n, sent = n, sent_at = now()
   where id = c.id;

  select count(*) into p from public.push_outbox where campaign_id = c.id;
  return jsonb_build_object('ok', true, 'campaign', c.id, 'sent', n, 'push', p);
exception when others then
  update public.notification_campaigns set status = 'failed' where id = p_campaign;
  raise;
end $$;
revoke execute on function public._notification_send(uuid) from public, anon, authenticated;

create or replace function public.admin_send_notification(
  p_title text, p_body text, p_image text default null,
  p_button_label text default null, p_button_url text default null,
  p_audience text default 'all', p_user_ids uuid[] default null,
  p_scheduled_at timestamptz default null, p_kind text default 'custom'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.notification_campaigns; n int; k text;
begin
  if not public.is_shop_admin() then raise exception 'forbidden'; end if;
  if char_length(btrim(coalesce(p_title,''))) between 1 and 120 is not true then raise exception 'invalid_title'; end if;
  if char_length(btrim(coalesce(p_body,''))) between 1 and 1000 is not true then raise exception 'invalid_body'; end if;
  if p_audience not in ('all','customers','active','push','selected') then raise exception 'invalid_audience'; end if;
  if p_audience = 'selected' and coalesce(array_length(p_user_ids, 1), 0) = 0 then raise exception 'no_recipients'; end if;
  if p_image is not null and p_image !~ '^https://' then raise exception 'invalid_image'; end if;
  if p_button_label is not null and char_length(p_button_label) > 40 then raise exception 'invalid_button_label'; end if;
  if p_button_url is not null and p_button_url !~ '^(https://|#)' then raise exception 'invalid_button_url'; end if;
  if p_scheduled_at is not null and p_scheduled_at <= now() then raise exception 'invalid_date'; end if;
  k := case when p_kind in ('custom','promotion','system') then p_kind else 'custom' end;

  select count(*) into n from public._notification_audience(p_audience, p_user_ids);
  if n = 0 then raise exception 'no_recipients'; end if;

  insert into public.notification_campaigns
    (title, body, kind, image_url, button_label, button_url, audience, recipient_ids, recipients,
     status, scheduled_at, created_by)
  values
    (btrim(p_title), btrim(p_body), k, nullif(btrim(coalesce(p_image,'')),''),
     nullif(btrim(coalesce(p_button_label,'')),''), nullif(btrim(coalesce(p_button_url,'')),''),
     p_audience, case when p_audience = 'selected' then p_user_ids else null end, n,
     case when p_scheduled_at is null then 'sending' else 'scheduled' end, p_scheduled_at, auth.uid())
  returning * into c;

  if p_scheduled_at is not null then
    return jsonb_build_object('ok', true, 'campaign', c.id, 'scheduled', true, 'recipients', n, 'sent', 0, 'push', 0);
  end if;
  return public._notification_send(c.id);
end $$;
revoke execute on function public.admin_send_notification(text,text,text,text,text,text,uuid[],timestamptz,text) from public, anon;
grant execute on function public.admin_send_notification(text,text,text,text,text,text,uuid[],timestamptz,text) to authenticated;

-- ───────── 11) ตั้งเวลา: คงเดิม + ปลุกตัวส่งเมื่อถึงเวลา ─────────
create or replace function public.dispatch_due_notifications() returns int
language plpgsql security definer set search_path = public as $$
declare r record; x jsonb; n int := 0;
begin
  for r in select id from public.notification_campaigns
            where status = 'scheduled' and scheduled_at is not null and scheduled_at <= now()
            order by scheduled_at
            limit 20
            for update skip locked
  loop
    x := public._notification_send(r.id);
    n := n + coalesce((x->>'sent')::int, 0);
  end loop;
  -- เก็บงาน push ที่ค้างอยู่ให้หมด (ทำงานได้ทุกครั้งที่มีคนเปิดเว็บ แม้ไม่มี pg_cron)
  perform public._push_kick(true);
  return n;
end $$;
revoke execute on function public.dispatch_due_notifications() from public, anon;
grant execute on function public.dispatch_due_notifications() to authenticated;

-- ───────── 12) ประวัติ/สถิติ: เพิ่มตัวเลขฝั่ง Push ─────────
create or replace function public.admin_notification_dashboard() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.is_shop_admin() then '{}'::jsonb else jsonb_build_object(
    'today_total', (select count(*) from public.notifications n where n.created_at >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
    'today_read', (select count(*) from public.notifications n where n.read_at is not null and n.created_at >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
    'sent_total', (select count(*) from public.notifications),
    'read_total', (select count(*) from public.notifications where read_at is not null),
    'unread_total', (select count(*) from public.notifications where read_at is null),
    'campaigns', (select count(*) from public.notification_campaigns),
    'scheduled', (select count(*) from public.notification_campaigns where status = 'scheduled'),
    'customers', (select count(*) from public.profiles),
    'push_devices', (select count(*) from public.push_subscriptions where enabled),
    'push_customers', (select count(distinct user_id) from public.push_subscriptions where enabled),
    'push_sent_24h', (select count(*) from public.push_outbox where status = 'sent' and sent_at >= now() - interval '24 hours'),
    'push_failed_24h', (select count(*) from public.push_outbox where status in ('failed','gone') and created_at >= now() - interval '24 hours'),
    'push_pending', (select count(*) from public.push_outbox where status in ('pending','sending'))
  ) end;
$$;
revoke execute on function public.admin_notification_dashboard() from public, anon;
grant execute on function public.admin_notification_dashboard() to authenticated;

create or replace function public.admin_notification_history(
  p_kind text default null, p_status text default null,
  p_from date default null, p_to date default null, p_q text default null
) returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_shop_admin() then '[]'::jsonb else coalesce(jsonb_agg(x), '[]'::jsonb) end from (
    select jsonb_build_object(
      'id', c.id, 'title', c.title, 'body', c.body, 'kind', c.kind, 'audience', c.audience,
      'recipients', c.recipients, 'sent', c.sent, 'status', c.status,
      'scheduled_at', c.scheduled_at, 'sent_at', c.sent_at, 'created_at', c.created_at,
      'image_url', c.image_url, 'button_label', c.button_label, 'button_url', c.button_url,
      'created_by_name', coalesce(p.name, 'ระบบ'),
      'sent_now', (select count(*) from public.notifications n where n.campaign_id = c.id),
      'read_count', (select count(*) from public.notifications n where n.campaign_id = c.id and n.read_at is not null),
      'unread_count', (select count(*) from public.notifications n where n.campaign_id = c.id and n.read_at is null),
      'push_targets', (select count(*) from public.push_outbox o where o.campaign_id = c.id),
      'push_sent', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status = 'sent'),
      'push_failed', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status in ('failed','gone')),
      'push_pending', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status in ('pending','sending')),
      'push_clicked', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.clicked_at is not null)
    ) as x, c.created_at
    from public.notification_campaigns c
    left join public.profiles p on p.id = c.created_by
    where (p_kind is null or c.kind = p_kind)
      and (p_status is null or c.status = p_status)
      and (p_from is null or c.created_at >= (p_from::timestamp at time zone 'Asia/Bangkok'))
      and (p_to is null or c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Bangkok'))
      and (
        nullif(btrim(coalesce(p_q,'')), '') is null
        or c.title ilike '%' || btrim(p_q) || '%'
        or c.body ilike '%' || btrim(p_q) || '%'
        or (btrim(p_q) ~ '^[0-9]+$' and exists (
              select 1 from public.notifications n join public.orders o on o.id = n.order_id
               where n.campaign_id = c.id and lpad(o.no::text, 3, '0') like '%' || btrim(p_q) || '%'))
        or exists (
              select 1 from public.notifications n join public.profiles p2 on p2.id = n.user_id
               where n.campaign_id = c.id
                 and (p2.name ilike '%' || btrim(p_q) || '%' or p2.nickname ilike '%' || btrim(p_q) || '%'))
      )
    order by c.created_at desc
    limit 100
  ) q;
$$;
revoke execute on function public.admin_notification_history(text,text,date,date,text) from public, anon;
grant execute on function public.admin_notification_history(text,text,date,date,text) to authenticated;

create or replace function public.admin_notification_detail(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.is_shop_admin() then null else (
    select jsonb_build_object(
      'campaign', jsonb_build_object(
        'id', c.id, 'title', c.title, 'body', c.body, 'kind', c.kind, 'audience', c.audience,
        'recipients', c.recipients, 'sent', c.sent, 'status', c.status,
        'scheduled_at', c.scheduled_at, 'sent_at', c.sent_at, 'created_at', c.created_at,
        'image_url', c.image_url, 'button_label', c.button_label, 'button_url', c.button_url,
        'created_by_name', coalesce(p.name, 'ระบบ')),
      'read_count', (select count(*) from public.notifications n where n.campaign_id = c.id and n.read_at is not null),
      'unread_count', (select count(*) from public.notifications n where n.campaign_id = c.id and n.read_at is null),
      'push', jsonb_build_object(
        'targets', (select count(*) from public.push_outbox o where o.campaign_id = c.id),
        'sent', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status = 'sent'),
        'failed', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status in ('failed','gone')),
        'pending', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.status in ('pending','sending')),
        'clicked', (select count(*) from public.push_outbox o where o.campaign_id = c.id and o.clicked_at is not null)),
      'recipients_sample', coalesce((
        select jsonb_agg(y) from (
          select jsonb_build_object(
            'name', coalesce(nullif(p2.nickname,''), p2.name),
            'avatar_url', p2.avatar_url, 'read_at', n.read_at, 'created_at', n.created_at) as y
            from public.notifications n join public.profiles p2 on p2.id = n.user_id
           where n.campaign_id = c.id order by n.read_at nulls first limit 60) z), '[]'::jsonb)
    )
    from public.notification_campaigns c
    left join public.profiles p on p.id = c.created_by
    where c.id = p_id
  ) end;
$$;
revoke execute on function public.admin_notification_detail(uuid) from public, anon;
grant execute on function public.admin_notification_detail(uuid) to authenticated;

-- ───────── 13) เก็บกวาดคิวเก่า (เฉพาะแจ้งเตือนที่ไม่ได้ผูกแคมเปญ) ─────────
create or replace function public.push_cleanup(p_days integer default 30) returns integer
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  delete from public.push_outbox
   where campaign_id is null
     and status in ('sent','gone','failed','skipped','expired')
     and created_at < now() - make_interval(days => greatest(1, coalesce(p_days, 30)));
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.push_cleanup(integer) from public, anon, authenticated;
grant execute on function public.push_cleanup(integer) to service_role;
