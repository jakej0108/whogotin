-- profile_guards: stop users from setting server-owned fields on their own
-- profile rows through the public API.
--
-- Why: the "users insert/update their own profiles" RLS policies allow every
-- column, so anyone could send verified = true (no proof uploaded) or set
-- their own view_count / like_count directly.
--
-- What this enforces for requests made by site users (roles anon and
-- authenticated, not admins):
--   * verified is computed, never trusted: it is true only when
--     verification_path points at a file that actually exists in the
--     verification-docs bucket, inside that user's own folder.
--   * view_count and like_count can't be changed directly. They start at 0
--     and only move through increment_profile_view() and the like triggers,
--     which run as SECURITY DEFINER and are unaffected.
--   * status must be accepted, waitlisted or rejected (new/changed rows only;
--     existing rows are not re-checked).
--
-- Admins (is_admin()) and anything run from the SQL Editor are not affected.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again.

-- True when the file exists in the user's own folder of verification-docs.
-- SECURITY DEFINER so it can look in storage.objects; it only answers
-- yes/no and only for paths under the caller's own folder.
create or replace function public.verification_file_exists(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_path is not null
     and auth.uid() is not null
     and split_part(p_path, '/', 1) = auth.uid()::text
     and exists (
       select 1 from storage.objects o
        where o.bucket_id = 'verification-docs' and o.name = p_path
     );
$$;

revoke execute on function public.verification_file_exists(text) from public, anon;
grant execute on function public.verification_file_exists(text) to authenticated;

-- Deliberately SECURITY INVOKER: current_user is then the role that made
-- the change. Direct API requests run as anon/authenticated; the view and
-- like counters run as the function owner, so they pass through untouched.
create or replace function public.profiles_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.view_count := 0;
    new.like_count := 0;
  else
    new.view_count := old.view_count;
    new.like_count := old.like_count;
  end if;

  new.verified := coalesce(public.verification_file_exists(new.verification_path), false);

  if new.status is null or new.status not in ('accepted', 'waitlisted', 'rejected') then
    raise exception 'Invalid decision status.';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before insert or update on public.profiles
  for each row execute function public.profiles_guard();
