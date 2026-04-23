-- Fix: convert the partial unique index on notification_jobs.dedupe_key to a
-- full unique constraint so that ON CONFLICT (dedupe_key) DO NOTHING works
-- without requiring the partial-index predicate.  PostgreSQL treats NULL as
-- not-equal-to-NULL in unique constraints, so multiple NULL dedupe_key rows
-- remain valid — behaviour is semantically identical to the old partial index.

DROP INDEX IF EXISTS public.uq_notification_jobs_dedupe_key;

ALTER TABLE public.notification_jobs
  ADD CONSTRAINT uq_notification_jobs_dedupe_key UNIQUE (dedupe_key);
