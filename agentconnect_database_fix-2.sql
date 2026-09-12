-- =====================================================================
-- AGENTCONNECT — FULL DATABASE FIX
-- Paste this whole file into Supabase Dashboard → SQL Editor → Run.
-- It is safe to run more than once (everything is idempotent).
--
-- This creates/repairs every table, trigger, function and RLS policy
-- that admin.html and dashboard.html actually call. Missing/incorrect
-- versions of any of these are why "profile not displaying", wallet/
-- users list empty, chat not saving, etc. were happening.
-- =====================================================================

create extension if not exists pgcrypto;   -- gives us gen_random_uuid()

-- =====================================================================
-- 0. CLEAN SLATE FOR FUNCTIONS THIS SCRIPT OWNS
-- If any of these already exist with a different signature or different
-- parameter defaults, plain CREATE OR REPLACE fails with:
--   ERROR 42P13: cannot remove parameter defaults from existing function
-- Dropping every overload by name first (cascade removes any trigger
-- that depended on it — each one is recreated further down) makes this
-- script safe to run no matter what was there before.
-- =====================================================================
do $$
declare
  r record;
  fn text;
begin
  foreach fn in array array['complete_profile','admin_update_user_details',
                             'release_housing_deal_funds','is_admin',
                             'handle_new_user','touch_conversation_on_message']
  loop
    for r in
      select p.oid::regprocedure as sig
      from pg_proc p
      where p.proname = fn
        and p.pronamespace = 'public'::regnamespace
    loop
      execute format('drop function if exists %s cascade', r.sig);
    end loop;
  end loop;
end $$;

-- =====================================================================
-- 1. PROFILES  (dashboard.html + admin.html read/write this constantly)
-- =====================================================================
create table if not exists public.profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  full_name           text,
  email               text,
  avatar_url          text,
  dob                 date,
  location            text,
  account_number      text unique,
  onboarding_step     smallint  not null default 1,
  onboarding_completed boolean  not null default false,
  biometric_enabled   boolean   not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- add any columns that might be missing on an older table
alter table public.profiles add column if not exists full_name text;
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists dob date;
alter table public.profiles add column if not exists location text;
alter table public.profiles add column if not exists account_number text;
alter table public.profiles add column if not exists onboarding_step smallint not null default 1;
alter table public.profiles add column if not exists onboarding_completed boolean not null default false;
alter table public.profiles add column if not exists biometric_enabled boolean not null default false;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

-- =====================================================================
-- 2. ADMIN_USERS  (admin.html checks this to gate the whole app)
-- =====================================================================
create table if not exists public.admin_users (
  id         uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 3. USER_FINANCIALS  (wallet balance)
-- =====================================================================
create table if not exists public.user_financials (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  available_balance numeric(14,2) not null default 0,
  currency          text not null default 'USD',
  updated_at        timestamptz not null default now()
);

-- =====================================================================
-- 4. USER_BANK_DETAILS
-- =====================================================================
create table if not exists public.user_bank_details (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  bank_name      text,
  account_name   text,
  account_number text,
  updated_at     timestamptz not null default now()
);

-- =====================================================================
-- 5. CONVERSATIONS
-- NOTE: agent_id is TEXT on purpose. In dashboard.html the "agents" a
-- user chats with are locally generated mock map-pins (numeric/string
-- ids like 1, 2, "megan-danielle-anderson") — they are NOT rows in
-- auth.users. Only when an *admin* starts a chat is agent_id a real
-- auth uid. A uuid foreign key here would break every user-initiated
-- chat, which is one of the "database problems" you were seeing.
-- =====================================================================
create table if not exists public.conversations (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  agent_id         text,
  agent_name       text,
  agent_photo      text,
  last_message_at  timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create index if not exists idx_conversations_user_id on public.conversations(user_id);
create index if not exists idx_conversations_last_message on public.conversations(last_message_at desc);

-- =====================================================================
-- 6. MESSAGES
-- =====================================================================
create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender          text not null check (sender in ('user','agent')),
  sender_id       uuid,
  body            text,
  media_url       text,
  media_type      text check (media_type in ('image','video') or media_type is null),
  created_at      timestamptz not null default now()
);
create index if not exists idx_messages_conversation_id on public.messages(conversation_id, created_at);

-- keep conversations.last_message_at in sync automatically
create or replace function public.touch_conversation_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations
    set last_message_at = new.created_at
    where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists trg_touch_conversation on public.messages;
create trigger trg_touch_conversation
  after insert on public.messages
  for each row execute function public.touch_conversation_on_message();

-- =====================================================================
-- 7. PAYOUT_SETTINGS  (single row, id = 1)
-- =====================================================================
create table if not exists public.payout_settings (
  id             smallint primary key default 1,
  bank_name      text,
  account_name   text,
  account_number text,
  updated_at     timestamptz not null default now(),
  constraint payout_settings_single_row check (id = 1)
);
insert into public.payout_settings (id) values (1) on conflict (id) do nothing;

-- =====================================================================
-- 8. TRANSACTIONS  (wallet history)
-- =====================================================================
create table if not exists public.transactions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  type            text not null default 'escrow_release',
  direction       text not null check (direction in ('credit','debit')),
  amount          numeric(14,2) not null,
  currency        text not null default 'USD',
  title           text,
  description     text,
  balance_before  numeric(14,2),
  balance_after   numeric(14,2),
  reference_id    text,
  created_at      timestamptz not null default now()
);
create index if not exists idx_transactions_user_id on public.transactions(user_id, created_at desc);

