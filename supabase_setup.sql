-- AgentConnect / Supabase database setup
-- Run this entire file in Supabase Dashboard -> SQL Editor.
-- IMPORTANT: keep your Supabase anon/publishable key in the frontend only; NEVER use a service-role key in dashboard.html/admin.html.

create extension if not exists pgcrypto;

-- ============================================================
-- 1) Core profile/account tables
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

create table if not exists public.user_financials (
  user_id uuid primary key references auth.users(id) on delete cascade,
  available_balance numeric(18,2) not null default 0,
  currency text not null default 'USD',
  updated_at timestamptz not null default now()
);

create table if not exists public.user_bank_details (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bank_name text,
  account_name text,
  account_number text,
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 2) Admin allow-list
-- ============================================================
create table if not exists public.admin_users (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ============================================================
-- 3) Automatically create application rows when Auth creates a user
--    This is what records the first signup section as onboarding_step=1.
-- ============================================================
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, onboarding_step, onboarding_completed)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''), new.email, 1, false)
  on conflict (id) do update
    set email = excluded.email,
        full_name = case when coalesce(public.profiles.full_name,'') = '' then excluded.full_name else public.profiles.full_name end,
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

-- Keep profile email synchronized when the Auth email changes.
create or replace function public.sync_profile_auth_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set email = new.email, updated_at = now() where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed_agentconnect on auth.users;
create trigger on_auth_user_email_changed_agentconnect
after update of email on auth.users
for each row execute function public.sync_profile_auth_email();

-- ============================================================
-- 4) Updated-at helper
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
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists user_financials_set_updated_at on public.user_financials;
create trigger user_financials_set_updated_at before update on public.user_financials
for each row execute function public.set_updated_at();
drop trigger if exists user_bank_details_set_updated_at on public.user_bank_details;
create trigger user_bank_details_set_updated_at before update on public.user_bank_details
for each row execute function public.set_updated_at();

-- ============================================================
-- 5) Admin authorization helper
-- ============================================================
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users a where a.id = auth.uid()
  );
$$;

-- ============================================================
-- 6) Complete profile/onboarding RPC
--    Users can update their own onboarding through this function,
--    but cannot use it to modify balance or bank details.
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
     set full_name = nullif(trim(p_full_name),''),
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
-- 7) Admin RPC for balance + per-user bank details
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

  if p_available_balance is null or p_available_balance < 0 then
    raise exception 'Balance must be zero or greater';
  end if;

  update public.user_financials
     set available_balance = round(p_available_balance,2),
         updated_at = now()
   where user_id = p_user_id;

  if not found then
    insert into public.user_financials(user_id, available_balance, currency)
    values (p_user_id, round(p_available_balance,2), 'USD');
  end if;

  insert into public.user_bank_details(user_id, bank_name, account_name, account_number, updated_at)
  values (p_user_id, nullif(trim(p_bank_name),''), nullif(trim(p_account_name),''), nullif(trim(p_account_number),''), now())
  on conflict (user_id) do update set
    bank_name = excluded.bank_name,
    account_name = excluded.account_name,
    account_number = excluded.account_number,
    updated_at = now();

  return jsonb_build_object('success', true, 'user_id', p_user_id);
end;
$$;

-- ============================================================
-- 8) RLS
-- ============================================================
alter table public.profiles enable row level security;
alter table public.user_financials enable row level security;
alter table public.user_bank_details enable row level security;
alter table public.admin_users enable row level security;

-- Drop/recreate only policies created by this script.
drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists profiles_admin_select on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy profiles_update_own on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_admin_select on public.profiles for select to authenticated using (public.is_admin());

drop policy if exists financials_select_own on public.user_financials;
drop policy if exists financials_admin_select on public.user_financials;
create policy financials_select_own on public.user_financials for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy financials_admin_select on public.user_financials for select to authenticated using (public.is_admin());

drop policy if exists bank_select_own on public.user_bank_details;
drop policy if exists bank_admin_select on public.user_bank_details;
create policy bank_select_own on public.user_bank_details for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy bank_admin_select on public.user_bank_details for select to authenticated using (public.is_admin());

drop policy if exists admin_users_self_select on public.admin_users;
create policy admin_users_self_select on public.admin_users for select to authenticated using (id = auth.uid());

-- RPC execution permissions.
revoke all on function public.complete_profile(text,date,text,text,boolean) from public;
grant execute on function public.complete_profile(text,date,text,text,boolean) to authenticated;
revoke all on function public.admin_update_user_details(uuid,numeric,text,text,text) from public;
grant execute on function public.admin_update_user_details(uuid,numeric,text,text,text) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- Table grants for frontend Data API.
grant select on public.profiles, public.user_financials, public.user_bank_details to authenticated;
grant update on public.profiles to authenticated;

