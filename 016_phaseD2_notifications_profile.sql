-- 016 (Phase D2): Customer Notification Center + Admin Broadcast + Customer Profile
--
-- หลักการ:
--  * ต่อยอดของเดิมทั้งหมด: ใช้ตาราง orders / profiles / promotions / reviews / auth เดิม
--    ไม่สร้างระบบจองซ้ำ และไม่แตะตาราง/ฟังก์ชันเดิมของ Phase ก่อนหน้า
--  * Notification ทุกใบผูกกับข้อมูลจริง (order_id / campaign_id) และถูกสร้างจาก trigger
--    ของเหตุการณ์จริงในฐานข้อมูล ไม่ใช่ข้อความหลอกที่ฝั่งหน้าจอ
--  * ลูกค้าอ่าน/อัปเดตสถานะอ่านได้เฉพาะของตัวเอง (RLS แบบ restrictive กัน policy เก่าที่หลวม)
--  * แอดมิน/เจ้าของเท่านั้นที่สร้างแคมเปญ ดูประวัติ และดูสถิติของผู้รับทุกคน
--  * โปรไฟล์: ชื่อที่แสดง / ชื่อเล่น / ข้อความแนะนำตัว / รูปโปรไฟล์ (bucket avatars)
--    และแก้ไขได้เฉพาะแถวของตัวเองผ่านฟังก์ชันฝั่งเซิร์ฟเวอร์

-- ───────── helpers ─────────
create or replace function public.is_shop_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and (coalesce(p.is_admin, false) or coalesce(p.role, 'customer') in ('owner','admin','manager'))
  );
$$;
revoke execute on function public.is_shop_admin() from public, anon;
grant execute on function public.is_shop_admin() to authenticated;

-- ───────── 1) ตาราง notifications: ต่อของเดิม (ถ้ามี) หรือสร้างใหม่ ─────────
do $$ begin
  if to_regclass('public.notifications') is null then
    create table public.notifications (
      id uuid primary key default gen_random_uuid(),
      user_id uuid not null references public.profiles(id) on delete cascade,
      title text not null,
      body text,
      read_at timestamptz,
      created_at timestamptz not null default now()
    );
  end if;
end $$;

alter table public.notifications add column if not exists user_id uuid;
alter table public.notifications add column if not exists title text;
alter table public.notifications add column if not exists body text;
alter table public.notifications add column if not exists read_at timestamptz;
alter table public.notifications add column if not exists created_at timestamptz not null default now();
alter table public.notifications add column if not exists kind text not null default 'system';
alter table public.notifications add column if not exists order_id uuid;
alter table public.notifications add column if not exists campaign_id uuid;
alter table public.notifications add column if not exists image_url text;
alter table public.notifications add column if not exists link_url text;
alter table public.notifications add column if not exists link_label text;
alter table public.notifications add column if not exists meta jsonb;

alter table public.notifications alter column created_at set default now();
alter table public.notifications alter column kind set default 'system';

create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index if not exists notifications_campaign_idx on public.notifications (campaign_id);

-- ───────── 2) แคมเปญแจ้งเตือนจากหลังบ้าน ─────────
create table if not exists public.notification_campaigns (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  kind text not null default 'custom' check (kind in ('custom','promotion','system')),
  image_url text check (image_url is null or (char_length(image_url) <= 500 and image_url ~ '^https://')),
  button_label text check (button_label is null or char_length(button_label) <= 40),
  button_url text check (button_url is null or (char_length(button_url) <= 500 and button_url ~ '^(https://|#)')),
  audience text not null default 'all' check (audience in ('all','customers','active','selected')),
  recipient_ids uuid[],
  recipients int not null default 0 check (recipients >= 0),
  sent int not null default 0 check (sent >= 0),
  status text not null default 'draft' check (status in ('draft','scheduled','sending','sent','cancelled','failed')),
  scheduled_at timestamptz,
  sent_at timestamptz,
  promotion_id uuid,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists notification_campaigns_created_idx on public.notification_campaigns (created_at desc);
create index if not exists notification_campaigns_status_idx on public.notification_campaigns (status, scheduled_at);

-- FK ของ notifications.order_id / campaign_id (เพิ่มแบบมีเงื่อนไข)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notifications_order_fk') then
    begin
      alter table public.notifications add constraint notifications_order_fk
        foreign key (order_id) references public.orders(id) on delete cascade;
    exception when others then raise warning 'skip notifications_order_fk: %', sqlerrm;
    end;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'notifications_campaign_fk') then
    begin
      alter table public.notifications add constraint notifications_campaign_fk
        foreign key (campaign_id) references public.notification_campaigns(id) on delete set null;
    exception when others then raise warning 'skip notifications_campaign_fk: %', sqlerrm;
    end;
  end if;
