-- العدّ اليومي لأصحاب الأثر | NextStep AI
-- شغّله كاملاً مرة واحدة في: Supabase > SQL Editor (آمن لإعادة التشغيل)

create table if not exists daily_counts (
  participant_id uuid not null references participants(id) on delete cascade,
  day date not null,
  cnt integer not null default 0 check (cnt >= 0 and cnt <= 10000),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (participant_id, day)
);

-- مغلق عن الجمهور: الفريق (المسجّلون) فقط يقرأ ويكتب
alter table daily_counts enable row level security;
drop policy if exists team_all_d on daily_counts;
create policy team_all_d on daily_counts for all to authenticated using (true) with check (true);
grant select, insert, update, delete on daily_counts to authenticated;

-- الواجهات العامة: المؤكد = الإحالات المؤكدة + مجموع العدّ اليومي
create or replace view public_leaderboard as
select p.first_name, p.university,
       (coalesce((select count(*) from referrals r where r.referrer_id = p.id and r.status = 'confirmed'), 0)
      + coalesce((select sum(d.cnt) from daily_counts d where d.participant_id = p.id), 0))::bigint as confirmed,
       case when p.photo_done then p.photo_key end as photo
from participants p
order by confirmed desc, p.created_at;

create or replace view uni_board as
with t as (
  select coalesce(p.university,'—') as u,
         (coalesce((select count(*) from referrals r where r.referrer_id = p.id and r.status = 'confirmed'), 0)
        + coalesce((select sum(d.cnt) from daily_counts d where d.participant_id = p.id), 0)) as c
  from participants p)
select u as university, count(*) as participants, sum(c)::bigint as confirmed
from t group by u order by confirmed desc;

create or replace view public_totals as
select ((select count(*) from referrals where status = 'confirmed')
      + coalesce((select sum(cnt) from daily_counts), 0))::bigint as confirmed,
       (select count(*) from participants) as participants;

create or replace function my_stats(p_code text) returns json
language sql security definer set search_path = public as $$
  with s as (
    select p.id, p.first_name, p.university,
      case when p.photo_done then p.photo_key end photo,
      ((select count(*) from referrals r where r.referrer_id = p.id and r.status = 'confirmed')
       + coalesce((select sum(d.cnt) from daily_counts d where d.participant_id = p.id), 0)) c,
      (select count(*) from referrals r where r.referrer_id = p.id and r.status = 'pending') pe
    from participants p)
  select json_build_object('name', first_name, 'university', university, 'photo', photo,
    'confirmed', c, 'pending', pe,
    'rank', (select count(*) + 1 from s s2 where s2.c > s.c))
  from s where id = (select id from participants where code = upper(regexp_replace(p_code, '\s+', '', 'g')));
$$;

grant select on public_leaderboard, uni_board, public_totals to anon, authenticated;
grant execute on function my_stats(text) to anon, authenticated;