-- ============================================================
-- 9) Existing chat tables: admin needs full access, users only their chats.
--    These policies are additive and safe to run repeatedly.
-- ============================================================
alter table if exists public.conversations enable row level security;
alter table if exists public.messages enable row level security;

drop policy if exists conversations_user_select on public.conversations;
drop policy if exists conversations_user_insert on public.conversations;
drop policy if exists conversations_admin_all on public.conversations;
create policy conversations_user_select on public.conversations for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy conversations_user_insert on public.conversations for insert to authenticated with check (user_id = auth.uid() or public.is_admin());
create policy conversations_admin_all on public.conversations for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists messages_user_select on public.messages;
drop policy if exists messages_user_insert on public.messages;
drop policy if exists messages_admin_all on public.messages;
create policy messages_user_select on public.messages for select to authenticated using (exists(select 1 from public.conversations c where c.id = conversation_id and (c.user_id = auth.uid() or public.is_admin())));
create policy messages_user_insert on public.messages for insert to authenticated with check (sender_id = auth.uid() and sender = 'user' and exists(select 1 from public.conversations c where c.id = conversation_id and c.user_id = auth.uid()));
create policy messages_admin_all on public.messages for all to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert on public.conversations to authenticated;
grant select, insert on public.messages to authenticated;

-- ============================================================
-- 10) Global payout settings table used by Top Up screen
-- ============================================================
create table if not exists public.payout_settings (
  id integer primary key,
  bank_name text,
  account_name text,
  account_number text,
  updated_at timestamptz not null default now()
);
alter table public.payout_settings enable row level security;
drop policy if exists payout_settings_authenticated_select on public.payout_settings;
drop policy if exists payout_settings_admin_write on public.payout_settings;
create policy payout_settings_authenticated_select on public.payout_settings for select to authenticated using (true);
create policy payout_settings_admin_write on public.payout_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update on public.payout_settings to authenticated;

-- ============================================================
-- 11) Storage buckets used by the supplied HTML files
-- ============================================================
insert into storage.buckets (id, name, public)
values ('avatars','avatars',true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('chat-media','chat-media',true)
on conflict (id) do update set public = true;

-- Avatar files: first folder must be the authenticated user's UUID.
drop policy if exists avatars_public_read on storage.objects;
drop policy if exists avatars_user_insert on storage.objects;
drop policy if exists avatars_user_update on storage.objects;
drop policy if exists avatars_user_delete on storage.objects;
create policy avatars_public_read on storage.objects for select using (bucket_id='avatars');
create policy avatars_user_insert on storage.objects for insert to authenticated with check (bucket_id='avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_user_update on storage.objects for update to authenticated using (bucket_id='avatars' and (storage.foldername(name))[1] = auth.uid()::text) with check (bucket_id='avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_user_delete on storage.objects for delete to authenticated using (bucket_id='avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Chat media: users may upload into their conversation folder; admins may upload anywhere.
drop policy if exists chat_media_public_read on storage.objects;
drop policy if exists chat_media_authenticated_insert on storage.objects;
drop policy if exists chat_media_admin_update on storage.objects;
create policy chat_media_public_read on storage.objects for select using (bucket_id='chat-media');
create policy chat_media_authenticated_insert on storage.objects for insert to authenticated with check (bucket_id='chat-media' and (public.is_admin() or exists(select 1 from public.conversations c where c.id::text = (storage.foldername(name))[1] and c.user_id = auth.uid())));
create policy chat_media_admin_update on storage.objects for update to authenticated using (bucket_id='chat-media' and public.is_admin()) with check (bucket_id='chat-media' and public.is_admin());

-- ============================================================
-- 12) Realtime publication
-- ============================================================
do $$
begin
  begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.conversations; exception when duplicate_object then null; end;
end $$;

-- ============================================================
-- 13) IMPORTANT: create your first admin after signing up that admin account.
-- Replace the email below with the exact email of the admin Auth account.
-- Run only after that account exists in Authentication -> Users.
-- ============================================================
-- insert into public.admin_users (id)
-- select id from auth.users where lower(email) = lower('YOUR-ADMIN-EMAIL@example.com')
-- on conflict (id) do nothing;

-- ============================================================
-- 14) Optional: initialize global Top Up details.
-- Replace values before running if desired.
-- ============================================================
-- insert into public.payout_settings(id, bank_name, account_name, account_number)
-- values (1, 'Your Bank', 'Your Account Name', 'Your Account Number')
-- on conflict (id) do update set bank_name=excluded.bank_name, account_name=excluded.account_name, account_number=excluded.account_number, updated_at=now();