end $$;

-- ───────── 3) RLS: ลูกค้าเห็นเฉพาะของตัวเอง / แอดมินเห็นของทุกคน ─────────
alter table public.notifications enable row level security;
alter table public.notification_campaigns enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='notifications read own') then
    create policy "notifications read own" on public.notifications
      for select using (user_id = auth.uid() or public.is_owner());
  end if;
  -- restrictive: กัน policy เดิมที่อาจหลวม (ต้องผ่านทั้งสองเงื่อนไข)
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='notifications read own strict') then
    create policy "notifications read own strict" on public.notifications
      as restrictive for select using (user_id = auth.uid() or public.is_owner());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='notifications read mark') then
    create policy "notifications read mark" on public.notifications
      for update using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='notifications read mark strict') then
    create policy "notifications read mark strict" on public.notifications
      as restrictive for update using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='notification_campaigns' and policyname='campaigns admin read') then
    create policy "campaigns admin read" on public.notification_campaigns
      for select using (public.is_shop_admin());
  end if;
end $$;

revoke all on public.notifications from anon, authenticated;
revoke all on public.notification_campaigns from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant select on public.notification_campaigns to authenticated;

-- ───────── 4) ข้อความอัปเดตถึงลูกค้า (คนละตารางกับ order_notes ที่เป็นหมายเหตุภายใน) ─────────
create table if not exists public.order_updates (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  message text not null check (char_length(btrim(message)) between 1 and 1000),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists order_updates_order_idx on public.order_updates (order_id, created_at desc);
alter table public.order_updates enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='order_updates' and policyname='order updates read own') then
    create policy "order updates read own" on public.order_updates for select using (
      public.is_shop_admin()
      or exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
    );
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='order_updates' and policyname='order updates admin write') then
    create policy "order updates admin write" on public.order_updates for all using (public.is_shop_admin()) with check (public.is_shop_admin());
  end if;
end $$;
revoke all on public.order_updates from anon, authenticated;
grant select, insert on public.order_updates to authenticated;

-- ───────── 5) โปรไฟล์ลูกค้า ─────────
alter table public.profiles add column if not exists nickname text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_nickname_len') then
    alter table public.profiles add constraint profiles_nickname_len check (nickname is null or char_length(btrim(nickname)) between 1 and 30);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_len') then
    alter table public.profiles add constraint profiles_bio_len check (bio is null or char_length(bio) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_len') then
    alter table public.profiles add constraint profiles_avatar_len check (avatar_url is null or char_length(avatar_url) <= 300);
  end if;
exception when others then raise warning 'skip profile constraints: %', sqlerrm;
end $$;

-- ลูกค้าแก้ไขได้เฉพาะแถวโปรไฟล์ของตัวเอง (restrictive กัน policy เดิมที่หลวม)
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='profiles' and policyname='profiles self update only') then
    create policy "profiles self update only" on public.profiles
      as restrictive for update
      using (id = auth.uid() or public.is_shop_admin())
      with check (id = auth.uid() or public.is_shop_admin());
  end if;
end $$;

-- bucket รูปโปรไฟล์ (อ่านสาธารณะ, เขียนได้เฉพาะโฟลเดอร์ของตัวเอง)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='avatars public read') then
    create policy "avatars public read" on storage.objects for select using (bucket_id = 'avatars');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='avatars own insert') then
    create policy "avatars own insert" on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='avatars own update') then
    create policy "avatars own update" on storage.objects for update to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
      with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='avatars own delete') then
    create policy "avatars own delete" on storage.objects for delete to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

