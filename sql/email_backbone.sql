-- email_backbone: contact emails, verification, unsubscribe, the email
-- outbox, new-results digests, and claiming guest (anonymous) submissions.
--
-- How email works:
--   * Nothing in the database sends email. Triggers, RPCs and scheduled jobs
--     only INSERT rows into email_outbox.
--   * The email-sender Edge Function (supabase/functions/email-sender) runs
--     every minute (sql/email_cron.sql). It calls claim_email_batch(), which
--     drops rows the person shouldn't get (no email, unverified, category
--     turned off) and hands back the rest. It sends them, then calls
--     finish_email().
--   * email_outbox.dedupe_key is unique, so the same email can never be
--     queued twice. Callers build keys like 'reply:{user}:{parent}:{hour}'
--     so that also caps how often someone can be emailed.
--
-- Privacy: user_contacts, email_verifications, email_outbox, account_claims
-- and app_settings can't be read with the anon key at all. A signed-in user
-- can read only their own user_contacts row. Every change goes through the
-- SECURITY DEFINER functions below.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again. Then follow sql/email_cron.sql.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

-- Admission season (month-day, wraps over New Year) and digest cadence.
-- Change these with an UPDATE; nothing is hardcoded in the functions.
insert into public.app_settings (key, value) values
  ('digest_season',   '{"start": "12-15", "end": "04-30"}'),
  ('digest_interval', '{"season_days": 14, "off_season_days": 30, "min_results": 3}')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- user_contacts
-- ---------------------------------------------------------------------------

