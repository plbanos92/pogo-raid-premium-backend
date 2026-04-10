import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL              = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CLEANUP_CRON_SECRET       = Deno.env.get('CLEANUP_CRON_SECRET')
const JWT_EXPIRY_HOURS          = 24  // Must match jwt_expiry in config.toml (86400s = 24h)

Deno.serve(async (req: Request) => {
  // --------------------------------------------------------------------------
  // Auth: validate shared secret (if set). Allow unauthenticated in local dev.
  // --------------------------------------------------------------------------
  const expectedSecret = CLEANUP_CRON_SECRET
  if (expectedSecret) {
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
    if (token !== expectedSecret) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } },
      )
    }
  }

  // --------------------------------------------------------------------------
  // Service-role client — bypasses RLS so we can read all user_sessions rows
  // --------------------------------------------------------------------------
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  })

  // --------------------------------------------------------------------------
  // Calculate cutoff timestamp
  // --------------------------------------------------------------------------
  const cutoff = new Date(Date.now() - JWT_EXPIRY_HOURS * 60 * 60 * 1000).toISOString()

  // --------------------------------------------------------------------------
  // Find expired-but-unclosed sessions
  // --------------------------------------------------------------------------
  const { data: expiredSessions, error: queryError } = await supabase
    .from('user_sessions')
    .select('id, user_id')
    .is('ended_at', null)
    .lt('started_at', cutoff)

  if (queryError) {
    console.error('[cleanup-expired-sessions] Failed to query user_sessions:', queryError)
    return new Response(
      JSON.stringify({ error: queryError.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    )
  }

  if (!expiredSessions || expiredSessions.length === 0) {
    return new Response(
      JSON.stringify({ message: 'No expired sessions found', processed: 0 }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )
  }

  // --------------------------------------------------------------------------
  // Call cleanup_expired_session_for_user for each expired session
  // --------------------------------------------------------------------------
  const results: Array<{ session_id: string; user_id: string; result?: unknown; error?: string }> = []

  for (const session of expiredSessions) {
    const { data, error } = await supabase.rpc('cleanup_expired_session_for_user', {
      p_user_id: session.user_id,
      p_session_id: session.id,
      p_removal_source: 'scheduled_cleanup',
    })

    if (error) {
      console.error(
        `[cleanup-expired-sessions] Error cleaning session ${session.id} for user ${session.user_id}:`,
        error,
      )
      results.push({ session_id: session.id, user_id: session.user_id, error: error.message })
    } else {
      results.push({ session_id: session.id, user_id: session.user_id, result: data })
    }
  }

  return new Response(
    JSON.stringify({ processed: expiredSessions.length, results }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  )
})
