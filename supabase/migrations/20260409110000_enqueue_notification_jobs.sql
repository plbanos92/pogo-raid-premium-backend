-- Migration: 20260409110000_enqueue_notification_jobs.sql
-- Phase 3: Instrument four backend RPCs to enqueue notification_jobs rows when
-- important queue state transitions occur.
--
-- Changed functions:
--   1. host_invite_next_in_queue  — emit 'invited' job on manual promotion
--   2. expire_stale_invites       — emit 'invited' job on raid-queue promotion
--                                    and on boss-queue promotion
--   3. join_boss_queue            — emit 'invited' job on immediate auto-invite-on-join
--   4. host_cancel_raid           — emit 'cancelled' jobs (set-based) for all active members
--
-- IMPORTANT: The unique index on notification_jobs(dedupe_key) already exists from
-- 20260409100000_add_push_subscriptions_and_notification_jobs.sql — not re-created here.
--
-- Base versions read before writing:
--   host_invite_next_in_queue : 20260401220000_add_invite_attempts_auto_reinvite.sql
--   expire_stale_invites      : 20260402190000_expire_promotes_from_boss_queue.sql
--   join_boss_queue           : 20260401240000_inline_join_boss_queue.sql
--   host_cancel_raid          : 20260330110000_fix_host_cancel_raid_auth.sql

-- ============================================================
-- 1. host_invite_next_in_queue
--    Adds 'invited' notification after manual promotion.
-- ============================================================

