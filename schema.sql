-- تحدّي صنّاع الأثر | NextStep AI — Supabase schema (آمن لإعادة التشغيل)
-- شغّله كاملاً في: Supabase > SQL Editor

create extension if not exists pgcrypto;

create table if not exists participants (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  first_name text not null,
  university text,
  created_at timestamptz default now()
);
alter table participants add column if not exists full_name text;
alter table participants add column if not exists phone text;
alter table participants add column if not exists email text;
alter table participants add column if not exists major text;
alter table participants add column if not exists level text;
alter table participants add column if not exists city text;
alter table participants add column if not exists member_no text;
alter table participants add column if not exists consent_at timestamptz;
alter table participants add column if not exists photo_key text default replace(gen_random_uuid()::text,'-','');
alter table participants add column if not exists photo_done boolean not null default false;
update participants set photo_key = replace(gen_random_uuid()::text,'-','') where photo_key is null;
create unique index if not exists participants_phone_u on participants (phone);
create unique index if not exists participants_member_u on participants (member_no);
create unique index if not exists participants_photo_u on participants (photo_key);

create table if not exists referrals (
  id uuid primary key default gen_random_uuid(),
  new_name text not null,
  university text,
  phone text unique,
  referrer_id uuid references participants(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  reviewed_by text,
  created_at timestamptz default now()
);
create index if not exists referrals_ref_idx on referrals (referrer_id, status);
create index if not exists referrals_status_idx on referrals (status, created_at);

-- نستخدم جدول members الموجود أصلاً (تنشئه صفحة العضويات عبر create_member).
-- تأكد أنه موجود وفيه العمود membership_number قبل المتابعة.
do $$ begin
  if to_regclass('public.members') is null or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'members' and column_name = 'membership_number') then
    raise exception 'جدول members أو العمود membership_number غير موجود. شغّل أولاً supabase-schema.sql الخاص بصفحة العضويات.';
  end if;
end $$;
-- يسمح لحسابات الفريق (المسجّلة فقط) بقراءة القائمة من لوحة الأدمن. لا يُفتح شيء للعامة.
drop policy if exists challenge_team_read_members on members;
create policy challenge_team_read_members on members for select to authenticated using (true);

-- الجداول مغلقة عن الجمهور. الفريق (المستخدمون المسجّلون) فقط يقرأ ويكتب.
alter table participants enable row level security;
alter table referrals enable row level security;
drop policy if exists team_all_p on participants;
drop policy if exists team_all_r on referrals;
create policy team_all_p on participants for all to authenticated using (true) with check (true);
create policy team_all_r on referrals for all to authenticated using (true) with check (true);

-- واجهات عامة بلا بيانات شخصية (الاسم الأول + الصورة + الأعداد فقط)
create or replace view public_leaderboard as
select p.first_name, p.university,
       count(r.id) filter (where r.status = 'confirmed') as confirmed,
       case when p.photo_done then p.photo_key end as photo
from participants p left join referrals r on r.referrer_id = p.id
group by p.id order by confirmed desc, p.created_at;

create or replace view uni_board as
select coalesce(p.university,'—') as university,
       count(distinct p.id) as participants,
       count(r.id) filter (where r.status = 'confirmed') as confirmed
from participants p left join referrals r on r.referrer_id = p.id
group by 1 order by confirmed desc;

create or replace view public_totals as
select (select count(*) from referrals where status = 'confirmed') as confirmed,
       (select count(*) from participants) as participants;

-- صفحة المشارك الشخصية
create or replace function my_stats(p_code text) returns json
language sql security definer set search_path = public as $$
  with s as (
    select p.id, p.first_name, p.university,
      case when p.photo_done then p.photo_key end photo,
      count(r.id) filter (where r.status = 'confirmed') c,
      count(r.id) filter (where r.status = 'pending') pe
    from participants p left join referrals r on r.referrer_id = p.id group by p.id)
  select json_build_object('name', first_name, 'university', university, 'photo', photo,
    'confirmed', c, 'pending', pe,
    'rank', (select count(*) + 1 from s s2 where s2.c > s.c))
  from s where id = (select id from participants where code = upper(regexp_replace(p_code, '\s+', '', 'g')));
$$;

