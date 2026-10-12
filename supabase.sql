-- 소방 기출노트: 승인제 회원 + 계정별 기록 + 비공개 콘텐츠
-- Supabase SQL Editor 에 전체 붙여넣고 한 번 Run (여러 번 실행해도 안전)

-- 1) 관리자 이메일 (이 이메일로 가입하면 자동 승인 + 관리자)
create table if not exists public.fx_admin_emails (email text primary key);
alter table public.fx_admin_emails enable row level security;
insert into public.fx_admin_emails values ('kky5483@gmail.com'), ('mlp1759@naver.com') on conflict do nothing;

-- 2) 회원 + 승인 상태
create table if not exists public.fx_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  status     text not null default 'pending' check (status in ('pending','approved','rejected')),
  is_admin   boolean not null default false,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table public.fx_members enable row level security;

create or replace function public.fx_is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from fx_members where user_id = auth.uid() and status = 'approved');
$$;
create or replace function public.fx_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from fx_members where user_id = auth.uid() and status = 'approved' and is_admin);
$$;

-- 가입 시 자동으로 승인 대기 등록
create or replace function public.fx_on_signup() returns trigger
language plpgsql security definer set search_path = public as $$
declare adm boolean;
begin
  adm := exists (select 1 from fx_admin_emails where lower(email) = lower(new.email));
  insert into fx_members (user_id, email, status, is_admin, decided_at)
  values (new.id, new.email, case when adm then 'approved' else 'pending' end, adm, case when adm then now() end)
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists fx_on_signup on auth.users;
create trigger fx_on_signup after insert on auth.users for each row execute function public.fx_on_signup();

-- 이미 가입된 계정도 등록
insert into public.fx_members (user_id, email, status, is_admin, decided_at)
select u.id, u.email,
       case when a.email is not null then 'approved' else 'pending' end,
       a.email is not null,
       case when a.email is not null then now() end
from auth.users u left join public.fx_admin_emails a on lower(a.email) = lower(u.email)
on conflict (user_id) do nothing;

drop policy if exists "members read" on public.fx_members;
create policy "members read" on public.fx_members for select using (user_id = auth.uid() or public.fx_is_admin());

-- 관리자만 승인/거절 (관리자 계정 자체는 변경 불가)
create or replace function public.fx_set_member(p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not fx_is_admin() then raise exception 'not admin'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'bad status'; end if;
  update fx_members set status = p_status, decided_at = now() where user_id = p_user and not is_admin;
end $$;
revoke all on function public.fx_set_member(uuid, text) from public;
grant execute on function public.fx_set_member(uuid, text) to authenticated;

-- 3) 계정별 학습 기록 (승인된 본인만)
create table if not exists public.fx_user_data (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.fx_user_data enable row level security;
drop policy if exists "own row select" on public.fx_user_data;
drop policy if exists "own row insert" on public.fx_user_data;
drop policy if exists "own row update" on public.fx_user_data;
create policy "own row select" on public.fx_user_data for select using (auth.uid() = user_id and public.fx_is_approved());
create policy "own row insert" on public.fx_user_data for insert with check (auth.uid() = user_id and public.fx_is_approved());
create policy "own row update" on public.fx_user_data for update using (auth.uid() = user_id and public.fx_is_approved()) with check (auth.uid() = user_id);

-- 4) 문제·해설 콘텐츠 (승인된 회원만 읽기, 관리자만 쓰기)
create table if not exists public.fx_content (
  id         text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.fx_content enable row level security;
drop policy if exists "content read" on public.fx_content;
drop policy if exists "content insert" on public.fx_content;
drop policy if exists "content update" on public.fx_content;
create policy "content read" on public.fx_content for select using (public.fx_is_approved());
create policy "content insert" on public.fx_content for insert with check (public.fx_is_admin());
create policy "content update" on public.fx_content for update using (public.fx_is_admin()) with check (public.fx_is_admin());

-- 5) 문제 이미지 (비공개 버킷)
insert into storage.buckets (id, name, public) values ('fx-images', 'fx-images', false)
on conflict (id) do update set public = false;
drop policy if exists "fx img read" on storage.objects;
drop policy if exists "fx img insert" on storage.objects;
drop policy if exists "fx img update" on storage.objects;
create policy "fx img read" on storage.objects for select using (bucket_id = 'fx-images' and public.fx_is_approved());
create policy "fx img insert" on storage.objects for insert with check (bucket_id = 'fx-images' and public.fx_is_admin());
create policy "fx img update" on storage.objects for update using (bucket_id = 'fx-images' and public.fx_is_admin());

-- 이전 버전(동기화 코드 방식) 정리
drop function if exists public.fx_pull(text);
drop function if exists public.fx_push(text, jsonb);
drop table if exists public.fx_sync;