create table if not exists public.user_contacts (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  email            text,
  verified_at      timestamptz,
  unsub_token      text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  prefs            jsonb not null default '{"replies": true, "waitlist": true, "digest": true, "updates": true}',
  last_digest_at   timestamptz,
  -- Set when the person used "Delete my email": the row stays (email null,
  -- everything off) so signing in again doesn't silently re-add the address.
  email_deleted_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint user_contacts_email_format check (
    email is null or (char_length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
  )
);

alter table public.user_contacts enable row level security;
revoke all on public.user_contacts from anon, authenticated;
grant select on public.user_contacts to authenticated;

drop policy if exists "user_contacts select own" on public.user_contacts;
create policy "user_contacts select own" on public.user_contacts
  for select to authenticated using (auth.uid() = user_id);

create index if not exists user_contacts_email_idx on public.user_contacts (lower(email));

-- Only known keys, only booleans (plus waitlist_off: schools the person
-- doesn't want waitlist emails for). Anything else is dropped.
create or replace function public.sanitize_email_prefs(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
    from (
      select k, to_jsonb((p ->> k)::boolean) as v
        from unnest(array['replies', 'waitlist', 'digest', 'updates']) as k
       where jsonb_typeof(p -> k) = 'boolean'
      union all
      select 'waitlist_off',
             coalesce((select jsonb_agg(x.e)
                         from (select distinct left(e, 200) as e
                                 from jsonb_array_elements_text(p -> 'waitlist_off') as e
                                limit 100) x), '[]'::jsonb)
       where jsonb_typeof(p -> 'waitlist_off') = 'array'
    ) s;
$$;

-- Shows "j•••@gmail.com" on the token-based preferences page, so a
-- forwarded email doesn't reveal the whole address.
create or replace function public.mask_email(p text)
returns text
language sql
immutable
as $$
  select case when p is null then null
              else left(split_part(p, '@', 1), 1) || '•••@' || split_part(p, '@', 2) end;
$$;

-- ---------------------------------------------------------------------------
-- Verification tokens (only the SHA-256 hash is stored)
-- ---------------------------------------------------------------------------

create table if not exists public.email_verifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  email      text not null,
  token_hash bytea not null unique,
  expires_at timestamptz not null default now() + interval '48 hours',
  used_at    timestamptz,
  created_at timestamptz not null default now()
);
alter table public.email_verifications enable row level security;
revoke all on public.email_verifications from anon, authenticated;
create index if not exists email_verifications_user_idx on public.email_verifications (user_id, created_at);
create index if not exists email_verifications_email_idx on public.email_verifications (email, created_at);

-- ---------------------------------------------------------------------------
-- Outbox
-- ---------------------------------------------------------------------------

create table if not exists public.email_outbox (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  kind           text not null check (kind in ('verify', 'reply', 'waitlist', 'digest', 'update')),
  payload        jsonb not null default '{}',
  dedupe_key     text not null unique,
  send_after     timestamptz not null default now(),
  sent_at        timestamptz,
  claimed_at     timestamptz,
  attempts       int not null default 0,
  last_error     text,
  skipped_reason text,
  created_at     timestamptz not null default now()
);
alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from anon, authenticated;
create index if not exists email_outbox_pending_idx on public.email_outbox (send_after)
  where sent_at is null and skipped_reason is null;

-- Outbox kind -> prefs key. 'verify' is an account email: always sent.
create or replace function public.email_pref_key(p_kind text)
returns text
language sql
immutable
as $$
  select case p_kind
           when 'reply'    then 'replies'
           when 'waitlist' then 'waitlist'
           when 'digest'   then 'digest'
           when 'update'   then 'updates'
         end;
$$;

-- ---------------------------------------------------------------------------
-- Signed-in user: email + preferences
-- ---------------------------------------------------------------------------

-- Called after every sign-in. A Google or magic-link account has already
-- proved it owns its auth email, so that email is saved as verified, unless
-- the person already has a contact email or deleted theirs.
create or replace function public.sync_my_auth_email()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
begin
  if v_uid is null then return; end if;
  select lower(u.email) into v_email
    from auth.users u
   where u.id = v_uid
     and coalesce(u.is_anonymous, false) = false
     and u.email is not null
     and u.email_confirmed_at is not null;
  if v_email is null then return; end if;

  insert into user_contacts (user_id, email, verified_at)
  values (v_uid, v_email, now())
  on conflict (user_id) do update
     set email       = coalesce(user_contacts.email, excluded.email),
         verified_at = case when coalesce(user_contacts.email, excluded.email) = excluded.email
                            then coalesce(user_contacts.verified_at, now())
                            else user_contacts.verified_at end,
         updated_at  = now()
   where user_contacts.email_deleted_at is null
     and (user_contacts.email is null
          or (user_contacts.email = excluded.email and user_contacts.verified_at is null));
end;
$$;

-- Set (or change) the contact email. If it's not already proven, a
-- verification email is queued and nothing else is sent until it's clicked.
-- Returns 'verified' or 'sent'.
create or replace function public.set_my_email(p_email text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid      uuid := auth.uid();
  v_email    text := lower(btrim(coalesce(p_email, '')));
  v_contact  user_contacts;
  v_auth     text;
  v_token    text;
  v_ver_id   uuid;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That doesn''t look like an email address.';
  end if;

  select * into v_contact from user_contacts where user_id = v_uid;
  if v_contact.email = v_email and v_contact.verified_at is not null then
    return 'verified';
  end if;

  -- Same as the account's own confirmed sign-in email: already proven.
  select lower(u.email) into v_auth from auth.users u
   where u.id = v_uid and coalesce(u.is_anonymous, false) = false and u.email_confirmed_at is not null;
  if v_auth = v_email then
    insert into user_contacts (user_id, email, verified_at) values (v_uid, v_email, now())
    on conflict (user_id) do update
       set email = excluded.email, verified_at = now(), email_deleted_at = null, updated_at = now();
    return 'verified';
  end if;

  -- Caps so this can't be used to spam someone else's inbox.
  if (select count(*) from email_verifications
       where user_id = v_uid and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many verification emails. Try again in an hour.';
  end if;
  if (select count(*) from email_verifications
       where email = v_email and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Too many verification emails were sent to that address today.';
  end if;

  insert into user_contacts (user_id, email, verified_at) values (v_uid, v_email, null)
  on conflict (user_id) do update
     set email = excluded.email, verified_at = null, email_deleted_at = null, updated_at = now();

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into email_verifications (user_id, email, token_hash)
  values (v_uid, v_email, digest(v_token, 'sha256'))
  returning id into v_ver_id;

  -- The raw token rides in the payload only until the email is sent;
  -- finish_email() removes it.
  insert into email_outbox (user_id, kind, payload, dedupe_key)
  values (v_uid, 'verify', jsonb_build_object('email', v_email, 'token', v_token), 'verify:' || v_ver_id);

  return 'sent';
end;
$$;

-- Verification link target. Works without signing in.
create or replace function public.verify_email(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row email_verifications;
begin
  select * into v_row from email_verifications
   where token_hash = digest(coalesce(p_token, ''), 'sha256')
     and used_at is null
     and expires_at > now();
  if not found then return false; end if;

  update email_verifications set used_at = now() where id = v_row.id;
  update user_contacts
     set verified_at = now(), updated_at = now()
   where user_id = v_row.user_id and email = v_row.email;
  return found;
end;
$$;

create or replace function public.set_my_email_prefs(p_prefs jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_prefs jsonb;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  insert into user_contacts (user_id) values (v_uid) on conflict (user_id) do nothing;
  update user_contacts
     set prefs = prefs || sanitize_email_prefs(p_prefs), updated_at = now()
   where user_id = v_uid
  returning prefs into v_prefs;
  return v_prefs;
end;
$$;

create or replace function public.delete_my_email()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  insert into user_contacts (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  update user_contacts
     set email = null, verified_at = null, email_deleted_at = now(),
         prefs = prefs || '{"replies": false, "waitlist": false, "digest": false, "updates": false}',
         updated_at = now()
   where user_id = auth.uid();
end;
$$;

-- Saved school bell (saved schools = followed schools for the digest).
alter table public.saved_schools add column if not exists notify boolean not null default true;

create or replace function public.set_school_notify(p_university text, p_notify boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update saved_schools set notify = coalesce(p_notify, true)
   where user_id = auth.uid() and university = p_university;
$$;

-- ---------------------------------------------------------------------------
-- Unsubscribe page (no login: the unsub_token in the email link is the key)
-- ---------------------------------------------------------------------------

create or replace function public.email_prefs_by_token(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'email',    mask_email(email),
           'verified', verified_at is not null,
           'prefs',    prefs)
    from user_contacts
   where unsub_token = p_token and char_length(coalesce(p_token, '')) >= 32;
$$;

create or replace function public.set_email_prefs_by_token(p_token text, p_prefs jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefs jsonb;
begin
  if char_length(coalesce(p_token, '')) < 32 then raise exception 'Invalid link.'; end if;
  update user_contacts
     set prefs = prefs || sanitize_email_prefs(p_prefs), updated_at = now()
   where unsub_token = p_token
  returning prefs into v_prefs;
  if v_prefs is null then raise exception 'This link is no longer valid.'; end if;
  return v_prefs;
end;
$$;

create or replace function public.delete_email_by_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if char_length(coalesce(p_token, '')) < 32 then return false; end if;
  update user_contacts
     set email = null, verified_at = null, email_deleted_at = now(),
         prefs = prefs || '{"replies": false, "waitlist": false, "digest": false, "updates": false}',
         updated_at = now()
   where unsub_token = p_token;
  return found;
end;
$$;

-- One-click unsubscribe (List-Unsubscribe-Post). Called by the unsubscribe
-- Edge Function. Turns off every category that can be turned off.
create or replace function public.unsubscribe_all_by_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if char_length(coalesce(p_token, '')) < 32 then return false; end if;
  update user_contacts
     set prefs = prefs || '{"replies": false, "waitlist": false, "digest": false, "updates": false}',
         updated_at = now()
   where unsub_token = p_token;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sender API (service_role only: used by the email-sender Edge Function)
-- ---------------------------------------------------------------------------

-- Locks up to p_limit due rows. Rows the person shouldn't get are marked
-- skipped right here, so the decision lives in one place. Returns only
-- rows that should be sent, with the address and unsubscribe token.
create or replace function public.claim_email_batch(p_limit int default 50)
returns table (
  id bigint, user_id uuid, kind text, payload jsonb, attempts int,
  email text, unsub_token text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  with due as (
    select o.id
      from email_outbox o
     where o.sent_at is null
       and o.skipped_reason is null
       and o.send_after <= now()
       and (o.claimed_at is null or o.claimed_at < now() - interval '10 minutes')
     order by o.send_after, o.id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  ),
  judged as (
    select o.id,
           case
             when c.user_id is null or c.email is null then 'no_email'
             when o.kind = 'verify' and (o.payload ->> 'email') is distinct from c.email then 'email_changed'
             when o.kind <> 'verify' and c.verified_at is null then 'unverified'
             when o.kind <> 'verify' and (c.prefs -> email_pref_key(o.kind)) = 'false'::jsonb then 'pref_off'
             when o.kind = 'waitlist'
                  and coalesce(c.prefs -> 'waitlist_off', '[]'::jsonb) ? (o.payload ->> 'school') then 'school_muted'
           end as skip
      from email_outbox o
      join due on due.id = o.id
      left join user_contacts c on c.user_id = o.user_id
  ),
  skipped as (
    update email_outbox o
       set skipped_reason = j.skip,
           payload = o.payload - 'token'
      from judged j
     where j.id = o.id and j.skip is not null
  )
  update email_outbox o
     set claimed_at = now()
    from judged j
   where j.id = o.id and j.skip is null;

  return query
    select o.id, o.user_id, o.kind, o.payload, o.attempts, c.email, c.unsub_token
      from email_outbox o
      join user_contacts c on c.user_id = o.user_id
     where o.claimed_at = now()  -- claimed by this call (now() is fixed per transaction)
       and o.sent_at is null
       and o.skipped_reason is null
     order by o.id;
end;
$$;

create or replace function public.finish_email(p_id bigint, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_ok then
    update email_outbox
       set sent_at = now(), claimed_at = null, last_error = null, payload = payload - 'token'
     where id = p_id;
  else
    update email_outbox
       set attempts = attempts + 1,
           last_error = left(p_error, 1000),
           claimed_at = null,
           send_after = now() + make_interval(mins => power(2, least(attempts + 1, 8))::int),
           skipped_reason = case when attempts + 1 >= 5 then 'failed' end,
           payload = case when attempts + 1 >= 5 then payload - 'token' else payload end
     where id = p_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- New-results digest (run daily by pg_cron, see sql/email_cron.sql)
-- ---------------------------------------------------------------------------

create or replace function public.in_admission_season(p_day date default current_date)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select coalesce((select value ->> 'start' from app_settings where key = 'digest_season'), '12-15') as a,
           coalesce((select value ->> 'end'   from app_settings where key = 'digest_season'), '04-30') as b
  )
  select case when a <= b then to_char(p_day, 'MM-DD') between a and b
              else to_char(p_day, 'MM-DD') >= a or to_char(p_day, 'MM-DD') <= b end
    from s;
$$;

-- Queues a digest for everyone who is due (monthly, or every two weeks in
-- admission season) AND has at least min_results new results at their saved
-- schools with the bell on. Anyone under the minimum is skipped and their
-- results carry over to the next run, so an empty digest is never sent.
-- Returns how many digests were queued.
create or replace function public.queue_digests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg      jsonb := coalesce((select value from app_settings where key = 'digest_interval'), '{}');
  v_days     int;
  v_min      int := coalesce((v_cfg ->> 'min_results')::int, 3);
  v_queued   int := 0;
  r          record;
begin
  v_days := case when in_admission_season()
                 then coalesce((v_cfg ->> 'season_days')::int, 14)
                 else coalesce((v_cfg ->> 'off_season_days')::int, 30) end;

  for r in
    select c.user_id,
           coalesce(c.last_digest_at, c.verified_at) as since
      from user_contacts c
     where c.email is not null
       and c.verified_at is not null
       and coalesce(c.prefs -> 'digest', 'true'::jsonb) <> 'false'::jsonb
       and coalesce(c.last_digest_at, c.verified_at) <= now() - make_interval(days => v_days)
  loop
    with counts as (
      select p.university as name, count(*)::int as n
        from saved_schools s
        join profiles p on p.university = s.university
       where s.user_id = r.user_id
         and s.notify
         and p.created_at > r.since
         and p.owner_id is distinct from r.user_id
       group by p.university
    )
    insert into email_outbox (user_id, kind, payload, dedupe_key)
    select r.user_id, 'digest',
           jsonb_build_object(
             'since', r.since,
             'total', sum(n),
             'schools', jsonb_agg(jsonb_build_object('name', name, 'count', n) order by n desc, name)),
           'digest:' || r.user_id || ':' || to_char(now(), 'YYYY-MM-DD')
      from counts
    having coalesce(sum(n), 0) >= v_min
    on conflict (dedupe_key) do nothing;

    if found then
      update user_contacts set last_digest_at = now() where user_id = r.user_id;
      v_queued := v_queued + 1;
    end if;
  end loop;

  return v_queued;
end;
$$;

-- Site update to everyone with "Site updates" on. Run from the SQL Editor:
--   select public.queue_site_update('2026-11-launch', 'Subject', 'Plain text body');
-- p_slug makes it safe to run twice (each person gets it once).
create or replace function public.queue_site_update(p_slug text, p_subject text, p_body text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if current_user in ('anon', 'authenticated') and not public.is_admin() then
    raise exception 'Admins only.';
  end if;
  insert into email_outbox (user_id, kind, payload, dedupe_key)
  select c.user_id, 'update',
         jsonb_build_object('subject', p_subject, 'body', p_body),
         'update:' || p_slug || ':' || c.user_id
    from user_contacts c
   where c.email is not null and c.verified_at is not null
     and coalesce(c.prefs -> 'updates', 'true'::jsonb) <> 'false'::jsonb
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Claiming guest submissions after sign-up
-- ---------------------------------------------------------------------------
-- Guests submit under a Supabase anonymous session. Signing in with Google
-- or a magic link creates a different user, so before that the browser asks
-- for a claim token (while still the guest) and keeps it in localStorage.
-- After sign-in it calls claim_anonymous_account(token) and the guest's
-- submissions, contact email and queued emails move to the real account.

create table if not exists public.account_claims (
  token_hash   bytea primary key,
  anon_user_id uuid not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '60 days',
  claimed_by   uuid,
  claimed_at   timestamptz
);
alter table public.account_claims enable row level security;
revoke all on public.account_claims from anon, authenticated;
create index if not exists account_claims_claimed_by_idx on public.account_claims (claimed_by);

create or replace function public.create_claim_token()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text;
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false then
    return null; -- only guests have anything to claim
  end if;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into account_claims (token_hash, anon_user_id) values (digest(v_token, 'sha256'), auth.uid());
  return v_token;
end;
$$;

create or replace function public.claim_anonymous_account(p_token text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_claim account_claims;
  v_moved int := 0;
begin
  if v_uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return 0;
  end if;

  select * into v_claim from account_claims
   where token_hash = digest(coalesce(p_token, ''), 'sha256')
   for update;
  if not found or v_claim.expires_at < now() or v_claim.anon_user_id = v_uid then
    return 0;
  end if;
  if v_claim.claimed_by is not null then
    return 0;
  end if;
  -- Only ever take over a guest account, never a real one.
  if not exists (select 1 from auth.users u where u.id = v_claim.anon_user_id and u.is_anonymous) then
    return 0;
  end if;

  update profiles set owner_id = v_uid where owner_id = v_claim.anon_user_id;
  get diagnostics v_moved = row_count;

  -- Keep the account's own contact if it has one, otherwise take the guest's.
  if exists (select 1 from user_contacts where user_id = v_uid) then
    delete from user_contacts where user_id = v_claim.anon_user_id;
  else
    update user_contacts set user_id = v_uid where user_id = v_claim.anon_user_id;
  end if;
  update email_outbox set user_id = v_uid
   where user_id = v_claim.anon_user_id and sent_at is null;

  update account_claims set claimed_by = v_uid, claimed_at = now()
   where token_hash = v_claim.token_hash;
  return v_moved;
end;
$$;

-- Verification files live in "<uploader id>/..." folders. After a claim the
-- uploader was the guest id, so also accept folders of guests this account
-- has claimed (otherwise editing a claimed result would drop its Verified
-- badge). Same behaviour as sql/profile_guards.sql otherwise.
create or replace function public.verification_file_exists(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_path is not null
     and auth.uid() is not null
     and (split_part(p_path, '/', 1) = auth.uid()::text
          or exists (select 1 from account_claims ac
                      where ac.claimed_by = auth.uid()
                        and ac.anon_user_id::text = split_part(p_path, '/', 1)))
     and exists (
       select 1 from storage.objects o
        where o.bucket_id = 'verification-docs' and o.name = p_path
     );
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function public.sanitize_email_prefs(jsonb)           from public, anon, authenticated;
revoke execute on function public.mask_email(text)                      from public, anon, authenticated;
revoke execute on function public.email_pref_key(text)                  from public, anon, authenticated;
revoke execute on function public.in_admission_season(date)             from public, anon, authenticated;

revoke execute on function public.sync_my_auth_email()                  from public, anon;
revoke execute on function public.set_my_email(text)                    from public, anon;
revoke execute on function public.set_my_email_prefs(jsonb)             from public, anon;
revoke execute on function public.delete_my_email()                     from public, anon;
revoke execute on function public.set_school_notify(text, boolean)      from public, anon;
revoke execute on function public.create_claim_token()                  from public, anon;
revoke execute on function public.claim_anonymous_account(text)         from public, anon;
grant  execute on function public.sync_my_auth_email()                  to authenticated;
grant  execute on function public.set_my_email(text)                    to authenticated;
grant  execute on function public.set_my_email_prefs(jsonb)             to authenticated;
grant  execute on function public.delete_my_email()                     to authenticated;
grant  execute on function public.set_school_notify(text, boolean)      to authenticated;
grant  execute on function public.create_claim_token()                  to authenticated;
grant  execute on function public.claim_anonymous_account(text)         to authenticated;

-- Token-based: work from an email link without signing in.
grant execute on function public.verify_email(text)                     to anon, authenticated;
grant execute on function public.email_prefs_by_token(text)             to anon, authenticated;
grant execute on function public.set_email_prefs_by_token(text, jsonb)  to anon, authenticated;
grant execute on function public.delete_email_by_token(text)            to anon, authenticated;

-- Server only.
revoke execute on function public.unsubscribe_all_by_token(text)        from public, anon, authenticated;
revoke execute on function public.claim_email_batch(int)                from public, anon, authenticated;
revoke execute on function public.finish_email(bigint, boolean, text)   from public, anon, authenticated;
revoke execute on function public.queue_digests()                       from public, anon, authenticated;
revoke execute on function public.queue_site_update(text, text, text)   from public, anon, authenticated;
grant  execute on function public.unsubscribe_all_by_token(text)        to service_role;
grant  execute on function public.claim_email_batch(int)                to service_role;
grant  execute on function public.finish_email(bigint, boolean, text)   to service_role;
grant  execute on function public.queue_digests()                       to service_role;

-- ---------------------------------------------------------------------------
-- Checks (run these after installing)
-- ---------------------------------------------------------------------------
-- 1. With the anon key, these must return an error or nothing:
--      curl "$SUPABASE_URL/rest/v1/user_contacts?select=*" -H "apikey: $ANON_KEY"
--      curl "$SUPABASE_URL/rest/v1/email_outbox?select=*"  -H "apikey: $ANON_KEY"
-- 2. In the SQL Editor, as anon:
--      set local role anon; select * from public.user_contacts;   -- permission denied
