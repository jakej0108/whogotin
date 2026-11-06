-- comments: threaded comments on submissions (and, later, discussion posts),
-- with anonymous up/down votes, reports, auto-hide, rate limits and reply
-- emails.
--
-- Requires sql/email_backbone.sql (reply emails go into email_outbox).
--
-- Privacy: nobody can read the comments, comment_votes, content_reports or
-- user_handles tables directly with the API. Everything goes through the
-- functions below. get_comments() returns the author's handle and an
-- is_op flag, never anyone's user id.
--
-- parent_type 'submission': parent_id is profiles.submission_id (or, for
-- old rows saved before submission_id existed, that row's profiles.id).
-- parent_type 'post' is allowed by the table but rejected until the posts
-- table exists (sql for Discussions). comment_parent_exists() and
-- comment_parent_owner() are the only places that need to learn about it.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again.

-- ---------------------------------------------------------------------------
-- Handles (public names shown on comments)
-- ---------------------------------------------------------------------------

create table if not exists public.user_handles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  handle     text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_handles_format check (handle ~ '^[a-z0-9_]{3,20}$')
);
create unique index if not exists user_handles_handle_key on public.user_handles (lower(handle));
alter table public.user_handles enable row level security;
revoke all on public.user_handles from anon, authenticated;

-- Random handle like "quiet_otter_482" for people who haven't picked one.
create or replace function public.ensure_my_handle()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_handle text;
  v_adj    text[] := array['quiet','brave','sunny','lucky','calm','swift','bright','bold','keen','merry',
                             'witty','gentle','clever','eager','jolly','mellow','nimble','plucky','steady','zesty'];
  v_noun   text[] := array['otter','falcon','maple','comet','panda','heron','cedar','lynx','koala','robin',
                             'badger','finch','willow','orca','tiger','sparrow','bison','aspen','gecko','moose'];
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  select handle into v_handle from user_handles where user_id = v_uid;
  if v_handle is not null then return v_handle; end if;
  for i in 1..20 loop
    v_handle := v_adj[1 + floor(random() * array_length(v_adj, 1))::int] || '_' ||
                v_noun[1 + floor(random() * array_length(v_noun, 1))::int] || '_' ||
                (100 + floor(random() * 900))::int;
    begin
      insert into user_handles (user_id, handle) values (v_uid, v_handle);
      return v_handle;
    exception when unique_violation then
      -- taken (or a parallel call already created ours): try again
      select handle into v_handle from user_handles where user_id = v_uid;
      if v_handle is not null then return v_handle; end if;
    end;
  end loop;
  raise exception 'Could not pick a username. Try again.';
end;
$$;