-- ───────── 6) ฟังก์ชันกลางของ notification ─────────
create or replace function public._notify_user(
  p_user uuid, p_title text, p_body text, p_kind text,
  p_order uuid default null, p_image text default null,
  p_link text default null, p_label text default null, p_meta jsonb default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  insert into public.notifications (user_id, title, body, kind, order_id, image_url, link_url, link_label, meta)
  values (p_user, left(coalesce(p_title,'แจ้งเตือน'), 120), left(coalesce(p_body,''), 1000),
          coalesce(p_kind,'system'), p_order, p_image, p_link, p_label, p_meta);
end $$;
revoke execute on function public._notify_user(uuid,text,text,text,uuid,text,text,text,jsonb) from public, anon, authenticated;

-- ผู้รับตามกลุ่มที่แอดมินเลือก
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
  elsif p_audience = 'selected' then
    return query select p.id from public.profiles p where p.id = any (coalesce(p_ids, '{}'::uuid[]));
  end if;
  return;
end $$;
revoke execute on function public._notification_audience(text,uuid[]) from public, anon, authenticated;

-- ───────── 7) trigger: เหตุการณ์จริงของออเดอร์ → แจ้งเตือนลูกค้า ─────────
create or replace function public._trg_notify_order_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public._notify_user(
      new.user_id,
      'จองคิวสำเร็จ 🎉',
      format('ออเดอร์ #%s ได้รับการยืนยันแล้ว%s กดเพื่อดูรายละเอียดงาน',
             lpad(new.no::text, 3, '0'),
             case when coalesce(new.items::text,'') <> '' then ' · ' || left(new.items::text, 120) else '' end),
      'order_created', new.id, null, '#order', 'ดูรายละเอียดงาน',
      jsonb_build_object('no', new.no, 'status', new.status, 'items', new.items::text, 'total', new.total));
  exception when others then
    raise warning 'notify(order_created) skipped: %', sqlerrm;
  end;
  return new;
end $$;

create or replace function public._trg_notify_order_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare t text; b text; k text;
begin
  if new.status is not distinct from old.status then return new; end if;
  begin
    case new.status
      when 'pending' then
        t := 'ออเดอร์รอดำเนินการ ⏳';
        b := format('ออเดอร์ #%s เข้าคิวแล้ว ทีมงานจะยืนยันให้เร็วที่สุด', lpad(new.no::text,3,'0'));
        k := 'order_status';
      when 'confirmed' then
        t := 'ยืนยันออเดอร์แล้ว ✅';
        b := format('ออเดอร์ #%s ได้รับการยืนยันแล้ว ทีมงานจะเริ่มดำเนินการเร็ว ๆ นี้', lpad(new.no::text,3,'0'));
        k := 'order_status';
      when 'doing' then
        t := 'ทีมงานรับงานแล้ว 🛠️';
        b := format('ออเดอร์ #%s กำลังดำเนินการอยู่ กดเพื่อติดตามความคืบหน้า', lpad(new.no::text,3,'0'));
        k := 'order_status';
      when 'waiting' then
        t := 'งานของคุณพักชั่วคราว ⏸';
        b := format('ออเดอร์ #%s รอดำเนินการต่อ ทีมงานจะกลับมาทำให้เร็วที่สุด', lpad(new.no::text,3,'0'));
        k := 'order_status';
      when 'done' then
        t := 'งานเสร็จสมบูรณ์ 🎉';
        b := format('ออเดอร์ #%s เสร็จสิ้นแล้ว กดเพื่อดูหลักฐานและรายละเอียดงาน', lpad(new.no::text,3,'0'));
        k := 'order_done';
      when 'cancelled' then
        t := 'ออเดอร์ถูกยกเลิก 🔴';
        b := format('ออเดอร์ #%s ถูกยกเลิก หากมีข้อสงสัยติดต่อร้านได้เลย', lpad(new.no::text,3,'0'));
        k := 'order_cancelled';
      else
        t := 'อัปเดตสถานะงาน 📋';
        b := format('ออเดอร์ #%s มีการเปลี่ยนสถานะเป็น %s', lpad(new.no::text,3,'0'), new.status);
        k := 'order_status';
    end case;
    perform public._notify_user(new.user_id, t, b, k, new.id, null, '#order', 'ดูรายละเอียดงาน',
      jsonb_build_object('no', new.no, 'status', new.status));
  exception when others then
    raise warning 'notify(order_status) skipped: %', sqlerrm;
  end;
  return new;
end $$;

