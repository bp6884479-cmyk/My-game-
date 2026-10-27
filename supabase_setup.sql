-- =====================================================================
-- Colour Trading Pro : Coin Transfer + Withdraw system
-- Safe to run more than once.
-- =====================================================================

-- 0) ADMIN LIST
create table if not exists public.admins (
  email text primary key
);
alter table public.admins enable row level security;

-- >>> APNI ADMIN GOOGLE EMAIL YAHAN DAALO <<<
insert into public.admins(email) values ('YOUR_EMAIL@gmail.com')
on conflict do nothing;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- 1) CLOUD SAVE
create table if not exists public.game_saves (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb,
  updated_at timestamptz default now()
);
alter table public.game_saves enable row level security;
drop policy if exists "own save" on public.game_saves;
create policy "own save" on public.game_saves
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 2) PLAYERS
create table if not exists public.players (
  username   text primary key,
  user_id    uuid not null,
  updated_at timestamptz default now()
);
alter table public.players enable row level security;
drop policy if exists "players read"   on public.players;
drop policy if exists "players insert" on public.players;
drop policy if exists "players update" on public.players;
create policy "players read"   on public.players for select
  using (user_id = auth.uid() or public.is_admin());
create policy "players insert" on public.players for insert
  with check (user_id = auth.uid());
create policy "players update" on public.players for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 3) COIN CREDITS (admin -> player)
create table if not exists public.coin_credits (
  id         uuid primary key default gen_random_uuid(),
  username   text not null,
  amount     numeric not null check (amount > 0),
  note       text,
  status     text not null default 'pending',
  created_at timestamptz default now(),
  claimed_at timestamptz
);
alter table public.coin_credits enable row level security;
drop policy if exists "credits admin all"   on public.coin_credits;
drop policy if exists "credits own read"    on public.coin_credits;
drop policy if exists "credits own claim"   on public.coin_credits;
create policy "credits admin all" on public.coin_credits for all
  using (public.is_admin()) with check (public.is_admin());
create policy "credits own read" on public.coin_credits for select
  using (username in (select username from public.players where user_id = auth.uid()));
create policy "credits own claim" on public.coin_credits for update
  using (status = 'pending'
         and username in (select username from public.players where user_id = auth.uid()))
  with check (status = 'claimed');

-- 4) WITHDRAWALS
create table if not exists public.withdrawals (
  id         text primary key,
  user_id    uuid not null,
  username   text,
  coins      numeric not null check (coins > 0),
  rupees     numeric not null check (rupees > 0),
  upi        text,
  status     text not null default 'Processing',
  refunded   boolean not null default false,
  created_at timestamptz default now()
);
alter table public.withdrawals enable row level security;
drop policy if exists "wd own insert"   on public.withdrawals;
drop policy if exists "wd own read"     on public.withdrawals;
drop policy if exists "wd own refund"   on public.withdrawals;
drop policy if exists "wd admin all"    on public.withdrawals;
create policy "wd own insert" on public.withdrawals for insert
  with check (user_id = auth.uid() and status = 'Processing' and refunded = false);
create policy "wd own read" on public.withdrawals for select
  using (user_id = auth.uid());
create policy "wd own refund" on public.withdrawals for update
  using (user_id = auth.uid() and status = 'Rejected' and refunded = false)
  with check (user_id = auth.uid() and status = 'Rejected' and refunded = true);
create policy "wd admin all" on public.withdrawals for all
  using (public.is_admin()) with check (public.is_admin());

-- Limit: min 110, ek din (IST) me max 50,000
create or replace function public.wd_limit_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  day_start timestamptz :=
    (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata');
  used numeric;
begin
  if new.rupees < 110 then
    raise exception 'Minimum withdraw 110';
  end if;
  select coalesce(sum(rupees), 0) into used
  from public.withdrawals
  where user_id = new.user_id and status <> 'Rejected' and created_at >= day_start;
  if used + new.rupees > 50000 then
    raise exception 'Daily withdraw limit 50000 poori ho gayi';
  end if;
  return new;
end;
$$;
drop trigger if exists wd_limit_check on public.withdrawals;
create trigger wd_limit_check before insert on public.withdrawals
  for each row execute function public.wd_limit_check();

-- Player sirf refunded flag badal sake
create or replace function public.wd_lock_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_admin() then return new; end if;
  if new.id <> old.id or new.user_id <> old.user_id or new.coins <> old.coins
     or new.rupees <> old.rupees or new.status <> old.status
     or new.upi is distinct from old.upi or new.username is distinct from old.username then
    raise exception 'Not allowed';
  end if;
  return new;
end;
$$;
drop trigger if exists wd_lock_columns on public.withdrawals;
create trigger wd_lock_columns before update on public.withdrawals
  for each row execute function public.wd_lock_columns();
