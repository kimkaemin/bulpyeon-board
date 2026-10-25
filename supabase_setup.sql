-- Painboard shared board schema for Supabase.
-- Run once in Supabase SQL Editor. No privileged service key is used by the website.

create extension if not exists pgcrypto;

create table if not exists public.board_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 40),
  body text not null check (char_length(body) between 10 and 1000),
  category text not null check (category in ('직장·학교','가족·친구','서비스·소비','교통·공공장소','기타')),
  created_at timestamptz not null default now(),
  hidden boolean not null default false,
  author_id uuid not null default auth.uid()
);

alter table public.board_posts add column if not exists author_id uuid default auth.uid();

create table if not exists public.board_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.board_posts(id) on delete cascade,
  body text not null check (char_length(body) between 2 and 300),
  created_at timestamptz not null default now(),
  hidden boolean not null default false,
  author_id uuid not null default auth.uid()
);

alter table public.board_comments add column if not exists author_id uuid default auth.uid();

create table if not exists public.board_reactions (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.board_posts(id) on delete cascade,
  reaction text not null check (reaction in ('a','b','c')),
  voter_key text not null,
  created_at timestamptz not null default now(),
  unique (post_id, reaction, voter_key)
);

create table if not exists public.board_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.board_posts(id) on delete cascade,
  comment_id uuid references public.board_comments(id) on delete cascade,
  reason text not null,
  created_at timestamptz not null default now()
);

alter table public.board_posts enable row level security;
alter table public.board_comments enable row level security;
alter table public.board_reactions enable row level security;
alter table public.board_reports enable row level security;

drop policy if exists "Anyone can read visible posts" on public.board_posts;
create policy "Anyone can read visible posts" on public.board_posts for select to anon, authenticated using (hidden = false);
drop policy if exists "Anyone can publish posts" on public.board_posts;
create policy "Signed-in visitors can publish posts" on public.board_posts for insert to authenticated with check (auth.uid() = author_id);
drop policy if exists "Authors can delete their own posts" on public.board_posts;
create policy "Authors can delete their own posts" on public.board_posts for delete to authenticated using (auth.uid() = author_id);

drop policy if exists "Anyone can read visible comments" on public.board_comments;
create policy "Anyone can read visible comments" on public.board_comments for select to anon, authenticated using (hidden = false);
drop policy if exists "Anyone can write comments" on public.board_comments;
drop policy if exists "Signed-in visitors can write comments" on public.board_comments;
create policy "Signed-in visitors can write comments" on public.board_comments for insert to authenticated with check (auth.uid() = author_id);
drop policy if exists "Authors can delete their own comments" on public.board_comments;
create policy "Authors can delete their own comments" on public.board_comments for delete to authenticated using (auth.uid() = author_id);

drop policy if exists "Anyone can read reactions" on public.board_reactions;
create policy "Anyone can read reactions" on public.board_reactions for select to anon, authenticated using (true);
drop policy if exists "Anyone can react" on public.board_reactions;
create policy "Signed-in visitors can react" on public.board_reactions for insert to authenticated with check (voter_key = auth.uid()::text);
drop policy if exists "Anyone can remove their browser reaction" on public.board_reactions;
drop policy if exists "Visitors can remove their own reaction" on public.board_reactions;
create policy "Visitors can remove their own reaction" on public.board_reactions for delete to authenticated using (voter_key = auth.uid()::text);

drop policy if exists "Anyone can submit reports" on public.board_reports;
create policy "Anyone can submit reports" on public.board_reports for insert to anon, authenticated with check (true);

create index if not exists board_posts_created_at_idx on public.board_posts (created_at desc);
create index if not exists board_comments_post_created_idx on public.board_comments (post_id, created_at);
create index if not exists board_reactions_post_idx on public.board_reactions (post_id);
create index if not exists board_reports_post_idx on public.board_reports (post_id, created_at desc);

grant select on public.board_posts to anon, authenticated;
grant insert, delete on public.board_posts to authenticated;
grant select on public.board_comments to anon, authenticated;
grant insert, delete on public.board_comments to authenticated;
revoke insert, delete on public.board_comments from anon;
grant select, insert, delete on public.board_reactions to authenticated;
grant select on public.board_reactions to anon;
revoke delete on public.board_reactions from anon;
grant insert on public.board_reports to anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.board_posts;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.board_comments;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.board_reactions;
exception when duplicate_object then null;
end $$;

-- ===== Reports: one per visitor, auto-hide at 3 distinct reporters; write rate limits =====
alter table public.board_reports add column if not exists reporter_id uuid default auth.uid();
update public.board_reports set reporter_id = gen_random_uuid() where reporter_id is null;
alter table public.board_reports alter column reporter_id set not null;

create unique index if not exists board_reports_one_per_reporter
  on public.board_reports (reporter_id, post_id, coalesce(comment_id, '00000000-0000-0000-0000-000000000000'::uuid));

drop policy if exists "Anyone can submit reports" on public.board_reports;
drop policy if exists "Signed-in visitors can submit reports" on public.board_reports;
create policy "Signed-in visitors can submit reports" on public.board_reports
  for insert to authenticated with check (reporter_id = auth.uid());
revoke insert on public.board_reports from anon;

create or replace function public.board_apply_report_threshold() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.comment_id is not null then
    if (select count(distinct reporter_id) from public.board_reports where comment_id = new.comment_id) >= 3 then
      update public.board_comments set hidden = true where id = new.comment_id;
    end if;
  else
    if (select count(distinct reporter_id) from public.board_reports where post_id = new.post_id and comment_id is null) >= 3 then
      update public.board_posts set hidden = true where id = new.post_id;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.board_apply_report_threshold() from public, anon, authenticated;

drop trigger if exists board_reports_threshold on public.board_reports;
create trigger board_reports_threshold after insert on public.board_reports
  for each row execute function public.board_apply_report_threshold();

create or replace function public.board_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_table_name = 'board_posts' then
    select count(*) into n from public.board_posts where author_id = new.author_id and created_at > now() - interval '1 hour';
    if n >= 5 then raise exception 'rate limit: too many posts'; end if;
  elsif tg_table_name = 'board_comments' then
    select count(*) into n from public.board_comments where author_id = new.author_id and created_at > now() - interval '1 hour';
    if n >= 30 then raise exception 'rate limit: too many comments'; end if;
  end if;
  return new;
end $$;
revoke execute on function public.board_rate_limit() from public, anon, authenticated;

drop trigger if exists board_posts_rate_limit on public.board_posts;
create trigger board_posts_rate_limit before insert on public.board_posts
  for each row execute function public.board_rate_limit();
drop trigger if exists board_comments_rate_limit on public.board_comments;
create trigger board_comments_rate_limit before insert on public.board_comments
  for each row execute function public.board_rate_limit();
