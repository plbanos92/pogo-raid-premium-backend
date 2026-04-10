// Edge Function: dispatch-push-notifications
// Scheduled every minute — dispatches queued notification_jobs to browser push endpoints.
//
// Processes up to 50 pending notification_jobs per invocation.
// Uses VAPID-signed Web Push (RFC 8030 + RFC 8292) via npm:web-push.
//
// Security:
//   - Requires 'x-cron-secret' header matching DISPATCH_CRON_SECRET env var
//   - Uses service_role key for all DB access
//   - Never logs endpoint URLs, p256dh, or auth key material

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// @ts-ignore — npm: specifier is Deno-native; types not bundled
import webpush from "npm:web-push";

const BATCH_SIZE = 50;

Deno.serve(async (req: Request) => {
  // ── Auth ─────────────────────────────────────────────────────────────────
  const DISPATCH_CRON_SECRET = Deno.env.get("DISPATCH_CRON_SECRET");
  const cronHeader = req.headers.get("x-cron-secret");
  if (!DISPATCH_CRON_SECRET || cronHeader !== DISPATCH_CRON_SECRET) {
    return json({ error: "Unauthorized" }, 401);
  }

  // ── Config ────────────────────────────────────────────────────────────────
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const VAPID_PRIVATE_KEY = Deno.env.get("WEB_PUSH_VAPID_PRIVATE_KEY");
  const VAPID_PUBLIC_KEY = Deno.env.get("WEB_PUSH_VAPID_PUBLIC_KEY");
  const VAPID_SUBJECT = Deno.env.get("WEB_PUSH_SUBJECT");

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error("dispatch-push: missing Supabase env vars");
    return json({ error: "Missing Supabase config" }, 500);
  }
  if (!VAPID_PRIVATE_KEY || !VAPID_PUBLIC_KEY || !VAPID_SUBJECT) {
    console.error("dispatch-push: missing VAPID env vars");
    return json({ error: "Missing VAPID config" }, 500);
  }

  // ── Setup webpush ─────────────────────────────────────────────────────────
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

  // ── DB client ─────────────────────────────────────────────────────────────
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // ── Fetch pending jobs ────────────────────────────────────────────────────
  const { data: jobs, error: jobsError } = await supabase
    .from("notification_jobs")
    .select("id, user_id, event_type, title, body, payload, attempt_count")
    .eq("status", "pending")
    .lte("scheduled_at", new Date().toISOString())
    .order("scheduled_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (jobsError) {
    console.error("dispatch-push: fetch jobs error:", jobsError.message);
    return json({ error: jobsError.message }, 500);
  }

  const results = { dispatched: jobs?.length ?? 0, sent: 0, failed: 0, discarded: 0 };

  if (!jobs || jobs.length === 0) {
    return json(results, 200);
  }

  // ── Process each job ──────────────────────────────────────────────────────
  for (const job of jobs) {
    const shortJobId = (job.id as string).slice(0, 8);
    const shortUserId = (job.user_id as string).slice(0, 8);

    // Fetch active subscriptions for this user
    const { data: subs, error: subsError } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth")
      .eq("user_id", job.user_id)
      .is("disabled_at", null);

    if (subsError) {
      console.error(`dispatch-push: job=${shortJobId} fetch subs error:`, subsError.message);
      await markJob(supabase, job.id, "failed", job.attempt_count, subsError.message);
      results.failed++;
      continue;
    }

    if (!subs || subs.length === 0) {
      // No active subscriptions — nothing to deliver
      console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} no active subs → discard`);
      await markJob(supabase, job.id, "discarded", job.attempt_count, null);
      results.discarded++;
      continue;
    }

    // Build push payload
    const pushPayload = JSON.stringify({
      title: job.title,
      body: job.body,
      tag: `${job.event_type}-${job.id}`,
      data: job.payload ?? {},
    });

    let successCount = 0;
    let transientFailCount = 0;
    let lastTransientError: string | null = null;

    for (const sub of subs) {
      try {
        await webpush.sendNotification(
          {
            endpoint: sub.endpoint,
            keys: { p256dh: sub.p256dh, auth: sub.auth },
          },
          pushPayload,
          { TTL: 60 * 60 * 12 } // 12-hour TTL
        );
        successCount++;
      } catch (err: unknown) {
        const statusCode = (err as { statusCode?: number }).statusCode;
        if (statusCode === 410 || statusCode === 404) {
          // Permanent failure — subscription expired or gone
          console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} sub expired (${statusCode}) → disabling`);
          await supabase
            .from("push_subscriptions")
            .update({ disabled_at: new Date().toISOString() })
            .eq("id", sub.id);
          // 410/404 is permanent but not the job's fault — treat as if the
          // sub counted as a non-success (don't count as transient failure)
        } else {
          transientFailCount++;
          lastTransientError = `HTTP ${statusCode ?? "unknown"}: ${(err as Error).message ?? "send error"}`;
          console.warn(`dispatch-push: job=${shortJobId} user=${shortUserId} transient error: ${lastTransientError}`);
        }
      }
    }

    // ── Determine final job status ────────────────────────────────────────
    if (successCount > 0) {
      // At least one delivery succeeded
      await markJob(supabase, job.id, "sent", job.attempt_count, null);
      results.sent++;
      console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} sent (${successCount} delivered)`);
    } else if (transientFailCount === 0) {
      // All subs were gone (410/404) or there were no deliverable subs after filtering
      // No transient errors — consider this resolved (nothing left to send to)
      await markJob(supabase, job.id, "discarded", job.attempt_count, "all subscriptions expired");
      results.discarded++;
      console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} discarded (all subs expired)`);
    } else {
      // Transient failures only
      const newAttemptCount = job.attempt_count + 1;
      if (newAttemptCount >= 3) {
        await markJob(supabase, job.id, "discarded", newAttemptCount, lastTransientError);
        results.discarded++;
        console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} discarded after ${newAttemptCount} attempts`);
      } else {
        // Keep pending for retry
        const { error: retryError } = await supabase
          .from("notification_jobs")
          .update({
            attempt_count: newAttemptCount,
            last_error: lastTransientError,
          })
          .eq("id", job.id);
        if (retryError) {
          console.error(`dispatch-push: job=${shortJobId} retry update error:`, retryError.message);
        }
        results.failed++;
        console.log(`dispatch-push: job=${shortJobId} user=${shortUserId} will retry (attempt ${newAttemptCount})`);
      }
    }
  }

  console.log(`dispatch-push: done — dispatched=${results.dispatched} sent=${results.sent} failed=${results.failed} discarded=${results.discarded}`);
  return json(results, 200);
});

// ── Helpers ───────────────────────────────────────────────────────────────────

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function markJob(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  jobId: string,
  status: "sent" | "failed" | "discarded",
  attemptCount: number,
  lastError: string | null
): Promise<void> {
  const update: Record<string, unknown> = {
    status,
    attempt_count: attemptCount,
    last_error: lastError,
  };
  if (status === "sent") {
    update.sent_at = new Date().toISOString();
  }
  const { error } = await supabase
    .from("notification_jobs")
    .update(update)
    .eq("id", jobId);
  if (error) {
    console.error(`dispatch-push: markJob(${jobId.slice(0, 8)}) error:`, error.message);
  }
}