create or replace function public._trg_notify_order_evidence() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.orders; t text; b text; k text;
begin
  select * into o from public.orders where id = new.order_id;
  if not found or o.user_id is null then return new; end if;
  if new.kind = 'image' then
    t := 'อัปเดตงานของคุณ 📸';
    b := format('ออเดอร์ #%s มีการอัปเดตความคืบหน้าใหม่ ทีมงานได้เพิ่มรูปภาพอัปเดตงานแล้ว กดเพื่อดูรายละเอียด', lpad(o.no::text,3,'0'));
    k := 'order_image';
  else
    t := 'ทีมงานเพิ่มหลักฐานงาน 🎬';
    b := format('ออเดอร์ #%s มีลิงก์หลักฐาน/ถ่ายทอดสดใหม่ กดเพื่อเปิดดู', lpad(o.no::text,3,'0'));
    k := 'order_update';
  end if;
  begin
    perform public._notify_user(o.user_id, t, b, k, o.id, null, '#order', 'ดูรายละเอียด', jsonb_build_object('no', o.no));
  exception when others then
    raise warning 'notify(order_evidence) skipped: %', sqlerrm;
  end;
  return new;
end $$;

create or replace function public._trg_notify_order_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where id = new.order_id;
  if not found or o.user_id is null then return new; end if;
  begin
    perform public._notify_user(
      o.user_id, 'ข้อความอัปเดตจากร้าน 💬',
      format('ออเดอร์ #%s: %s', lpad(o.no::text,3,'0'), left(new.message, 300)),
      'order_message', o.id, null, '#order', 'อ่านข้อความ',
      jsonb_build_object('no', o.no));
  exception when others then
    raise warning 'notify(order_update) skipped: %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists notify_order_created_trg on public.orders;
create trigger notify_order_created_trg after insert on public.orders
  for each row execute function public._trg_notify_order_created();

drop trigger if exists notify_order_status_trg on public.orders;
create trigger notify_order_status_trg after update of status on public.orders
  for each row execute function public._trg_notify_order_status();

drop trigger if exists notify_order_evidence_trg on public.order_evidence;
create trigger notify_order_evidence_trg after insert on public.order_evidence
  for each row execute function public._trg_notify_order_evidence();

drop trigger if exists notify_order_update_trg on public.order_updates;
create trigger notify_order_update_trg after insert on public.order_updates
  for each row execute function public._trg_notify_order_update();

-- ───────── 8) ฝั่งลูกค้า: อ่านโปรไฟล์ / แก้โปรไฟล์ / ทำเครื่องหมายอ่านแล้ว ─────────
create or replace function public.my_profile_detail() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'nickname', p.nickname, 'bio', p.bio, 'avatar_url', p.avatar_url,
    'email', u.email, 'member_since', u.created_at)
  from public.profiles p left join auth.users u on u.id = p.id
  where p.id = auth.uid();
$$;
revoke execute on function public.my_profile_detail() from public, anon;
grant execute on function public.my_profile_detail() to authenticated;

create or replace function public.update_my_profile(
  p_name text default null, p_nickname text default null,
  p_bio text default null, p_avatar_url text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); nm text; nk text; b text; av text;
begin
  if u is null then raise exception 'login_required'; end if;
  nm := nullif(btrim(coalesce(p_name,'')), '');
  nk := nullif(btrim(coalesce(p_nickname,'')), '');
  b  := nullif(btrim(coalesce(p_bio,'')), '');
  av := nullif(btrim(coalesce(p_avatar_url,'')), '');
  if nm is not null and char_length(nm) > 40 then raise exception 'invalid_name'; end if;
  if nk is not null and char_length(nk) > 30 then raise exception 'invalid_nickname'; end if;
  if b is not null and char_length(b) > 200 then raise exception 'invalid_bio'; end if;
  if av is not null and av !~ ('^' || u::text || '/[A-Za-z0-9._-]{1,140}$') then raise exception 'invalid_avatar'; end if;
  update public.profiles
     set name = coalesce(nm, name),
         nickname = nk,
         bio = b,
         avatar_url = av
   where id = u;
  if not found then raise exception 'profile_not_found'; end if;
  return public.my_profile_detail();
end $$;
revoke execute on function public.update_my_profile(text,text,text,text) from public, anon;
grant execute on function public.update_my_profile(text,text,text,text) to authenticated;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if auth.uid() is null then return 0; end if;
  update public.notifications
     set read_at = now()
   where user_id = auth.uid() and read_at is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

create or replace function public.my_notification_badge() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(count(*), 0)::int from public.notifications
   where user_id = auth.uid() and read_at is null;
$$;
revoke execute on function public.my_notification_badge() from public, anon;
grant execute on function public.my_notification_badge() to authenticated;

