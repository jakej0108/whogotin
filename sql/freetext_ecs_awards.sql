-- freetext_ecs_awards: add free-text columns for extracurriculars and
-- honors & awards.
--
-- The submission form now takes ECs and awards as one free-text box each.
-- Older submissions keep their structured `ecs` / `awards` JSON arrays,
-- which are never modified or deleted; profiles show the free text when a
-- submission has it (ecs_text is not null) and the old entries otherwise.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run,
-- then run the updated sql/save_my_submission.sql. Safe to run again.

alter table public.profiles add column if not exists ecs_text text;
alter table public.profiles add column if not exists awards_text text;

alter table public.profiles drop constraint if exists profiles_ecs_text_length;
alter table public.profiles add constraint profiles_ecs_text_length
  check (ecs_text is null or char_length(ecs_text) <= 5000);

alter table public.profiles drop constraint if exists profiles_awards_text_length;
alter table public.profiles add constraint profiles_awards_text_length
  check (awards_text is null or char_length(awards_text) <= 5000);
