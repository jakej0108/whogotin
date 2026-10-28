-- progress_ecs_text: free-text extracurriculars for progress snapshots.
--
-- Progress snapshots now take extracurriculars as one text box, the same as
-- the "Share your result" form. Older snapshots keep their structured `ecs`
-- entries (never modified or deleted); the box is prefilled from them.
--
-- Install: paste this whole file into Supabase -> SQL Editor -> Run.
-- Safe to run again.

alter table public.progress_snapshots add column if not exists ecs_text text;

alter table public.progress_snapshots drop constraint if exists progress_ecs_text_length;
alter table public.progress_snapshots add constraint progress_ecs_text_length
  check (ecs_text is null or char_length(ecs_text) <= 5000);