-- รีวิวสาธารณะพร้อมรูป/ชื่อเล่นของลูกค้า (ไม่เปิดเผยอีเมลหรือข้อมูลส่วนตัวอื่น)
create or replace function public.public_reviews(p_limit int default 12)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select r.rating, r.comment, r.created_at,
           coalesce(nullif(p.nickname, ''), r.reviewer, p.name, 'ลูกค้า') as reviewer,
           p.avatar_url
      from public.reviews r
      left join public.profiles p on p.id = r.user_id
     where r.visible
     order by r.created_at desc
     limit greatest(1, least(50, coalesce(p_limit, 12)))
  ) x;
$$;
revoke execute on function public.public_reviews(int) from public, anon;
grant execute on function public.public_reviews(int) to anon, authenticated;

-- ───────── 9) ฝั่งแอดมิน: ส่ง / ตั้งเวลา / ประวัติ / สถิติ ─────────
create or replace function public._notification_send(p_campaign uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.notification_campaigns; n int := 0;
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
  return jsonb_build_object('ok', true, 'campaign', c.id, 'sent', n);
exception when others then
  update public.notification_campaigns set status = 'failed' where id = p_campaign;
  raise;
end $$;
revoke execute on function public._notification_send(uuid) from public, anon, authenticated;

create or replace function public.admin_notification_preview(p_audience text, p_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n int; s jsonb;
begin
  if not public.is_shop_admin() then raise exception 'forbidden'; end if;
  select count(*) into n from public._notification_audience(p_audience, p_ids);
  select coalesce(jsonb_agg(y), '[]'::jsonb) into s from (
    select jsonb_build_object('id', p.id, 'name', coalesce(nullif(p.nickname,''), p.name), 'avatar_url', p.avatar_url) as y
      from public._notification_audience(p_audience, p_ids) as u
      join public.profiles p on p.id = u
     limit 5
  ) q;
  return jsonb_build_object('recipients', n, 'sample', s);
end $$;
revoke execute on function public.admin_notification_preview(text,uuid[]) from public, anon;
grant execute on function public.admin_notification_preview(text,uuid[]) to authenticated;

create or replace function public.admin_notification_customers(p_q text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_shop_admin() then '[]'::jsonb else coalesce(jsonb_agg(x), '[]'::jsonb) end from (
    select jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'nickname', p.nickname,
      'avatar_url', p.avatar_url,
      'email', u.email,
      'orders_count', (select count(*) from public.orders o where o.user_id = p.id),
      'active_count', (select count(*) from public.orders o where o.user_id = p.id and o.status in ('pending','confirmed','doing','waiting'))
    ) as x
    from public.profiles p left join auth.users u on u.id = p.id
    where nullif(btrim(coalesce(p_q,'')), '') is null
       or p.name ilike '%' || btrim(p_q) || '%'
       or p.nickname ilike '%' || btrim(p_q) || '%'
       or u.email ilike '%' || btrim(p_q) || '%'
    order by p.name nulls last
    limit 50
  ) q;
$$;
revoke execute on function public.admin_notification_customers(text) from public, anon;
grant execute on function public.admin_notification_customers(text) to authenticated;

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
  if p_audience not in ('all','customers','active','selected') then raise exception 'invalid_audience'; end if;
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
    return jsonb_build_object('ok', true, 'campaign', c.id, 'scheduled', true, 'recipients', n, 'sent', 0);
  end if;
  return public._notification_send(c.id);
end $$;
revoke execute on function public.admin_send_notification(text,text,text,text,text,text,uuid[],timestamptz,text) from public, anon;
grant execute on function public.admin_send_notification(text,text,text,text,text,text,uuid[],timestamptz,text) to authenticated;

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
  return n;
end $$;
revoke execute on function public.dispatch_due_notifications() from public, anon;
grant execute on function public.dispatch_due_notifications() to authenticated;

create or replace function public.admin_cancel_campaign(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.notification_campaigns;
begin
  if not public.is_shop_admin() then raise exception 'forbidden'; end if;
  select * into c from public.notification_campaigns where id = p_id;
  if not found then raise exception 'campaign_not_found'; end if;
  if c.status <> 'scheduled' then raise exception 'campaign_locked'; end if;
  update public.notification_campaigns set status = 'cancelled' where id = p_id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;
revoke execute on function public.admin_cancel_campaign(uuid) from public, anon;
grant execute on function public.admin_cancel_campaign(uuid) to authenticated;

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
    'customers', (select count(*) from public.profiles)
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
      'unread_count', (select count(*) from public.notifications n where n.campaign_id = c.id and n.read_at is null)
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

-- แจ้งโปรโมชั่นใหม่ให้ลูกค้าทุกคน (เรียกจากปุ่ม "แจ้งเตือน" ในหน้าจัดการโปรโมชั่น)
create or replace function public.admin_broadcast_promotion(p_promo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr public.promotions; c public.notification_campaigns; n int; b text; v text;
begin
  if not public.is_shop_admin() then raise exception 'forbidden'; end if;
  select * into pr from public.promotions where id = p_promo;
  if not found then raise exception 'promo_not_found'; end if;
  v := case when pr.kind = 'percent' then pr.value::text || '%' else pr.value::text || ' บาท' end;
  b := format('โค้ด %s ลด %s%s%s กดเพื่อดูรายละเอียดและสิทธิ์ของคุณ',
              pr.code, v,
              case when coalesce(pr.min_total,0) > 0 then format(' (ขั้นต่ำ %s บาท)', pr.min_total) else '' end,
              case when pr.expires_at is not null then format(' · ถึงวันที่ %s', to_char(pr.expires_at at time zone 'Asia/Bangkok', 'DD/MM/YYYY')) else '' end);
  select count(*) into n from public._notification_audience('all', null);
  if n = 0 then raise exception 'no_recipients'; end if;
  insert into public.notification_campaigns
    (title, body, kind, button_label, button_url, audience, recipients, status, promotion_id, created_by)
  values ('🎉 โปรโมชั่นใหม่จาก MPSHOP', b, 'promotion', 'ดูโปรโมชั่น', '#promosec', 'all', n, 'sending', pr.id, auth.uid())
  returning * into c;
  return public._notification_send(c.id);
end $$;
revoke execute on function public.admin_broadcast_promotion(uuid) from public, anon;
grant execute on function public.admin_broadcast_promotion(uuid) to authenticated;

-- แอดมินโพสต์ข้อความอัปเดตถึงลูกค้า (เก็บใน order_updates + trigger ส่ง notification)
create or replace function public.add_order_update(p_order uuid, p_message text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.orders; r public.order_updates;
begin
  if not public.is_shop_admin() then raise exception 'forbidden'; end if;
  select * into o from public.orders where id = p_order;
  if not found then raise exception 'order_not_found'; end if;
  if char_length(btrim(coalesce(p_message,''))) between 1 and 1000 is not true then raise exception 'invalid_message'; end if;
  insert into public.order_updates (order_id, message, created_by)
  values (p_order, btrim(p_message), auth.uid()) returning * into r;
  return jsonb_build_object('id', r.id, 'order_id', r.order_id, 'created_at', r.created_at);
end $$;
revoke execute on function public.add_order_update(uuid,text) from public, anon;
grant execute on function public.add_order_update(uuid,text) to authenticated;

-- ───────── 10) สิทธิ์ของคอลัมน์โปรไฟล์ (ลูกค้าแก้เฉพาะของตัวเองผ่าน RPC) ─────────
grant select on public.profiles to authenticated;
do $$ begin
  execute 'grant update (nickname, bio, avatar_url) on public.profiles to authenticated';
exception when others then raise warning 'skip profile column grants: %', sqlerrm;
end $$;

-- ───────── 11) ตรวจสุขภาพระบบหลังติดตั้ง ─────────
create or replace function public.notifications_selfcheck() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'notifications_table', to_regclass('public.notifications') is not null,
    'campaigns_table', to_regclass('public.notification_campaigns') is not null,
    'order_updates_table', to_regclass('public.order_updates') is not null,
    'avatars_bucket', exists (select 1 from storage.buckets where id = 'avatars'),
    'triggers', (select count(*) from pg_trigger t
                  where not t.tgisinternal
                    and t.tgname in ('notify_order_created_trg','notify_order_status_trg',
                                     'notify_order_evidence_trg','notify_order_update_trg')),
    'orders_notified', (select count(*) from public.notifications where kind like 'order%'),
    'admin_view', public.is_shop_admin()
  );
$$;
revoke execute on function public.notifications_selfcheck() from public, anon;
grant execute on function public.notifications_selfcheck() to authenticated;