CREATE OR REPLACE FUNCTION public.host_invite_next_in_queue(
  p_raid_id uuid
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_invited   public.raid_queues%ROWTYPE;
  v_expired   int;
  v_boss_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.raids r
    WHERE r.id = p_raid_id
      AND r.host_user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Only the raid host can invite users for this raid'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize host invitation decisions per raid.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  -- Expire stale invites first (60s timeout)
  SELECT public.expire_stale_invites(p_raid_id) INTO v_expired;

  -- One-invite-at-a-time guard: reject if someone is already invited
  IF EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status = 'invited'
  ) THEN
    RAISE EXCEPTION 'Another user is already invited — wait for their response'
      USING ERRCODE = 'P0001';
  END IF;

  WITH candidate AS (
    SELECT q.id
    FROM public.raid_queues q
    WHERE q.raid_id = p_raid_id
      AND q.status = 'queued'
    ORDER BY q.is_vip DESC, q.joined_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.raid_queues q
  SET status          = 'invited',
      invite_attempts = 0
  FROM candidate c
  WHERE q.id = c.id
  RETURNING q.* INTO v_invited;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No queued users available for invitation';
  END IF;

  -- Fetch boss name for notification
  SELECT rb.name INTO v_boss_name
  FROM public.raid_bosses rb
  JOIN public.raids r ON r.raid_boss_id = rb.id
  WHERE r.id = p_raid_id;

  -- Enqueue 'invited' notification for the newly invited user.
  -- invite_attempts is always 0 at this point (set above).
  INSERT INTO public.notification_jobs (user_id, event_type, title, body, payload, dedupe_key)
  VALUES (
    v_invited.user_id,
    'invited',
    'You''re invited!',
    'Tap to join the ' || coalesce(v_boss_name, 'raid') || ' lobby',
    jsonb_build_object('queue_id', v_invited.id, 'click_url', '/?notify=queues'),
    'invited-' || v_invited.id || '-' || extract(epoch from v_invited.invited_at)::bigint
  )
  ON CONFLICT (dedupe_key) DO NOTHING;

  RETURN v_invited;
END;
$$;

-- ============================================================
-- 2. expire_stale_invites
--    Adds 'invited' notifications after raid-queue promotion (Step 1)
--    and boss-queue promotion (Step 2).
--    Invariants preserved:
--      - v_expired_ids excluded from candidate CTE (infinite-cycle prevention)
--      - Position recompute fires on revert
--      - Boss-queue path only when v_raid_promoted = 0
--      - Host guard: bq candidates with user_id = host are skipped
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

-- ============================================================
-- 3. join_boss_queue
--    Adds 'invited' notification on the immediate auto-invite-on-join path.
--    The boss-level queue fall-through path (status='queued') gets no notification
--    since no invite is issued there.
--    Invariants preserved:
--      1. Host self-join guard: RAISE EXCEPTION if host_user_id = calling user
--      2. Auto-invite on join: INSERT with status='invited', invited_at=now()
--      3-6. Advisory lock, FOR UPDATE re-verify, capacity re-check, terminal cleanup
-- ============================================================

CREATE OR REPLACE FUNCTION public.join_boss_queue(
  p_boss_id uuid,
  p_note    text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_raid_id      uuid;
  v_existing     public.raid_queues%ROWTYPE;
  v_result       public.raid_queues%ROWTYPE;
  -- Inlined from join_raid_queue
  v_capacity     int;
  v_host_user_id uuid;
  v_current_size int;
  v_boss_name    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Idempotent: check if user already has an active entry for this boss
  -- (covers both boss-level entries and raid-level entries via raid_boss_id)
  SELECT rq.* INTO v_existing
  FROM public.raid_queues rq
  LEFT JOIN public.raids r ON r.id = rq.raid_id
  WHERE rq.user_id = v_uid
    AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding')
    AND (
      (rq.boss_id = p_boss_id AND rq.raid_id IS NULL)
      OR r.raid_boss_id = p_boss_id
    )
  LIMIT 1;

  IF FOUND THEN RETURN v_existing; END IF;

  -- Try to find an eligible raid for this boss
  SELECT r.id INTO v_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = p_boss_id
    AND r.status IN ('open', 'lobby')
    AND r.host_user_id <> v_uid
    AND (
      SELECT COUNT(*) FROM public.raid_queues q
      WHERE q.raid_id = r.id AND q.status IN ('queued', 'invited', 'confirmed')
    ) < r.capacity
  ORDER BY (
    SELECT COUNT(*) FROM public.raid_queues q
    WHERE q.raid_id = r.id AND q.status IN ('queued', 'invited', 'confirmed')
  ) DESC
  LIMIT 1;

  IF v_raid_id IS NOT NULL THEN
    -- ── Inlined join_raid_queue logic ────────────────────────────────────
    -- Invariant 3: acquire per-raid advisory lock BEFORE the FOR UPDATE read
    PERFORM pg_advisory_xact_lock(hashtext(v_raid_id::text));

    -- Invariant 6: clean up any terminal rows for this user in this raid
    -- so the subsequent INSERT can succeed without a unique-constraint conflict
    DELETE FROM public.raid_queues
    WHERE raid_id = v_raid_id AND user_id = v_uid
      AND status IN ('left', 'cancelled', 'done');

    -- Invariant 4: re-verify raid is still joinable under the lock
    SELECT capacity, host_user_id
    INTO v_capacity, v_host_user_id
    FROM public.raids
    WHERE id = v_raid_id AND status IN ('open', 'lobby')
    FOR UPDATE;

    IF NOT FOUND THEN
      -- Raid closed or disappeared between selection and lock; fall through
      -- to the boss-level queue path below by clearing v_raid_id.
      v_raid_id := NULL;
    ELSE
      -- Invariant 1: host cannot join their own lobby as a player
      IF v_host_user_id = v_uid THEN
        RAISE EXCEPTION 'Hosts cannot join their own lobby as a player'
          USING ERRCODE = '23514';
      END IF;

      -- Invariant 5: re-check capacity after lock
      SELECT COUNT(*) INTO v_current_size
      FROM public.raid_queues
      WHERE raid_id = v_raid_id
        AND status IN ('queued', 'invited', 'confirmed');

      IF v_current_size >= v_capacity THEN
        -- Raid filled in the window; fall through to boss-level queue path.
        v_raid_id := NULL;
      ELSE
        -- Invariant 2: auto-invite on join
        -- boss_id and is_vip are populated automatically by triggers on INSERT
        INSERT INTO public.raid_queues (raid_id, user_id, note, status, position, invited_at)
        VALUES (v_raid_id, v_uid, p_note, 'invited', v_current_size + 1, now())
        RETURNING * INTO v_result;

        -- Fetch boss name for notification (p_boss_id is the raid's boss)
        SELECT rb.name INTO v_boss_name
        FROM public.raid_bosses rb
        WHERE rb.id = p_boss_id;

        -- Enqueue 'invited' notification for immediate auto-invite on join
        INSERT INTO public.notification_jobs (user_id, event_type, title, body, payload, dedupe_key)
        VALUES (
          v_result.user_id,
          'invited',
          'You''re invited!',
          'Tap to join the ' || coalesce(v_boss_name, 'raid') || ' lobby',
          jsonb_build_object('queue_id', v_result.id, 'click_url', '/?notify=queues'),
          'invited-' || v_result.id || '-' || extract(epoch from v_result.invited_at)::bigint
        )
        ON CONFLICT (dedupe_key) DO NOTHING;

        RETURN v_result;
      END IF;
    END IF;
    -- ── End inlined logic ─────────────────────────────────────────────────
  END IF;

  -- No eligible raid (or raid vanished/filled under lock) —
  -- fall through to the boss-level queue entry path.
  PERFORM pg_advisory_xact_lock(hashtext('boss_queue_' || p_boss_id::text));

  -- Re-check idempotency for the boss-level slot under lock
  SELECT rq.* INTO v_existing
  FROM public.raid_queues rq
  WHERE rq.user_id = v_uid AND rq.boss_id = p_boss_id
    AND rq.raid_id IS NULL AND rq.status = 'queued';
  IF FOUND THEN RETURN v_existing; END IF;

  -- Clean up terminal boss-level rows so a fresh INSERT can proceed
  DELETE FROM public.raid_queues
  WHERE boss_id = p_boss_id AND user_id = v_uid
    AND raid_id IS NULL AND status IN ('left', 'cancelled', 'done');

  INSERT INTO public.raid_queues (boss_id, user_id, note, status)
  VALUES (p_boss_id, v_uid, COALESCE(p_note, 'Waiting for host'), 'queued')
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

-- ============================================================
-- 4. host_cancel_raid
--    Adds set-based 'cancelled' notifications immediately before the bulk
--    UPDATE that sets all active queue members to 'cancelled'.
--    The INSERT reads the live statuses so it must run before the UPDATE.
-- ============================================================

CREATE OR REPLACE FUNCTION public.host_cancel_raid(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid := auth.uid();
  v_raid        public.raids%ROWTYPE;
  v_new_raid_id uuid;
  v_entry       record;
  v_boss_name   text;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_raid
  FROM public.raids
  WHERE id = p_raid_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN false; END IF;

  IF v_raid.host_user_id <> v_caller_id THEN
    RAISE EXCEPTION 'Not authorized to cancel this raid' USING ERRCODE = '42501';
  END IF;

  IF v_raid.status IN ('cancelled', 'completed') THEN RETURN false; END IF;
  IF NOT v_raid.is_active THEN RETURN false; END IF;

  UPDATE public.raids
  SET is_active = false,
      status    = 'cancelled'
  WHERE id = p_raid_id;

  SELECT r.id INTO v_new_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = v_raid.raid_boss_id
    AND r.is_active    = true
    AND r.id          <> p_raid_id
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

  FOR v_entry IN
    SELECT user_id, note
    FROM public.raid_queues
    WHERE raid_id = p_raid_id
      AND status IN ('queued', 'invited', 'confirmed')
  LOOP
    IF v_new_raid_id IS NOT NULL THEN
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (
        v_new_raid_id,
        v_entry.user_id,
        'queued',
        true,
        'Re-queued (host cancelled raid) — priority restored'
      )
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END IF;
  END LOOP;

  -- Fetch boss name for cancel notification
  SELECT rb.name INTO v_boss_name
  FROM public.raid_bosses rb
  WHERE rb.id = v_raid.raid_boss_id;

  -- Enqueue 'cancelled' notification for every active queue member (except the host).
  -- Run before the bulk cancel UPDATE so the status filter still matches live rows.
  INSERT INTO public.notification_jobs (user_id, event_type, title, body, payload, dedupe_key)
  SELECT rq.user_id,
         'cancelled',
         'Spot cancelled',
         'Your spot in the ' || coalesce(v_boss_name, 'raid') || ' queue was cancelled',
         jsonb_build_object('click_url', '/?notify=queues'),
         'cancelled-' || rq.id
  FROM public.raid_queues rq
  WHERE rq.raid_id = p_raid_id
    AND rq.status IN ('queued', 'invited', 'confirmed')
    AND rq.user_id <> auth.uid()
  ON CONFLICT (dedupe_key) DO NOTHING;

  UPDATE public.raid_queues
  SET status = 'cancelled'
  WHERE raid_id = p_raid_id
    AND status IN ('queued', 'invited', 'confirmed');

  IF v_new_raid_id IS NOT NULL THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id
               ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id
        AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.host_cancel_raid(uuid) TO authenticated;