-- تسجيل مشارك جديد من الصفحة العامة
create or replace function register_participant(
  p_full_name text, p_phone text, p_email text, p_university text,
  p_major text, p_level text, p_city text, p_member_no text, p_consent boolean
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_first text; v_key text; v_memail text;
  v_phone text := regexp_replace(coalesce(p_phone,''), '[^0-9+]', '', 'g');
  v_mno text := upper(regexp_replace(coalesce(p_member_no,''), '\s+', '', 'g'));  -- رقم العضوية = الكود الشخصي
  v_name text := trim(coalesce(p_full_name,''));
begin
  if not coalesce(p_consent,false) then return json_build_object('error','consent'); end if;
  if length(v_name) < 6 or length(v_name) > 120 or length(v_phone) < 9 or length(v_mno) < 2 or length(v_mno) > 30
    then return json_build_object('error','invalid'); end if;
  -- التحقق من وجود العضوية في قاعدة بيانات المجتمع
  select to_jsonb(m)->>'email' into v_memail from members m
   where upper(regexp_replace(m.membership_number::text, '\s+', '', 'g')) = v_mno limit 1;
  if not found then return json_build_object('error','unknown_member'); end if;
  -- مطابقة البريد (إن كان مسجّلاً في قاعدة الأعضاء) حتى لا يُستخدم رقم شخص آخر
  if nullif(trim(v_memail),'') is not null and lower(trim(v_memail)) <> lower(trim(coalesce(p_email,'')))
    then return json_build_object('error','email_mismatch'); end if;
  v_first := split_part(v_name,' ',1);
  begin
    insert into participants(code, first_name, full_name, phone, email, university, major, level, city, member_no, consent_at)
    values (v_mno, v_first, v_name, v_phone, left(trim(p_email),120), left(trim(p_university),80),
            left(trim(p_major),80), left(trim(p_level),40), left(trim(p_city),40), v_mno, now())
    returning photo_key into v_key;
    return json_build_object('code', v_mno, 'first_name', v_first, 'photo_key', v_key);
  exception when unique_violation then
    return json_build_object('error','duplicate');
  end;
end $$;

-- فحص فوري لرقم العضوية أثناء كتابته في نموذج التسجيل
create or replace function check_member(p_member_no text) returns json
language plpgsql stable security definer set search_path = public as $$
declare v text := upper(regexp_replace(coalesce(p_member_no,''), '\s+', '', 'g'));
begin
  if exists (select 1 from participants where member_no = v) then return json_build_object('status','registered'); end if;
  if exists (select 1 from members m where upper(regexp_replace(m.membership_number::text, '\s+', '', 'g')) = v)
    then return json_build_object('status','known'); end if;
  return json_build_object('status','unknown');
end $$;

-- ===== الصور الشخصية (Supabase Storage) =====
-- يُسمح برفع صورة واحدة فقط لكل مشارك، بمفتاح سرّي لا يعرفه غيره، وبدون استبدال.
create or replace function can_upload_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from participants where photo_done = false and photo_key || '.jpg' = p_name);
$$;

create or replace function confirm_photo(p_key text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from storage.objects where bucket_id = 'avatars' and name = p_key || '.jpg') then
    update participants set photo_done = true where photo_key = p_key and photo_done = false;
    return found;
  end if;
  return false;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars','avatars',true,204800,array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 204800, allowed_mime_types = array['image/jpeg'];

drop policy if exists avatars_insert on storage.objects;
drop policy if exists avatars_read on storage.objects;
drop policy if exists avatars_admin_del on storage.objects;
create policy avatars_insert on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'avatars' and public.can_upload_photo(name));
create policy avatars_read on storage.objects for select to anon, authenticated using (bucket_id = 'avatars');
create policy avatars_admin_del on storage.objects for delete to authenticated using (bucket_id = 'avatars');

-- صلاحيات حسابات الفريق (تعمل مع سياسات RLS أعلاه؛ الزوار بلا سياسات فلا يصلون للجداول)
grant select, insert, update, delete on participants, referrals to authenticated;
grant select on members to authenticated;
grant select on public_leaderboard, uni_board, public_totals to anon, authenticated;
grant execute on function my_stats(text) to anon, authenticated;
grant execute on function register_participant(text,text,text,text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function check_member(text) to anon, authenticated;
grant execute on function can_upload_photo(text) to anon, authenticated;
grant execute on function confirm_photo(text) to anon, authenticated;

-- بعد التشغيل: Authentication > Providers > Email > عطّل Sign ups،
-- ثم أنشئ حسابات الفريق الأربعة يدوياً من Authentication > Users.
