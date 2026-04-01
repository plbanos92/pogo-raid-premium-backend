-- Migration: 20260401240000_inline_join_boss_queue.sql
--
-- Self-contains join_boss_queue so it no longer delegates to join_raid_queue
-- for the raid-found path. join_raid_queue is NOT dropped here; that happens
-- in a later phase.
--
-- Key invariants preserved from join_raid_queue:
--   1. Host self-join guard: RAISE EXCEPTION if host_user_id = calling user
--   2. Auto-invite on join: INSERT with status = 'invited', invited_at = now()
--   3. Advisory lock per raid BEFORE FOR UPDATE on raids row
--   4. FOR UPDATE re-verify joinability under lock (race-condition safe)
--   5. Capacity re-check after lock
--   6. Clean up terminal rows (left/cancelled/done) before INSERT

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
