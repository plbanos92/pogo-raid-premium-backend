-- ============================================================
-- Phase 3: egg-status maintenance guards
-- ============================================================
-- Adds explicit 'egg' guards to three maintenance RPCs so that
-- egg-lobby raids are never accidentally processed by functions
-- that only apply to post-hatch open/lobby/raiding states.
--
-- Functions modified:
--   1. expire_stale_invites                — defense-in-depth RETURN 0 guard
--   2. check_host_inactivity               — defense-in-depth RETURN false guard
--   3. cleanup_expired_session_for_user    — 'egg' added to active-raid predicate
--
-- Functions confirmed safe (no change needed):
--   - expire_then_promote_next (20260401230000): promote logic inside
--     expire_stale_invites gates on v_raid_status IN ('open','lobby') — egg excluded.
--   - add_invite_attempts_auto_reinvite (20260401220000): earlier rewrite
--     superseded by 20260409110000; already safe via same gate.
--   - join_boss_queue (20260409110000): gates on r.status IN ('open', 'lobby')
--     — egg excluded. No change needed.
-- ============================================================


-- ============================================================
-- 1. expire_stale_invites
--    Source: 20260409110000_enqueue_notification_jobs.sql
--    Change: add IF v_raid_status = 'egg' THEN RETURN 0; END IF;
--            immediately after v_raid_status is first fetched.
-- ============================================================