-- =====================================================================
-- 9. HELPER: is_admin()
-- security definer + stable so it can be used inside RLS policies on
-- admin_users itself without causing infinite-recursion errors.
-- =====================================================================
create or replace function public.is_admin(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users a where a.id = uid);
$$;

-- =====================================================================
-- 10. NEW-USER TRIGGER
-- This is almost certainly why "the user profile does not display":
-- if a profiles row never gets created at sign-up, every profile
-- lookup in the app (loadProfile, admin Users tab, etc.) returns
-- nothing. This trigger guarantees the row exists the instant
-- someone signs up, with onboarding_step = 1 like the client expects.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, onboarding_step, onboarding_completed)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    1,
    false
  )
  on conflict (id) do nothing;

  insert into public.user_financials (user_id, available_balance, currency)
  values (new.id, 0, 'USD')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- 11. RPC: complete_profile
-- Called from dashboard.html step 3 of onboarding.
-- =====================================================================
create or replace function public.complete_profile(
  p_full_name          text,
  p_dob                date,
  p_location           text,
  p_avatar_url         text,
  p_biometric_enabled  boolean
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.profiles;
  new_account_number text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select account_number into new_account_number from public.profiles where id = auth.uid();

  if new_account_number is null then
    loop
      new_account_number := lpad((floor(random()*9000000000)+1000000000)::bigint::text, 10, '0');
      exit when not exists (select 1 from public.profiles where account_number = new_account_number);
    end loop;
  end if;

  update public.profiles set
    full_name            = coalesce(p_full_name, full_name),
    dob                  = p_dob,
    location             = p_location,
    avatar_url           = coalesce(p_avatar_url, avatar_url),
    biometric_enabled    = p_biometric_enabled,
    account_number       = new_account_number,
    onboarding_step      = 2,
    onboarding_completed = true,
    updated_at           = now()
  where id = auth.uid()
  returning * into result;

  if result.id is null then
    raise exception 'Profile row not found for this user';
  end if;

  return result;
end;
$$;

grant execute on function public.complete_profile(text, date, text, text, boolean) to authenticated;

-- =====================================================================
-- 12. RPC: admin_update_user_details
-- Called from admin.html "Save user details" button. Admin-only.
-- =====================================================================
create or replace function public.admin_update_user_details(
  p_user_id         uuid,
  p_available_balance numeric,
  p_bank_name       text,
  p_account_name    text,
  p_account_number  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Not authorized: admin only';
  end if;

  insert into public.user_financials (user_id, available_balance, currency, updated_at)
  values (p_user_id, p_available_balance, 'USD', now())
  on conflict (user_id) do update
    set available_balance = excluded.available_balance,
        updated_at        = now();

  insert into public.user_bank_details (user_id, bank_name, account_name, account_number, updated_at)
  values (p_user_id, p_bank_name, p_account_name, p_account_number, now())
  on conflict (user_id) do update
    set bank_name      = excluded.bank_name,
        account_name   = excluded.account_name,
        account_number = excluded.account_number,
        updated_at     = now();
end;
$$;

grant execute on function public.admin_update_user_details(uuid, numeric, text, text, text) to authenticated;

-- =====================================================================
-- 13. RPC: release_housing_deal_funds
-- Called from dashboard.html when a user releases an escrow to an agent.
-- =====================================================================
create or replace function public.release_housing_deal_funds(
  p_user_id      uuid,
  p_amount       numeric,
  p_agent_name   text,
  p_reference_id text
)
returns public.transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  current_balance numeric(14,2);
  current_currency text;
  new_balance numeric(14,2);
  result public.transactions;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'Not authorized';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Invalid amount';
  end if;

  select available_balance, currency into current_balance, current_currency
    from public.user_financials
    where user_id = p_user_id
    for update;

  if current_balance is null then
    raise exception 'No wallet found for this user';
  end if;
  if current_balance < p_amount then
    raise exception 'Insufficient balance';
  end if;

  new_balance := current_balance - p_amount;

  update public.user_financials
    set available_balance = new_balance, updated_at = now()
    where user_id = p_user_id;

  insert into public.transactions
    (user_id, type, direction, amount, currency, title, description, balance_before, balance_after, reference_id)
  values
    (p_user_id, 'escrow_release', 'debit', p_amount, coalesce(current_currency,'USD'),
     p_agent_name, 'Escrow released to '||p_agent_name, current_balance, new_balance, p_reference_id)
  returning * into result;

  return result;
end;
$$;

grant execute on function public.release_housing_deal_funds(uuid, numeric, text, text) to authenticated;

-- =====================================================================
-- 14. ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles           enable row level security;
alter table public.admin_users        enable row level security;
alter table public.user_financials    enable row level security;
alter table public.user_bank_details  enable row level security;
alter table public.conversations      enable row level security;
alter table public.messages           enable row level security;
alter table public.payout_settings    enable row level security;
alter table public.transactions       enable row level security;

-- ---- profiles ----
drop policy if exists profiles_select_own_or_admin on public.profiles;
create policy profiles_select_own_or_admin on public.profiles
  for select using (auth.uid() = id or public.is_admin(auth.uid()));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- ---- admin_users ----
-- Every signed-in user is allowed to check ONLY their own id (this is
-- exactly the query checkAdminAndBoot() runs: .eq('id', session.user.id)).
-- They can never see the full admin list.
drop policy if exists admin_users_self_check on public.admin_users;
create policy admin_users_self_check on public.admin_users
  for select using (auth.uid() = id or public.is_admin(auth.uid()));

-- ---- user_financials ----
drop policy if exists user_financials_select_own_or_admin on public.user_financials;
create policy user_financials_select_own_or_admin on public.user_financials
  for select using (auth.uid() = user_id or public.is_admin(auth.uid()));

-- ---- user_bank_details ----
drop policy if exists user_bank_details_select_own_or_admin on public.user_bank_details;
create policy user_bank_details_select_own_or_admin on public.user_bank_details
  for select using (auth.uid() = user_id or public.is_admin(auth.uid()));

-- ---- conversations ----
drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations
  for select using (
    auth.uid() = user_id
    or auth.uid()::text = agent_id
    or public.is_admin(auth.uid())
  );

drop policy if exists conversations_insert on public.conversations;
create policy conversations_insert on public.conversations
  for insert with check (
    auth.uid() = user_id
    or auth.uid()::text = agent_id
    or public.is_admin(auth.uid())
  );

-- ---- messages ----
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select using (
    exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and (c.user_id = auth.uid() or c.agent_id = auth.uid()::text or public.is_admin(auth.uid()))
    )
  );

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and (c.user_id = auth.uid() or c.agent_id = auth.uid()::text or public.is_admin(auth.uid()))
    )
  );

