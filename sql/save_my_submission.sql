-- save_my_submission: create or edit a signed-in account's submission in a
-- single transaction, updating existing rows in place.
--
-- Why: the old edit path deleted all of the account's profile rows and then
-- inserted new ones. Every table that references profiles(id) uses
-- ON DELETE CASCADE, so each edit also wiped likes, saves, reports and view
-- counts, and gave the submission a new submission_id (breaking its share
-- link). If the insert failed after the delete, the submission was lost.
--
-- What it does, all-or-nothing:
--   * keeps the account's newest submission_id (so share links keep working)
--   * for each school: updates the existing row for that university if there
--     is one (same id -> likes/saves/reports/views are kept), else inserts one
--   * deletes only rows for schools that were removed from the submission
--
-- Runs as the calling user (security invoker), so the existing RLS policies
-- on profiles still decide what they may insert/update/delete.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again; it replaces the previous version of the function.

create or replace function public.save_my_submission(p_shared jsonb, p_schools jsonb)
returns setof public.profiles
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_sub    uuid;
  v_short  text;
  v_school jsonb;
  v_row    public.profiles;
  v_id     uuid;
  v_keep   uuid[] := '{}';
  v_seen   text[] := '{}';
begin
  if v_uid is null then
    raise exception 'You need to be signed in to save a submission.';
  end if;
  if p_schools is null or jsonb_typeof(p_schools) <> 'array' or jsonb_array_length(p_schools) = 0 then
    raise exception 'Add at least one school before submitting.';
  end if;

  -- Reuse the account's newest submission id so existing share links keep working.
  select submission_id into v_sub
    from profiles
   where owner_id = v_uid and submission_id is not null
   order by created_at desc
   limit 1;
  if v_sub is null then
    v_sub := gen_random_uuid();
  end if;
  v_short := lower(split_part(v_sub::text, '-', 1));

  for v_school in select value from jsonb_array_elements(p_schools) loop
    -- Shared fields + this school's fields, cast to the table's column types.
    v_row := jsonb_populate_record(null::public.profiles, coalesce(p_shared, '{}'::jsonb) || v_school);

    if v_row.university is null or v_row.university = '' then
      raise exception 'Every school needs a university name.';
    end if;
    if v_row.university = any(v_seen) then
      raise exception '% is listed more than once. Keep it under one decision only.', v_row.university;
    end if;
    v_seen := v_seen || v_row.university;

    -- Existing row for this school (newest one if older duplicates exist).
    v_id := null;
    select id into v_id
      from profiles
     where owner_id = v_uid
       and university = v_row.university
       and id <> all (v_keep)
     order by created_at desc
     limit 1;

    if v_id is null then
      insert into profiles (
        owner_id, submission_id, university, status, decision_type, major,
        transfer, transfer_from, class_year, gpa, weighted_gpa, sat, act, high_school, essay,
        verified, verification_path, ecs, ap_exams, awards
      ) values (
        v_uid, v_sub, v_row.university, v_row.status,
        coalesce(nullif(v_row.decision_type, ''), 'Regular'), v_row.major,
        coalesce(v_row.transfer, false), v_row.transfer_from, v_row.class_year, v_row.gpa,
        v_row.weighted_gpa, v_row.sat, v_row.act, v_row.high_school, v_row.essay,
        coalesce(v_row.verified, false), v_row.verification_path,
        coalesce(v_row.ecs, '[]'::jsonb), coalesce(v_row.ap_exams, '[]'::jsonb),
        coalesce(v_row.awards, '[]'::jsonb)
      )
      returning id into v_id;
    else
      update profiles set
        submission_id     = v_sub,
        status            = v_row.status,
        decision_type     = coalesce(nullif(v_row.decision_type, ''), 'Regular'),
        major             = v_row.major,
        transfer          = coalesce(v_row.transfer, false),
        transfer_from     = v_row.transfer_from,
        class_year        = v_row.class_year,
        gpa               = v_row.gpa,
        weighted_gpa      = v_row.weighted_gpa,
        sat               = v_row.sat,
        act               = v_row.act,
        high_school       = v_row.high_school,
        essay             = v_row.essay,
        verified          = coalesce(v_row.verified, false),
        verification_path = v_row.verification_path,
        ecs               = coalesce(v_row.ecs, '[]'::jsonb),
        ap_exams          = coalesce(v_row.ap_exams, '[]'::jsonb),
        awards            = coalesce(v_row.awards, '[]'::jsonb)
      where id = v_id;
    end if;

    v_keep := v_keep || v_id;
  end loop;

  -- share_short_id is normally a generated column (computed from
  -- submission_id), which must not be written to. Only set it by hand if
  -- this database has it as a plain column.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'share_short_id' and is_generated = 'NEVER'
  ) then
    update profiles set share_short_id = v_short
     where id = any (v_keep) and share_short_id is distinct from v_short;
  end if;

  -- Remove only the schools that are no longer part of this submission.
  delete from profiles where owner_id = v_uid and id <> all (v_keep);

  return query
    select * from profiles where id = any (v_keep) order by created_at;
end;
$$;

-- Only signed-in sessions (including Supabase anonymous sessions) can call it.
revoke execute on function public.save_my_submission(jsonb, jsonb) from public, anon;
grant execute on function public.save_my_submission(jsonb, jsonb) to authenticated;