create or replace function public.set_my_handle(p_handle text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text := lower(btrim(coalesce(p_handle, '')));
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Create an account first.';
  end if;
  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Usernames are 3-20 characters: letters, numbers and _.';
  end if;
  if v_handle in ('admin', 'team', 'whogotin', 'moderator', 'mod', 'deleted', 'removed', 'op') then
    raise exception 'That username is reserved.';
  end if;
  begin
    insert into user_handles (user_id, handle) values (auth.uid(), v_handle)
    on conflict (user_id) do update set handle = excluded.handle, updated_at = now();
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  return v_handle;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.comments (
  id                  uuid primary key default gen_random_uuid(),
  parent_type         text not null check (parent_type in ('submission', 'post')),
  parent_id           uuid not null,
  reply_to_comment_id uuid references public.comments(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  body                text not null check (char_length(btrim(body)) between 1 and 4000),
  -- Random id made by the browser per draft. Posting the same draft twice
  -- (double click, two tabs resuming after a magic-link sign-in) is a no-op.
  client_id           uuid,
  created_at          timestamptz not null default now(),
  edited_at           timestamptz,
  deleted_at          timestamptz,
  hidden              boolean not null default false,
  reviewed_at         timestamptz,
  unique (user_id, client_id)
);
create index if not exists comments_parent_idx   on public.comments (parent_type, parent_id, created_at);
create index if not exists comments_reply_to_idx on public.comments (reply_to_comment_id);
create index if not exists comments_user_idx     on public.comments (user_id, created_at);
alter table public.comments enable row level security;
revoke all on public.comments from anon, authenticated;

create table if not exists public.comment_votes (
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  value      smallint not null check (value in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comment_votes enable row level security;
revoke all on public.comment_votes from anon, authenticated;

-- Reports on comments (and later posts). Separate from public.reports,
-- which is tied to profiles(id).
create table if not exists public.content_reports (
  id          uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('comment', 'post')),
  target_id   uuid not null,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason      text check (reason is null or char_length(reason) <= 500),
  status      text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at  timestamptz not null default now(),
  unique (target_type, target_id, reporter_id)
);
create index if not exists content_reports_target_idx on public.content_reports (target_type, target_id) where status = 'open';
alter table public.content_reports enable row level security;
revoke all on public.content_reports from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Parent helpers (polymorphic parent, so no foreign key)
-- ---------------------------------------------------------------------------

create or replace function public.comment_parent_exists(p_type text, p_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  if p_type = 'submission' then
    return exists (select 1 from profiles
                    where submission_id = p_id or (submission_id is null and id = p_id));
  elsif p_type = 'post' then
    if to_regclass('public.posts') is null then return false; end if;
    execute 'select exists (select 1 from public.posts where id = $1 and deleted_at is null and not hidden)'
       into v_ok using p_id;
    return v_ok;
  end if;
  return false;
end;
$$;

create or replace function public.comment_parent_owner(p_type text, p_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  if p_type = 'submission' then
    select owner_id into v_owner from profiles
     where submission_id = p_id or (submission_id is null and id = p_id)
     order by created_at limit 1;
  elsif p_type = 'post' and to_regclass('public.posts') is not null then
    execute 'select user_id from public.posts where id = $1' into v_owner using p_id;
  end if;
  return v_owner;
end;
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Checks the parent, the reply target and the rate limit on every insert.
create or replace function public.comments_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reply comments;
begin
  if not comment_parent_exists(new.parent_type, new.parent_id) then
    raise exception 'That result or post no longer exists.';
  end if;

  if new.reply_to_comment_id is not null then
    select * into v_reply from comments where id = new.reply_to_comment_id;
    if not found or v_reply.parent_type <> new.parent_type or v_reply.parent_id <> new.parent_id then
      raise exception 'The comment you''re replying to no longer exists.';
    end if;
  end if;

  if (select count(*) from comments
       where user_id = new.user_id and created_at > now() - interval '1 minute') >= 5 then
    raise exception 'You''re commenting too fast. Wait a minute and try again.';
  end if;
  if (select count(*) from comments
       where user_id = new.user_id and created_at > now() - interval '24 hours') >= 50 then
    raise exception 'You''ve reached today''s comment limit. Try again tomorrow.';
  end if;

  new.body := btrim(new.body);
  new.created_at := now();
  new.edited_at := null;
  new.deleted_at := null;
  new.hidden := false;
  return new;
end;
$$;

drop trigger if exists comments_before_insert on public.comments;
create trigger comments_before_insert
  before insert on public.comments
  for each row execute function public.comments_before_insert();

-- Queues a reply email: to the result/post owner for a top-level comment,
-- or to the author of the comment being replied to. Never to yourself.
-- At most one email per recipient per parent per hour.
create or replace function public.comments_queue_reply_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to uuid;
begin
  if new.reply_to_comment_id is null then
    v_to := comment_parent_owner(new.parent_type, new.parent_id);
  else
    select user_id into v_to from comments
     where id = new.reply_to_comment_id and deleted_at is null;
  end if;
  if v_to is null or v_to = new.user_id then return null; end if;

  insert into email_outbox (user_id, kind, payload, dedupe_key)
  values (
    v_to, 'reply',
    jsonb_build_object(
      'parent_type', new.parent_type,
      'parent_id',   new.parent_id,
      'short_id',    lower(split_part(new.parent_id::text, '-', 1)),
      'is_reply',    new.reply_to_comment_id is not null,
      'handle',      (select handle from user_handles where user_id = new.user_id),
      'excerpt',     left(new.body, 280)
    ),
    'reply:' || v_to || ':' || new.parent_id || ':' ||
      to_char(date_trunc('hour', now() at time zone 'utc'), 'YYYYMMDDHH24')
  )
  on conflict (dedupe_key) do nothing;
  return null;
end;
$$;

drop trigger if exists comments_queue_reply_email on public.comments;
create trigger comments_queue_reply_email
  after insert on public.comments
  for each row execute function public.comments_queue_reply_email();

-- 3 open reports -> hidden until an admin reviews it.
create or replace function public.content_reports_autohide()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from content_reports
       where target_type = new.target_type and target_id = new.target_id and status = 'open') >= 3 then
    if new.target_type = 'comment' then
      update comments set hidden = true where id = new.target_id and not hidden;
    elsif new.target_type = 'post' and to_regclass('public.posts') is not null then
      execute 'update public.posts set hidden = true where id = $1 and not hidden' using new.target_id;
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists content_reports_autohide on public.content_reports;
create trigger content_reports_autohide
  after insert on public.content_reports
  for each row execute function public.content_reports_autohide();

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- Every comment on one parent, flat; the browser builds the tree.
-- Deleted comments and hidden ones (for non-admins) come back as
-- placeholders with no body or handle, so their replies still have a place
-- in the tree. status: 'ok' | 'deleted' | 'removed'.
-- is_hidden and report_count are only filled in for admins.
drop function if exists public.get_comments(text, uuid);
create or replace function public.get_comments(p_parent_type text, p_parent_id uuid)
returns table (
  id                  uuid,
  reply_to_comment_id uuid,
  handle              text,
  body                text,
  created_at          timestamptz,
  edited_at           timestamptz,
  status              text,
  is_op               boolean,
  is_mine             boolean,
  score               int,
  my_vote             smallint,
  is_hidden           boolean,
  report_count        int
)
language sql
stable
security definer
set search_path = public
as $$
  with owner as (select comment_parent_owner(p_parent_type, p_parent_id) as uid),
       me    as (select auth.uid() as uid, public.is_admin() as admin)
  select c.id,
         c.reply_to_comment_id,
         case when c.deleted_at is null and (not c.hidden or me.admin) then h.handle end,
         case when c.deleted_at is null and (not c.hidden or me.admin) then c.body end,
         c.created_at,
         c.edited_at,
         case when c.deleted_at is not null then 'deleted'
              when c.hidden and not me.admin then 'removed'
              else 'ok' end,
         c.deleted_at is null and (not c.hidden or me.admin) and c.user_id = owner.uid,
         me.uid is not null and c.user_id = me.uid and c.deleted_at is null,
         coalesce((select sum(v.value)::int from comment_votes v where v.comment_id = c.id), 0),
         (select v.value from comment_votes v where v.comment_id = c.id and v.user_id = me.uid),
         case when me.admin then c.hidden end,
         case when me.admin then
           (select count(*)::int from content_reports r
             where r.target_type = 'comment' and r.target_id = c.id and r.status = 'open')
         end
    from comments c
    cross join owner
    cross join me
    left join user_handles h on h.user_id = c.user_id
   where c.parent_type = p_parent_type
     and c.parent_id = p_parent_id
   order by c.created_at;
$$;

-- Comment counts for several parents at once (cards, feeds).
create or replace function public.get_comment_counts(p_parent_type text, p_parent_ids uuid[])
returns table (parent_id uuid, n int)
language sql
stable
security definer
set search_path = public
as $$
  select c.parent_id, count(*)::int
    from comments c
   where c.parent_type = p_parent_type
     and c.parent_id = any (p_parent_ids[1:200])
     and c.deleted_at is null and not c.hidden
   group by c.parent_id;
$$;

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

create or replace function public.require_real_account()
returns uuid
language plpgsql
stable
as $$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Create a free account to do that.';
  end if;
  return auth.uid();
end;
$$;

create or replace function public.post_comment(
  p_parent_type text,
  p_parent_id   uuid,
  p_body        text,
  p_reply_to    uuid default null,
  p_client_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := require_real_account();
  v_id  uuid;
begin
  if p_client_id is not null then
    select id into v_id from comments where user_id = v_uid and client_id = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  perform ensure_my_handle();

  insert into comments (parent_type, parent_id, reply_to_comment_id, user_id, body, client_id)
  values (p_parent_type, p_parent_id, p_reply_to, v_uid, coalesce(p_body, ''), p_client_id)
  on conflict (user_id, client_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from comments where user_id = v_uid and client_id = p_client_id;
  end if;
  return v_id;
end;
$$;

-- Edits are allowed for 10 minutes after posting; edited comments show
-- "(edited)".
create or replace function public.edit_comment(p_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := require_real_account();
  v_c   comments;
begin
  select * into v_c from comments where id = p_id for update;
  if not found or v_c.user_id <> v_uid or v_c.deleted_at is not null then
    raise exception 'You can only edit your own comments.';
  end if;
  if v_c.created_at < now() - interval '10 minutes' then
    raise exception 'Comments can only be edited for 10 minutes after posting.';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 4000 then
    raise exception 'Comments need 1-4000 characters.';
  end if;
  if btrim(p_body) = v_c.body then return; end if;
  update comments set body = btrim(p_body), edited_at = now() where id = p_id;
end;
$$;

-- Own comment (or admin). With replies: kept as "[deleted]" so the thread
-- still makes sense. Without: removed, and any "[deleted]" ancestors that
-- are now empty are removed too.
create or replace function public.delete_comment(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := require_real_account();
  v_c      comments;
  v_parent uuid;
begin
  select * into v_c from comments where id = p_id for update;
  if not found or v_c.deleted_at is not null then return; end if;
  if v_c.user_id <> v_uid and not public.is_admin() then
    raise exception 'You can only delete your own comments.';
  end if;

  if exists (select 1 from comments where reply_to_comment_id = p_id) then
    update comments set deleted_at = now(), body = '[deleted]' where id = p_id;
    delete from comment_votes where comment_id = p_id;
    return;
  end if;

  v_parent := v_c.reply_to_comment_id;
  delete from comments where id = p_id;
  while v_parent is not null loop
    select * into v_c from comments where id = v_parent;
    exit when not found or v_c.deleted_at is null
           or exists (select 1 from comments where reply_to_comment_id = v_parent);
    delete from comments where id = v_parent;
    v_parent := v_c.reply_to_comment_id;
  end loop;
end;
$$;

-- p_value: 1, -1, or 0 to remove. Returns the new score.
create or replace function public.vote_comment(p_id uuid, p_value int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := require_real_account();
  v_c   comments;
begin
  if p_value not in (-1, 0, 1) then raise exception 'Invalid vote.'; end if;
  select * into v_c from comments where id = p_id;
  if not found or v_c.deleted_at is not null or v_c.hidden then
    raise exception 'That comment is no longer available.';
  end if;
  if v_c.user_id = v_uid then raise exception 'You can''t vote on your own comment.'; end if;

  if p_value = 0 then
    delete from comment_votes where comment_id = p_id and user_id = v_uid;
  else
    insert into comment_votes (comment_id, user_id, value) values (p_id, v_uid, p_value)
    on conflict (comment_id, user_id) do update set value = excluded.value, created_at = now();
  end if;
  return coalesce((select sum(value)::int from comment_votes where comment_id = p_id), 0);
end;
$$;

create or replace function public.report_comment(p_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := require_real_account();
begin
  if not exists (select 1 from comments where id = p_id and deleted_at is null) then
    raise exception 'That comment is no longer available.';
  end if;
  if exists (select 1 from comments where id = p_id and user_id = v_uid) then
    raise exception 'You can''t report your own comment.';
  end if;
  insert into content_reports (target_type, target_id, reporter_id, reason)
  values ('comment', p_id, v_uid, nullif(left(btrim(coalesce(p_reason, '')), 500), ''))
  on conflict (target_type, target_id, reporter_id) do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin review
-- ---------------------------------------------------------------------------

-- Comments that are hidden and not yet reviewed, or have open reports.
create or replace function public.admin_comment_queue()
returns table (
  id           uuid,
  parent_type  text,
  parent_id    uuid,
  short_id     text,
  handle       text,
  body         text,
  created_at   timestamptz,
  hidden       boolean,
  report_count int,
  reasons      text[]
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return query
    select c.id, c.parent_type, c.parent_id, lower(split_part(c.parent_id::text, '-', 1)),
           h.handle, c.body, c.created_at, c.hidden,
           count(r.id)::int,
           array_remove(array_agg(r.reason order by r.created_at), null)
      from comments c
      left join user_handles h on h.user_id = c.user_id
      left join content_reports r
        on r.target_type = 'comment' and r.target_id = c.id and r.status = 'open'
     where c.deleted_at is null
       and ((c.hidden and c.reviewed_at is null) or r.id is not null)
     group by c.id, h.handle
     order by max(r.created_at) desc nulls last, c.created_at desc;
end;
$$;

-- 'restore': visible again, open reports dismissed (they stop counting).
-- 'remove' : stays hidden for good, open reports marked actioned.
create or replace function public.admin_moderate_comment(p_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_action = 'restore' then
    update comments set hidden = false, reviewed_at = now() where id = p_id;
    update content_reports set status = 'dismissed'
     where target_type = 'comment' and target_id = p_id and status = 'open';
  elsif p_action = 'remove' then
    update comments set hidden = true, reviewed_at = now() where id = p_id;
    update content_reports set status = 'actioned'
     where target_type = 'comment' and target_id = p_id and status = 'open';
  else
    raise exception 'Unknown action.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function public.comment_parent_exists(text, uuid)   from public, anon, authenticated;
revoke execute on function public.comment_parent_owner(text, uuid)    from public, anon, authenticated;
revoke execute on function public.require_real_account()              from public, anon, authenticated;

grant execute on function public.get_comments(text, uuid)             to anon, authenticated;
grant execute on function public.get_comment_counts(text, uuid[])     to anon, authenticated;

revoke execute on function public.ensure_my_handle()                  from public, anon;
revoke execute on function public.set_my_handle(text)                 from public, anon;
revoke execute on function public.post_comment(text, uuid, text, uuid, uuid) from public, anon;
revoke execute on function public.edit_comment(uuid, text)            from public, anon;
revoke execute on function public.delete_comment(uuid)                from public, anon;
revoke execute on function public.vote_comment(uuid, int)             from public, anon;
revoke execute on function public.report_comment(uuid, text)          from public, anon;
revoke execute on function public.admin_comment_queue()               from public, anon;
revoke execute on function public.admin_moderate_comment(uuid, text)  from public, anon;
grant  execute on function public.ensure_my_handle()                  to authenticated;
grant  execute on function public.set_my_handle(text)                 to authenticated;
grant  execute on function public.post_comment(text, uuid, text, uuid, uuid) to authenticated;
grant  execute on function public.edit_comment(uuid, text)            to authenticated;
grant  execute on function public.delete_comment(uuid)                to authenticated;
grant  execute on function public.vote_comment(uuid, int)             to authenticated;
grant  execute on function public.report_comment(uuid, text)          to authenticated;
grant  execute on function public.admin_comment_queue()               to authenticated;
grant  execute on function public.admin_moderate_comment(uuid, text)  to authenticated;

-- A user's own handle (for "Posting as ..." and the settings field).
create or replace function public.get_my_handle()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select handle from user_handles where user_id = auth.uid();
$$;
revoke execute on function public.get_my_handle() from public, anon;
grant  execute on function public.get_my_handle() to authenticated;
