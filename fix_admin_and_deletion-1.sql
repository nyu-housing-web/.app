-- ============================================================
-- AgentConnect: admin access + account deletion fixes
-- Run this whole script in the Supabase SQL Editor.
-- It is written to be safe to re-run (idempotent).
-- ============================================================

-- ------------------------------------------------------------
-- 1) Make sure admin_users exists with the shape admin.html expects:
--    a table whose "id" is the Supabase Auth user's UUID.
-- ------------------------------------------------------------
create table if not exists public.admin_users (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

-- Without a SELECT policy, RLS silently blocks an admin's own check
-- against this table, and admin.html then shows "Not authorized"
-- even for a real admin. This is the most likely cause of your
-- "can't log into the admin dashboard" issue.
drop policy if exists "Admins can read their own admin row" on public.admin_users;
create policy "Admins can read their own admin row"
  on public.admin_users for select
  using (auth.uid() = id);

-- ------------------------------------------------------------
-- 2) Grant nasty00night@gmail.com admin access.
--    admin_users is keyed by the auth user's id (a UUID), not the
--    email itself, so this looks the id up from auth.users first.
-- ------------------------------------------------------------
insert into public.admin_users (id)
select id from auth.users where lower(email) = 'nasty00night@gmail.com'
on conflict (id) do nothing;

-- Run this after, to confirm it worked (should return 1 row):
-- select au.id, u.email, au.created_at
-- from public.admin_users au
-- join auth.users u on u.id = au.id
-- where lower(u.email) = 'nasty00night@gmail.com';
--
-- If it returns 0 rows, that email doesn't exist in auth.users at all
-- (typo, or the account was never created) — check with:
-- select id, email, created_at from auth.users where lower(email) = 'nasty00night@gmail.com';

-- ------------------------------------------------------------
-- 3) Fix "users cannot delete their accounts".
--    The typical cause: your delete-account edge function deletes the
--    auth.users row, but other tables (profiles, user_financials,
--    user_bank_details, conversations, messages, transactions,
--    admin_users, etc.) reference that user without ON DELETE CASCADE,
--    so Postgres blocks the delete with a foreign-key violation.
--    This finds every foreign key in the public schema that points at
--    auth.users(id) or public.profiles(id) and makes it cascade,
--    skipping (and reporting) any it can't safely change instead of
--    aborting the whole script.
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select
      tc.table_schema,
      tc.table_name,
      tc.constraint_name,
      kcu.column_name,
      ccu.table_schema as ref_schema,
      ccu.table_name as ref_table,
      ccu.column_name as ref_column
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on tc.constraint_name = kcu.constraint_name
     and tc.table_schema = kcu.table_schema
    join information_schema.constraint_column_usage ccu
      on tc.constraint_name = ccu.constraint_name
     and tc.table_schema = ccu.table_schema
    where tc.constraint_type = 'FOREIGN KEY'
      and tc.table_schema = 'public'
      and (
        (ccu.table_schema = 'auth' and ccu.table_name = 'users')
        or (ccu.table_schema = 'public' and ccu.table_name = 'profiles')
      )
  loop
    begin
      execute format(
        'alter table %I.%I drop constraint %I',
        r.table_schema, r.table_name, r.constraint_name
      );
      execute format(
        'alter table %I.%I add constraint %I foreign key (%I) references %I.%I(%I) on delete cascade',
        r.table_schema, r.table_name, r.constraint_name,
        r.column_name, r.ref_schema, r.ref_table, r.ref_column
      );
      raise notice 'Cascaded: %.% (%)', r.table_name, r.column_name, r.constraint_name;
    exception when others then
      raise notice 'Skipped %.% (%): %', r.table_name, r.column_name, r.constraint_name, sqlerrm;
    end;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 4) A defensive, database-level way for a signed-in user to delete
--    their own account, independent of your delete-account edge
--    function. SECURITY DEFINER lets it remove the auth.users row
--    (something a normal authenticated user can't do directly);
--    step 3 above makes that cascade correctly into every table.
--    Call it from the client as: supabaseClient.rpc('delete_own_account')
-- ------------------------------------------------------------
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;

-- ============================================================
-- Done. If account deletion still fails after this, check your
-- delete-account edge function's own logs — this script fixes the
-- database side (constraints + a working delete path), but the
-- edge function's code itself isn't visible from the SQL editor.
-- ============================================================
