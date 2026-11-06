-- Email + password sign-in, and moving a guest's result by email.
--
-- Sign-in is Google, or email + password (no more magic links). The login
-- popup asks for the email first and calls auth_email_status() to decide
-- what to show next:
--   'password'    -> password box (log in)
--   'google'      -> "This email uses Google"
--   'no_password' -> old magic-link account: email a link to set a password
--   'unconfirmed' -> signed up but never clicked the confirmation link
--   'new'         -> create a password (sign up)
-- This tells anyone whether an email has an account. That was an accepted
-- trade-off for the email-first login.
--
-- Guests (anonymous users who submitted a result) sign up with signUp(),
-- which creates a separate account. Before that, the guest calls
-- offer_my_guest_data(email). Whoever later signs in with that email,
-- confirmed, on any device, gets the guest's results via
-- claim_my_guest_data(). A guest can only offer its own data, and only to
-- someone who proves they own the email, so this can't be used to take
-- anyone else's results.
--
-- claim_my_guest_data() also picks up guests that confirmed a notification
-- email the old way (user_contacts.verified_at) and then signed up with the
-- same email somewhere else.
--
-- Install: run sql/email_backbone.sql first, then paste this whole file into
-- Supabase -> SQL Editor -> Run. Safe to run again.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Email-first login
-- ---------------------------------------------------------------------------

create or replace function public.auth_email_status(p_email text)
returns text
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user  auth.users;
begin
  if char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return 'invalid';
  end if;

  select * into v_user from auth.users u
   where lower(u.email) = v_email and coalesce(u.is_anonymous, false) = false
   order by u.created_at
   limit 1;
  if not found then return 'new'; end if;

  if coalesce(v_user.encrypted_password, '') <> '' then
    return case when v_user.email_confirmed_at is null then 'unconfirmed' else 'password' end;
  end if;
  if exists (select 1 from auth.identities i where i.user_id = v_user.id and i.provider = 'google') then
    return 'google';
  end if;
  if v_user.email_confirmed_at is null then
    return 'new'; -- started a magic-link sign-up and never finished it
  end if;
  return 'no_password';
end;
$$;

-- ---------------------------------------------------------------------------
-- Guest -> account, by email
-- ---------------------------------------------------------------------------

create table if not exists public.guest_email_offers (
  anon_user_id uuid not null,
  email        text not null,
  created_at   timestamptz not null default now(),
  claimed_by   uuid,
  claimed_at   timestamptz,
  primary key (anon_user_id, email)
);
alter table public.guest_email_offers enable row level security;
revoke all on public.guest_email_offers from anon, authenticated;
create index if not exists guest_email_offers_email_idx on public.guest_email_offers (email);

create or replace function public.offer_my_guest_data(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if v_uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false then
    return; -- only guests have anything to hand over
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That doesn''t look like an email address.';
  end if;
  if (select count(*) from guest_email_offers where anon_user_id = v_uid) >= 5 then
    raise exception 'Too many tries. Try again later.';
  end if;
  insert into guest_email_offers (anon_user_id, email) values (v_uid, v_email)
  on conflict (anon_user_id, email) do update set created_at = now();
end;
$$;

-- Moves one guest's data to a real account. Internal: not callable from the
-- API. Same moves as claim_anonymous_account() in email_backbone.sql.
create or replace function public.move_guest_data(p_from uuid, p_to uuid)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_moved int := 0;
begin
  if p_from is null or p_to is null or p_from = p_to then return 0; end if;
  -- Only ever take over a guest account, never a real one.
  if not exists (select 1 from auth.users u where u.id = p_from and u.is_anonymous) then
    return 0;
  end if;

  update profiles set owner_id = p_to where owner_id = p_from;
  get diagnostics v_moved = row_count;

  if exists (select 1 from user_contacts where user_id = p_to) then
    delete from user_contacts where user_id = p_from;
  else
    update user_contacts set user_id = p_to where user_id = p_from;
  end if;
  update email_outbox set user_id = p_to where user_id = p_from and sent_at is null;

  -- Recorded as a used claim so verification_file_exists() still accepts
  -- the guest's uploaded files (they live in "<guest id>/..." folders).
  insert into account_claims (token_hash, anon_user_id, claimed_by, claimed_at)
  values (digest(gen_random_bytes(32), 'sha256'), p_from, p_to, now());
  return v_moved;
end;
$$;

create or replace function public.claim_my_guest_data()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_anon  uuid;
  v_moved int := 0;
begin
  if v_uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return 0;
  end if;
  select lower(u.email) into v_email from auth.users u
   where u.id = v_uid and u.email is not null and u.email_confirmed_at is not null;
  if v_email is null then return 0; end if;

  for v_anon in
    select o.anon_user_id from guest_email_offers o
     where o.email = v_email and o.claimed_by is null
       and o.created_at > now() - interval '60 days'
    union
    select c.user_id from user_contacts c
      join auth.users u on u.id = c.user_id and u.is_anonymous
     where lower(c.email) = v_email and c.verified_at is not null
  loop
    v_moved := v_moved + move_guest_data(v_anon, v_uid);
    update guest_email_offers set claimed_by = v_uid, claimed_at = now()
     where anon_user_id = v_anon and claimed_by is null;
  end loop;
  return v_moved;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function public.auth_email_status(text)    from public;
revoke execute on function public.offer_my_guest_data(text)  from public, anon;
revoke execute on function public.move_guest_data(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.claim_my_guest_data()      from public, anon;
grant  execute on function public.auth_email_status(text)    to anon, authenticated;
grant  execute on function public.offer_my_guest_data(text)  to authenticated;
grant  execute on function public.claim_my_guest_data()      to authenticated;