-- ---- payout_settings ----
-- shown to every signed-in user on the "Top Up" screen; only an admin can change it
drop policy if exists payout_settings_select_all on public.payout_settings;
create policy payout_settings_select_all on public.payout_settings
  for select using (auth.uid() is not null);

drop policy if exists payout_settings_admin_write on public.payout_settings;
create policy payout_settings_admin_write on public.payout_settings
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---- transactions ----
drop policy if exists transactions_select_own_or_admin on public.transactions;
create policy transactions_select_own_or_admin on public.transactions
  for select using (auth.uid() = user_id or public.is_admin(auth.uid()));

-- =====================================================================
-- 15. REALTIME
-- Both pages use supabaseClient.channel(...).on('postgres_changes', ...)
-- on the messages table. If the table isn't in the supabase_realtime
-- publication, live chat updates silently never arrive.
-- =====================================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- =====================================================================
-- 16. STORAGE BUCKETS  (avatars, chat-media)
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('chat-media', 'chat-media', true)
on conflict (id) do update set public = true;

-- anyone can view avatar / chat-media files (needed for getPublicUrl to work)
drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "chat_media_public_read" on storage.objects;
create policy "chat_media_public_read" on storage.objects
  for select using (bucket_id = 'chat-media');

-- a user may only upload avatars into a folder named after their own uid
-- (dashboard.html uploads to `${userId}/avatar-...`)
drop policy if exists "avatars_owner_write" on storage.objects;
create policy "avatars_owner_write" on storage.objects
  for insert with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects
  for update using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- any signed-in user (or admin, replying) can drop a file into chat-media;
-- access to which conversation folder is meaningful is already enforced
-- by the messages table RLS above once the row is inserted
drop policy if exists "chat_media_authenticated_write" on storage.objects;
create policy "chat_media_authenticated_write" on storage.objects
  for insert with check (
    bucket_id = 'chat-media' and auth.uid() is not null
  );

-- =====================================================================
-- 17. MAKE YOURSELF THE FIRST ADMIN
-- Run this ONE line yourself after finding your own auth uid in
-- Authentication → Users (copy the UUID, paste it below), otherwise
-- admin.html will always show "Not authorized".
-- =====================================================================
-- insert into public.admin_users (id) values ('PASTE-YOUR-AUTH-USER-UUID-HERE')
--   on conflict (id) do nothing;
