-- account_pages: support for the /account/* pages.
--
--   1. user_settings.class_year  - "College entry year" on /account/profile
--   2. delete_my_account()       - "Delete my account" on /account/settings
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again.

-- ---------------------------------------------------------------------------
-- 1. College entry year on the profile
-- ---------------------------------------------------------------------------
alter table public.user_settings
  add column if not exists class_year smallint;

alter table public.user_settings
  drop constraint if exists user_settings_class_year_range;
alter table public.user_settings
  add constraint user_settings_class_year_range
  check (class_year is null or class_year between 1990 and 2100);

-- ---------------------------------------------------------------------------
-- 2. Delete my account
-- ---------------------------------------------------------------------------
-- Deletes everything the signed-in user owns, then the auth user itself.
-- Rows are deleted explicitly (not only through ON DELETE CASCADE) so this
-- works whatever the foreign keys on the older tables say.
--
-- Tables that reference auth.users with ON DELETE CASCADE are cleared by
-- the final delete: user_handles, user_contacts, email_verifications,
-- email_outbox, comments (and replies to them), comment_votes,
-- content_reports.
--
-- Verification files in the verification-docs bucket can't be deleted
-- from SQL; the page removes them through the Storage API first.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Guest sessions have no account to delete.';
  end if;

  delete from public.saved_profiles     where user_id = v_uid;
  delete from public.profile_likes      where user_id = v_uid;
  delete from public.saved_schools      where user_id = v_uid;
  delete from public.progress_snapshots where user_id = v_uid;
  delete from public.user_settings      where user_id = v_uid;
  delete from public.reports            where reporter_id = v_uid;
  delete from public.profiles           where owner_id = v_uid;

  delete from auth.users where id = v_uid;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant  execute on function public.delete_my_account() to authenticated;

-- Test (as a signed-in user, from the browser console):
--   await supabaseClient.rpc('delete_my_account')
-- then `select * from auth.users where id = '<that id>'` returns nothing.