CREATE OR REPLACE FUNCTION public.expire_stale_invites(p_raid_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid_status         text;
  v_capacity            int;
  v_confirmed           int;
  v_reverted            int := 0;
  v_expired_ids         uuid[];
  v_boss_id             uuid;
  v_host_user_id        uuid;
  v_raid_promoted       int := 0;
  v_boss_name           text;
  v_promoted_user_id    uuid;
  v_promoted_queue_id   uuid;
  v_promoted_invited_at timestamptz;
  v_bq_user_id          uuid;
  v_bq_queue_id         uuid;
  v_bq_invited_at       timestamptz;
BEGIN
  -- Collect expired entry IDs up front
  SELECT array_agg(id) INTO v_expired_ids
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND status = 'invited'
    AND invited_at < now() - interval '60 seconds';

  IF v_expired_ids IS NULL OR array_length(v_expired_ids, 1) = 0 THEN
    RETURN 0;
  END IF;

  -- Revert ALL expired entries to queued at the TAIL (joined_at = now())
  UPDATE public.raid_queues
  SET status     = 'queued',
      invited_at = NULL,
      joined_at  = now(),
      updated_at = now()
  WHERE id = ANY(v_expired_ids);
  GET DIAGNOSTICS v_reverted = ROW_COUNT;

  -- Position recompute (trg_recompute_positions does NOT fire on invited → queued)
  IF v_reverted > 0 THEN
    UPDATE public.raid_queues SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE raid_queues.id = sub.id;
  END IF;

  -- Auto-promote the next queued user EXCLUDING the just-expired entries.
  -- Without the exclusion, the same user who just expired would be picked
  -- right back up (they are now queued), creating an infinite cycle.
  IF v_reverted > 0 THEN
    SELECT r.status, r.capacity, r.raid_boss_id, r.host_user_id
      INTO v_raid_status, v_capacity, v_boss_id, v_host_user_id
      FROM public.raids r
     WHERE r.id = p_raid_id;

    -- Defense-in-depth: egg lobbies have no invited entries yet so the
    -- early-exit above should already protect this path, but guard explicitly.
    IF v_raid_status = 'egg' THEN RETURN 0; END IF;

    SELECT COUNT(*) INTO v_confirmed
      FROM public.raid_queues
     WHERE raid_id = p_raid_id AND status = 'confirmed';

    IF NOT EXISTS (
      SELECT 1 FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status = 'invited'
    ) AND v_raid_status IN ('open', 'lobby')
      AND v_confirmed < v_capacity
    THEN
      -- Step 1: Inline promote from raid-level queue, skipping just-expired entries
      WITH candidate AS (
        SELECT q.id
        FROM public.raid_queues q
        WHERE q.raid_id = p_raid_id
          AND q.status = 'queued'
          AND q.id <> ALL(v_expired_ids)
        ORDER BY q.is_vip DESC, q.joined_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      UPDATE public.raid_queues q
      SET status          = 'invited',
          invited_at      = now(),
          updated_at      = now(),
          invite_attempts = 0
      FROM candidate c
      WHERE q.id = c.id
      RETURNING q.user_id, q.id, q.invited_at
        INTO v_promoted_user_id, v_promoted_queue_id, v_promoted_invited_at;
      GET DIAGNOSTICS v_raid_promoted = ROW_COUNT;

      -- Notify on raid-queue promotion (invite_attempts = 0, not an auto-reinvite)
      IF v_raid_promoted > 0 THEN
        SELECT rb.name INTO v_boss_name
        FROM public.raid_bosses rb WHERE rb.id = v_boss_id;

        INSERT INTO public.notification_jobs (user_id, event_type, title, body, payload, dedupe_key)
        VALUES (
          v_promoted_user_id,
          'invited',
          'You''re invited!',
          'Tap to join the ' || coalesce(v_boss_name, 'raid') || ' lobby',
          jsonb_build_object('queue_id', v_promoted_queue_id, 'click_url', '/?notify=queues'),
          'invited-' || v_promoted_queue_id || '-' || extract(epoch from v_promoted_invited_at)::bigint
        )
        ON CONFLICT (dedupe_key) DO NOTHING;
      END IF;

      -- Step 2: Fall back to boss queue if no raid-level candidate was found
      IF v_raid_promoted = 0 AND v_boss_id IS NOT NULL THEN
        WITH bq_candidate AS (
          SELECT q.id
          FROM public.raid_queues q
          WHERE q.boss_id  = v_boss_id
            AND q.raid_id  IS NULL
            AND q.status   = 'queued'
            AND q.user_id <> v_host_user_id
          ORDER BY q.is_vip DESC, q.joined_at ASC
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE public.raid_queues q
        SET raid_id         = p_raid_id,
            status          = 'invited',
            invited_at      = now(),
            updated_at      = now(),
            invite_attempts = 0
        FROM bq_candidate c
        WHERE q.id = c.id
        RETURNING q.user_id, q.id, q.invited_at
          INTO v_bq_user_id, v_bq_queue_id, v_bq_invited_at;

        -- Recompute positions now that the promoted boss-queue row has raid_id set
        IF FOUND THEN
          UPDATE public.raid_queues SET position = sub.new_pos
          FROM (
            SELECT id,
                   ROW_NUMBER() OVER (
                     PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC
                   ) AS new_pos
            FROM public.raid_queues
            WHERE raid_id = p_raid_id AND status IN ('queued', 'invited')
          ) sub
          WHERE raid_queues.id = sub.id;

          -- Notify on boss-queue promotion (invite_attempts = 0, not an auto-reinvite)
          SELECT rb.name INTO v_boss_name
          FROM public.raid_bosses rb WHERE rb.id = v_boss_id;

          INSERT INTO public.notification_jobs (user_id, event_type, title, body, payload, dedupe_key)
          VALUES (
            v_bq_user_id,
            'invited',
            'You''re invited!',
            'Tap to join the ' || coalesce(v_boss_name, 'raid') || ' lobby',
            jsonb_build_object('queue_id', v_bq_queue_id, 'click_url', '/?notify=queues'),
            'invited-' || v_bq_queue_id || '-' || extract(epoch from v_bq_invited_at)::bigint
          )
          ON CONFLICT (dedupe_key) DO NOTHING;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN v_reverted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_invites(uuid) TO authenticated;


-- ============================================================
-- 2. check_host_inactivity
--    Source: 20260401110000_fix_check_host_inactivity_status_cancel.sql
--    Change: add IF v_raid.status = 'egg' THEN RETURN false; END IF;
--            immediately after v_raid is fetched (the function stores the
--            full row in v_raid rather than a separate v_raid_status variable).
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_host_inactivity(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid public.raids%ROWTYPE;
  v_timeout int;
  v_confirmed_count int;
  v_new_raid_id uuid;
  v_entry record;
BEGIN
  SELECT * INTO v_raid FROM public.raids WHERE id = p_raid_id AND is_active = true;
  IF NOT FOUND THEN RETURN false; END IF;

  -- Defense-in-depth: egg lobbies have no confirmed participants so the
  -- v_confirmed_count < 1 guard below already protects this path, but
  -- guard explicitly against future confirmed-count changes during egg phase.
  IF v_raid.status = 'egg' THEN RETURN false; END IF;

  -- Read configurable timeout (seconds) from app_config
  SELECT host_inactivity_seconds INTO v_timeout FROM public.app_config WHERE id = 1;

  -- Check: has host been inactive longer than the configured timeout?
  IF v_raid.last_host_action_at >= now() - (v_timeout * interval '1 second') THEN
    RETURN false;
  END IF;

  -- Guard: only fire if at least one player has confirmed (sent friend request).
  -- If no one is confirmed, there's no stranded user to protect.
  SELECT COUNT(*) INTO v_confirmed_count
  FROM public.raid_queues WHERE raid_id = p_raid_id AND status = 'confirmed';
  IF v_confirmed_count < 1 THEN RETURN false; END IF;

  -- Destroy the raid: set is_active = false and status = 'cancelled' atomically.
  UPDATE public.raids
  SET is_active = false,
      status = 'cancelled'::raid_status_enum
  WHERE id = p_raid_id;

  -- Find best alternative raid for same boss
  SELECT r.id INTO v_new_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = v_raid.raid_boss_id
    AND r.is_active = true
    AND r.id <> p_raid_id
    AND (SELECT COUNT(*) FROM public.raid_queues q
         WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) < r.capacity
  ORDER BY (SELECT COUNT(*) FROM public.raid_queues q
            WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) DESC
  LIMIT 1;

  -- Re-queue each affected user (with priority boost)
  -- Covers queued/invited/confirmed — all must be moved off the dead raid.
  FOR v_entry IN
    SELECT user_id, note FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed')
  LOOP
    IF v_new_raid_id IS NOT NULL THEN
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (v_new_raid_id, v_entry.user_id, 'queued', true,
              'Re-queued (host inactivity) — priority restored')
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END IF;
  END LOOP;

  -- Cancel original entries (all statuses on the dead raid)
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');

  -- Recompute positions in new raid if users were added
  IF v_new_raid_id IS NOT NULL THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_host_inactivity(uuid) TO authenticated;


-- ============================================================
-- 3. cleanup_expired_session_for_user
--    Source: 20260406100000_cleanup_expired_session_rpc.sql
--    Change: add 'egg' to the active-raid predicate in Step 2 so that
--            egg-lobby sessions hosted by an expiring user are cancelled.
--    NOTE: GRANT is service_role only — do NOT add authenticated access.
-- ============================================================

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
      AND status IN ('open', 'lobby', 'raiding', 'egg')
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
