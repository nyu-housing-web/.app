-- ============================================================
-- AgentConnect - complete Supabase setup
-- Project: vhxtdchncwzxdfdwacyw
--
-- Run this ENTIRE script in Supabase SQL Editor.
-- It is designed to be safe to run after a previous partial setup.
-- It creates tables BEFORE policies/triggers that depend on them.
--
-- Frontend must use ONLY the anon/publishable key.
-- NEVER put a service-role key in dashboard.html/admin.html.
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 1. PROFILES
-- ============================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  dob date,
  location text,
  avatar_url text,
  biometric_enabled boolean not null default false,
  onboarding_step integer not null default 1,
  onboarding_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists full_name text;
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists dob date;
alter table public.profiles add column if not exists location text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists biometric_enabled boolean not null default false;
alter table public.profiles add column if not exists onboarding_step integer not null default 1;
alter table public.profiles add column if not exists onboarding_completed boolean not null default false;
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

-- ============================================================
-- 2. PER-USER FINANCIAL DATA
-- ============================================================
create table if not exists public.user_financials (
  user_id uuid primary key references auth.users(id) on delete cascade,
  available_balance numeric(18,2) not null default 0,
  currency text not null default 'USD',
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 3. PER-USER BANK DETAILS
-- ============================================================
create table if not exists public.user_bank_details (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bank_name text,
  account_name text,
  account_number text,
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 4. ADMIN ALLOW-LIST
-- ============================================================
create table if not exists public.admin_users (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ============================================================
-- 5. CHAT TABLES
-- IMPORTANT: These tables are created BEFORE any chat policies.
-- ============================================================
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  agent_id text,
  agent_name text,
  agent_photo text,
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender text not null check (sender in ('user','agent')),
  sender_id uuid references auth.users(id) on delete set null,
  body text,
  media_url text,
  media_type text,
  created_at timestamptz not null default now()
);

create index if not exists conversations_user_id_idx
  on public.conversations(user_id);

create index if not exists conversations_agent_id_idx
  on public.conversations(agent_id);

create index if not exists conversations_last_message_at_idx
  on public.conversations(last_message_at desc);

create index if not exists messages_conversation_id_idx
  on public.messages(conversation_id);

create index if not exists messages_created_at_idx
  on public.messages(created_at);

-- ============================================================
-- 6. GLOBAL PAYOUT SETTINGS
-- These details are shown to every user in Top Up.
-- They are separate from per-user bank details above.
-- ============================================================
create table if not exists public.payout_settings (
  id integer primary key,
  bank_name text,
  account_name text,
  account_number text,
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 7. COMMON UPDATED_AT TRIGGER
-- ============================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists user_financials_set_updated_at on public.user_financials;
create trigger user_financials_set_updated_at
before update on public.user_financials
for each row execute function public.set_updated_at();

drop trigger if exists user_bank_details_set_updated_at on public.user_bank_details;
create trigger user_bank_details_set_updated_at
before update on public.user_bank_details
for each row execute function public.set_updated_at();

drop trigger if exists payout_settings_set_updated_at on public.payout_settings;
create trigger payout_settings_set_updated_at
before update on public.payout_settings
for each row execute function public.set_updated_at();

-- ============================================================
-- 8. CHAT LAST-MESSAGE TRIGGER
-- ============================================================
create or replace function public.update_conversation_last_message()
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

drop trigger if exists messages_update_conversation_time on public.messages;
create trigger messages_update_conversation_time
after insert on public.messages
for each row execute function public.update_conversation_last_message();

-- ============================================================
-- 9. AUTH USER -> PROFILE/FINANCIAL RECORD TRIGGER
-- Every new signup gets a DB row immediately.
-- onboarding_step=1 means section 1 has been passed and email
-- verification/onboarding can resume later.
-- ============================================================
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (
    id, full_name, email, onboarding_step, onboarding_completed
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    new.email,
    1,
    false
  )
  on conflict (id) do update set
    email = excluded.email,
    full_name = case
      when coalesce(public.profiles.full_name,'') = ''
      then excluded.full_name
      else public.profiles.full_name
    end,
    updated_at = now();

  insert into public.user_financials (user_id, available_balance, currency)
  values (new.id, 0, 'USD')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_agentconnect on auth.users;
create trigger on_auth_user_created_agentconnect
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Keep application email synchronized with Auth email.
create or replace function public.sync_profile_auth_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
  set email = new.email, updated_at = now()
  where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed_agentconnect on auth.users;
create trigger on_auth_user_email_changed_agentconnect
after update of email on auth.users
for each row execute function public.sync_profile_auth_email();

-- ============================================================
-- 10. BACKFILL USERS THAT ALREADY EXIST IN AUTH
-- This is important if the script is being run after earlier tests.
-- ============================================================
insert into public.profiles (
  id, full_name, email, onboarding_step, onboarding_completed
)
select
  u.id,
  coalesce(u.raw_user_meta_data->>'full_name',''),
  u.email,
  1,
  false
from auth.users u
on conflict (id) do update set
  email = excluded.email,
  full_name = case
    when coalesce(public.profiles.full_name,'') = ''
    then excluded.full_name
    else public.profiles.full_name
  end;

insert into public.user_financials (user_id, available_balance, currency)
select u.id, 0, 'USD'
from auth.users u
on conflict (user_id) do nothing;

-- ============================================================
-- 11. ADMIN CHECK
-- ============================================================
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users
    where id = auth.uid()
  );
$$;

-- ============================================================
-- 12. USER ONBOARDING RPC
-- Frontend calls this instead of directly changing protected fields.
-- ============================================================
create or replace function public.complete_profile(
  p_full_name text,
  p_dob date,
  p_location text,
  p_avatar_url text default null,
  p_biometric_enabled boolean default false
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.profiles;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.profiles
  set
    full_name = nullif(trim(p_full_name),''),
    email = (select email from auth.users where id = auth.uid()),
    dob = p_dob,
    location = nullif(trim(p_location),''),
    avatar_url = coalesce(p_avatar_url, avatar_url),
    biometric_enabled = coalesce(p_biometric_enabled,false),
    onboarding_step = 3,
    onboarding_completed = true,
    updated_at = now()
  where id = auth.uid()
  returning * into result;

  if result.id is null then
    raise exception 'Profile not found';
  end if;

  return result;
end;
$$;

-- ============================================================
-- 13. ADMIN USER DETAILS RPC
-- Admin can change balance + per-user bank details.
-- Normal users cannot call this successfully.
-- ============================================================
create or replace function public.admin_update_user_details(
  p_user_id uuid,
  p_available_balance numeric,
  p_bank_name text,
  p_account_name text,
  p_account_number text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized';
  end if;

  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'User does not exist';
  end if;

  if p_available_balance is null or p_available_balance < 0 then
    raise exception 'Balance must be zero or greater';
  end if;

  insert into public.user_financials(user_id, available_balance, currency)
  values (p_user_id, round(p_available_balance,2), 'USD')
  on conflict (user_id) do update set
    available_balance = excluded.available_balance,
    updated_at = now();

  insert into public.user_bank_details(
    user_id, bank_name, account_name, account_number, updated_at
  )
  values (
    p_user_id,
    nullif(trim(p_bank_name),''),
    nullif(trim(p_account_name),''),
    nullif(trim(p_account_number),''),
    now()
  )
  on conflict (user_id) do update set
    bank_name = excluded.bank_name,
    account_name = excluded.account_name,
    account_number = excluded.account_number,
    updated_at = now();

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id
  );
end;
$$;

-- ============================================================
-- 14. RLS - ENABLE AFTER ALL TABLES EXIST
-- ============================================================
alter table public.profiles enable row level security;
alter table public.user_financials enable row level security;
alter table public.user_bank_details enable row level security;
alter table public.admin_users enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.payout_settings enable row level security;

-- ---------------- profiles ----------------
drop policy if exists profiles_select_own_or_admin on public.profiles;
drop policy if exists profiles_update_own on public.profiles;

create policy profiles_select_own_or_admin
on public.profiles
for select to authenticated
using (id = auth.uid() or public.is_admin());

-- Keep protected onboarding fields out of direct client writes.
-- The dashboard uses complete_profile() instead.
create policy profiles_update_own
on public.profiles
for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- ---------------- financials ----------------
drop policy if exists financials_select_own_or_admin on public.user_financials;
create policy financials_select_own_or_admin
on public.user_financials
for select to authenticated
using (user_id = auth.uid() or public.is_admin());

-- No client INSERT/UPDATE/DELETE policy for financials.
-- Balance changes go through the admin RPC.

-- ---------------- bank details ----------------
drop policy if exists bank_select_own_or_admin on public.user_bank_details;
create policy bank_select_own_or_admin
on public.user_bank_details
for select to authenticated
using (user_id = auth.uid() or public.is_admin());

-- No client write policy for bank details.

-- ---------------- admin list ----------------
drop policy if exists admin_users_self_select on public.admin_users;
create policy admin_users_self_select
on public.admin_users
for select to authenticated
using (id = auth.uid());

-- ---------------- conversations ----------------
drop policy if exists conversations_select_user_or_admin on public.conversations;
drop policy if exists conversations_insert_user_or_admin on public.conversations;
drop policy if exists conversations_admin_update_delete on public.conversations;

create policy conversations_select_user_or_admin
on public.conversations
for select to authenticated
using (user_id = auth.uid() or public.is_admin());

create policy conversations_insert_user_or_admin
on public.conversations
for insert to authenticated
with check (user_id = auth.uid() or public.is_admin());

create policy conversations_admin_update_delete
on public.conversations
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- ---------------- messages ----------------
drop policy if exists messages_select_user_or_admin on public.messages;
drop policy if exists messages_insert_user on public.messages;
drop policy if exists messages_admin_all on public.messages;

create policy messages_select_user_or_admin
on public.messages
for select to authenticated
using (
  public.is_admin()
  or exists (
    select 1
    from public.conversations c
    where c.id = conversation_id
      and c.user_id = auth.uid()
  )
);

create policy messages_insert_user
on public.messages
for insert to authenticated
with check (
  sender = 'user'
  and sender_id = auth.uid()
  and exists (
    select 1
    from public.conversations c
    where c.id = conversation_id
      and c.user_id = auth.uid()
  )
);

create policy messages_admin_all
on public.messages
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- ---------------- payout settings ----------------
drop policy if exists payout_settings_select_authenticated on public.payout_settings;
drop policy if exists payout_settings_admin_write on public.payout_settings;

create policy payout_settings_select_authenticated
on public.payout_settings
for select to authenticated
using (true);

create policy payout_settings_admin_write
on public.payout_settings
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- ============================================================
-- 15. TABLE GRANTS
-- ============================================================
grant select on public.profiles to authenticated;
grant select on public.user_financials to authenticated;
grant select on public.user_bank_details to authenticated;
grant select, insert on public.conversations to authenticated;
grant select, insert on public.messages to authenticated;
grant select, insert, update on public.payout_settings to authenticated;

-- Remove direct profile updates from the Data API. The RPC handles onboarding.
revoke update on public.profiles from authenticated;

-- Function permissions.
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

revoke all on function public.complete_profile(text,date,text,text,boolean) from public;
grant execute on function public.complete_profile(text,date,text,text,boolean) to authenticated;

revoke all on function public.admin_update_user_details(uuid,numeric,text,text,text) from public;
grant execute on function public.admin_update_user_details(uuid,numeric,text,text,text) to authenticated;

-- ============================================================
-- 16. STORAGE BUCKETS
-- ============================================================
insert into storage.buckets (id, name, public)
values ('avatars','avatars',true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('chat-media','chat-media',true)
on conflict (id) do update set public = true;

-- Avatar files use: <user UUID>/<filename>
drop policy if exists avatars_public_read on storage.objects;
drop policy if exists avatars_user_insert on storage.objects;
drop policy if exists avatars_user_update on storage.objects;
drop policy if exists avatars_user_delete on storage.objects;

create policy avatars_public_read
on storage.objects for select
using (bucket_id = 'avatars');

create policy avatars_user_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy avatars_user_update
on storage.objects for update to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy avatars_user_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Chat media uses: <conversation UUID>/<filename>
drop policy if exists chat_media_public_read on storage.objects;
drop policy if exists chat_media_authenticated_insert on storage.objects;
drop policy if exists chat_media_admin_update on storage.objects;
drop policy if exists chat_media_admin_delete on storage.objects;

create policy chat_media_public_read
on storage.objects for select
using (bucket_id = 'chat-media');

create policy chat_media_authenticated_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.conversations c
      where c.id::text = (storage.foldername(name))[1]
        and c.user_id = auth.uid()
    )
  )
);

create policy chat_media_admin_update
on storage.objects for update to authenticated
using (bucket_id = 'chat-media' and public.is_admin())
with check (bucket_id = 'chat-media' and public.is_admin());

create policy chat_media_admin_delete
on storage.objects for delete to authenticated
using (bucket_id = 'chat-media' and public.is_admin());

-- ============================================================
-- 17. REALTIME
-- ============================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.conversations;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;

-- ============================================================
-- 18. OPTIONAL INITIAL PAYOUT DATA
-- Uncomment and edit if desired.
-- ============================================================
-- insert into public.payout_settings(id, bank_name, account_name, account_number)
-- values (1, 'Your Bank', 'Your Account Name', 'Your Account Number')
-- on conflict (id) do update set
--   bank_name = excluded.bank_name,
--   account_name = excluded.account_name,
--   account_number = excluded.account_number,
--   updated_at = now();

-- ============================================================
-- 19. CREATE YOUR ADMIN
-- IMPORTANT: Run this AFTER the admin account exists in
-- Authentication -> Users.
-- Replace the email with the exact admin email.
-- ============================================================
-- insert into public.admin_users(id)
-- select id
-- from auth.users
-- where lower(email) = lower('YOUR-ADMIN-EMAIL@example.com')
-- on conflict (id) do nothing;

-- ============================================================
-- END
-- ============================================================
