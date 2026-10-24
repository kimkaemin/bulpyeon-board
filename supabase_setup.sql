-- Painboard shared board schema for Supabase.
-- Run once in Supabase SQL Editor. No privileged service key is used by the website.

create extension if not exists pgcrypto;

create table if not exists public.board_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 40),
  body text not null check (char_length(body) between 10 and 1000),
  category text not null check (category in ('직장·학교','가족·친구','서비스·소비','교통·공공장소','기타')),
  created_at timestamptz not null default now(),
  hidden boolean not null default false
);

create table if not exists public.board_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.board_posts(id) on delete cascade,
  body text not null check (char_length(body) between 2 and 300),
  created_at timestamptz not null default now(),
  hidden boolean not null default false
);

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
create policy "Anyone can publish posts" on public.board_posts for insert to anon, authenticated with check (true);

drop policy if exists "Anyone can read visible comments" on public.board_comments;
create policy "Anyone can read visible comments" on public.board_comments for select to anon, authenticated using (hidden = false);
drop policy if exists "Anyone can write comments" on public.board_comments;
create policy "Anyone can write comments" on public.board_comments for insert to anon, authenticated with check (true);

drop policy if exists "Anyone can read reactions" on public.board_reactions;
create policy "Anyone can read reactions" on public.board_reactions for select to anon, authenticated using (true);
drop policy if exists "Anyone can react" on public.board_reactions;
create policy "Anyone can react" on public.board_reactions for insert to anon, authenticated with check (true);
drop policy if exists "Anyone can remove their browser reaction" on public.board_reactions;

drop policy if exists "Anyone can submit reports" on public.board_reports;
create policy "Anyone can submit reports" on public.board_reports for insert to anon, authenticated with check (true);

create index if not exists board_posts_created_at_idx on public.board_posts (created_at desc);
create index if not exists board_comments_post_created_idx on public.board_comments (post_id, created_at);
create index if not exists board_reactions_post_idx on public.board_reactions (post_id);
create index if not exists board_reports_post_idx on public.board_reports (post_id, created_at desc);

grant select, insert on public.board_posts to anon, authenticated;
grant select, insert on public.board_comments to anon, authenticated;
grant select, insert on public.board_reactions to anon, authenticated;
revoke delete on public.board_reactions from anon, authenticated;
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
