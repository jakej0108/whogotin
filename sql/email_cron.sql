-- email_cron: runs the email sender every minute and queues digests daily.
--
-- Before running this file:
--   1. Run sql/email_backbone.sql and sql/comments.sql.
--   2. Deploy the Edge Functions (see supabase/functions/README.md) and set
--      the function secret CRON_SECRET to a long random string.
--   3. Store the same string in Vault (SQL Editor, run once; never commit it):
--        select vault.create_secret('<the CRON_SECRET value>', 'email_cron_secret');
--   4. Database -> Extensions: turn on pg_cron and pg_net (or let the two
--      lines below do it).
--
-- Then paste this whole file into SQL Editor -> Run. Safe to run again
-- (cron.schedule with an existing job name replaces it).

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Every minute: POST to the email-sender function. It sends whatever is due
-- in email_outbox and exits.
select cron.schedule(
  'email-sender',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://nczvyfkfppndhovlevxm.supabase.co/functions/v1/email-sender',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                                    where name = 'email_cron_secret' limit 1)),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);

-- Daily at 15:23 UTC (morning in the US): queue new-results digests for
-- everyone who is due. queue_digests() decides monthly vs every two weeks
-- from app_settings, and skips anyone with fewer than 3 new results.
select cron.schedule('email-digests', '23 15 * * *', $$ select public.queue_digests(); $$);

-- Housekeeping, weekly: drop sent/skipped outbox rows older than 90 days and
-- used or expired verification tokens.
select cron.schedule(
  'email-cleanup',
  '41 4 * * 0',
  $$
  delete from public.email_outbox
   where (sent_at is not null or skipped_reason is not null) and created_at < now() - interval '90 days';
  delete from public.email_verifications
   where used_at is not null or expires_at < now() - interval '7 days';
  $$
);

-- To check on it:
--   select jobname, schedule, active from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 20;
--   select id, kind, skipped_reason, last_error, sent_at from public.email_outbox order by id desc limit 50;
