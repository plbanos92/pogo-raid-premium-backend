// Edge Function: expire-stale-invites
// Scheduled every minute — expires invited queue entries older than 60s
// back to 'queued' for all non-terminal raids.
//
// Decision: browser-side runQueueMaintenance expiry is retained alongside this.
// Overlapping client+server is safe (expire_stale_invites is idempotent) and
// provides redundancy: this function catches idle sessions while the browser
// call accelerates expiry for active users.
//
// Security: requires 'x-cron-secret' header matching the CRON_SECRET env var
// to prevent unauthorized triggers of the exposed endpoint.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get("CRON_SECRET");
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  // Require x-cron-secret header to prevent unauthorized calls
  const cronSecretHeader = req.headers.get("x-cron-secret");
  if (!CRON_SECRET || cronSecretHeader !== CRON_SECRET) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json" } }
    );
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ error: "Missing Supabase env vars" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false }
  });

  const { data, error } = await supabase.rpc("expire_stale_invites_all");

  if (error) {
    console.error("expire_stale_invites_all error:", error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  console.log(`expire_stale_invites_all: expired ${data} invite(s)`);
  return new Response(
    JSON.stringify({ expired: data }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
