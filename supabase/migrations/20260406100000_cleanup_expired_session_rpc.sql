-- Migration: cleanup_expired_session_rpc
-- Phase 2 of auto-remove-on-session-expiry.
-- Creates a SECURITY DEFINER RPC that is safe to call from an Edge Function
-- using service_role (where auth.uid() is NULL).
-- Does NOT delegate to leave_queue_and_promote or host_cancel_raid because
-- both of those RPCs require a non-NULL auth.uid() and will silently fail or
-- raise when invoked under service_role.

CREATE OR REPLACE FUNCTION public.cleanup_expired_session_for_user(
  p_user_id        uuid,
  p_session_id     uuid    DEFAULT NULL,
  p_removal_source text    DEFAULT 'scheduled_cleanup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cleaned_queues  int     := 0;
  v_cleaned_raids   int     := 0;
  v_errors          text[]  := '{}'::text[];
  v_entry           record;
  v_raid            record;
  v_participant     record;
  v_new_raid_id     uuid;
BEGIN

  -- ----------------------------------------------------------------
  -- Step 1: Clean up non-terminal queue entries for this user.
  --
  -- We use a CTE to lock and read the current status BEFORE the update
  -- so we can act on the old_status inside the loop.
  -- The RETURNING clause on an UPDATE only gives post-update values,
  -- so we carry the pre-update status through the CTE column.
  -- ----------------------------------------------------------------
  FOR v_entry IN
    WITH to_clean AS (
      SELECT id, raid_id, status
      FROM public.raid_queues
      WHERE user_id = p_user_id
        AND status IN ('queued', 'invited', 'confirmed')
      FOR UPDATE
    )
    UPDATE public.raid_queues rq
    SET status     = 'left',
        note       = COALESCE(p_removal_source, rq.note),
        updated_at = now()
    FROM to_clean tc
    WHERE rq.id = tc.id
    RETURNING tc.raid_id, tc.status AS old_status
  LOOP
    v_cleaned_queues := v_cleaned_queues + 1;

    -- Only raid-level entries (not boss-level) have a non-NULL raid_id.
    -- Boss-level entries have raid_id = NULL; they need no promotion.
    IF v_entry.raid_id IS NOT NULL THEN

      -- If the user held an active slot (invited or confirmed), the next
      -- queued user should be promoted to fill the vacancy.
      IF v_entry.old_status IN ('invited', 'confirmed') THEN
        PERFORM public.promote_next_queued_user(v_entry.raid_id);
      END IF;

      -- If the user was confirmed, the lobby may now have no confirmed
      -- participants. If so, revert the raid from 'lobby' back to 'open'
      -- so new participants can join.
      IF v_entry.old_status = 'confirmed' THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.raid_queues
          WHERE raid_id = v_entry.raid_id
            AND status  = 'confirmed'
        ) THEN
          UPDATE public.raids
          SET status = 'open'::raid_status_enum
          WHERE id     = v_entry.raid_id
            AND status = 'lobby'::raid_status_enum;
        END IF;
      END IF;

    END IF;
  END LOOP;

  -- ----------------------------------------------------------------
  -- Step 2: Cancel non-terminal raids hosted by this user.
  --
  -- For each raid we:
  --   a) Cancel the raid itself.
  --   b) Look for the best alternate active raid for the same boss.
  --   c) Re-queue current participants into the alternate (if found).
  --   d) Cancel remaining queue entries in the original raid.
  --
  -- Each raid is wrapped in its own sub-block so a single failure does
  -- not abort the entire cleanup run.
  -- ----------------------------------------------------------------
  FOR v_raid IN
    SELECT id, raid_boss_id, capacity
    FROM public.raids
    WHERE host_user_id = p_user_id
      AND status IN ('open', 'lobby', 'raiding')
    FOR UPDATE
  LOOP
    BEGIN

      -- a) Cancel the raid.
      UPDATE public.raids
      SET status    = 'cancelled'::raid_status_enum,
          is_active = false
      WHERE id = v_raid.id;

      -- b) Find the best alternate active raid for the same boss:
      --    pick the raid that already has the most participants but
      --    still has room (participant count < capacity).
      v_new_raid_id := NULL;
      SELECT r.id INTO v_new_raid_id
      FROM public.raids r
      WHERE r.raid_boss_id = v_raid.raid_boss_id
        AND r.is_active    = true
        AND r.id          <> v_raid.id
        AND (
          SELECT COUNT(*)
          FROM public.raid_queues q
          WHERE q.raid_id = r.id
            AND q.status IN ('queued', 'invited', 'confirmed')
        ) < r.capacity
      ORDER BY (
        SELECT COUNT(*)
        FROM public.raid_queues q
        WHERE q.raid_id = r.id
          AND q.status IN ('queued', 'invited', 'confirmed')
      ) DESC
      LIMIT 1;

      -- c) Re-queue all active participants into the alternate raid.
      --    Uses ON CONFLICT DO NOTHING to skip any user already in the
      --    alternate raid (e.g. if they joined independently).
      IF v_new_raid_id IS NOT NULL THEN
        FOR v_participant IN
          SELECT user_id, note
          FROM public.raid_queues
          WHERE raid_id = v_raid.id
            AND status IN ('queued', 'invited', 'confirmed')
        LOOP
          INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
          VALUES (
            v_new_raid_id,
            v_participant.user_id,
            'queued',
            true,
            'Re-queued (host session expired) — priority restored'
          )
          ON CONFLICT (raid_id, user_id) DO NOTHING;
        END LOOP;
      END IF;

      -- d) Cancel remaining queue entries in the original raid.
      --    This covers anyone who did not get re-queued above
      --    (either because no alternate existed, or because they were
      --    already in the alternate raid).
      UPDATE public.raid_queues
      SET status     = 'cancelled',
          updated_at = now()
      WHERE raid_id = v_raid.id
        AND status IN ('queued', 'invited', 'confirmed');

      v_cleaned_raids := v_cleaned_raids + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors := array_append(
        v_errors,
        format('raid %s: %s', v_raid.id, SQLERRM)
      );
    END;
  END LOOP;

  -- ----------------------------------------------------------------
  -- Step 3: Mark the session as ended (idempotent — only if still open).
  -- ----------------------------------------------------------------
  IF p_session_id IS NOT NULL THEN
    UPDATE public.user_sessions
    SET ended_at   = now(),
        end_reason = 'session_expiry'
    WHERE id       = p_session_id
      AND user_id  = p_user_id
      AND ended_at IS NULL;
  END IF;

  -- ----------------------------------------------------------------
  -- Step 4: Return JSON audit record.
  -- ----------------------------------------------------------------
  RETURN jsonb_build_object(
    'user_id',        p_user_id,
    'session_id',     p_session_id,
    'removal_source', p_removal_source,
    'cleaned_queues', v_cleaned_queues,
    'cleaned_raids',  v_cleaned_raids,
    'errors',         v_errors,
    'ran_at',         now()
  );

END;
$$;

-- Harden permissions: only service_role may call this function.
-- anon and authenticated roles must NOT be able to invoke it directly.
REVOKE ALL ON FUNCTION public.cleanup_expired_session_for_user(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.cleanup_expired_session_for_user(uuid, uuid, text) TO service_role;
