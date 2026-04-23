-- Migration: 20260502130000_track_invite_expire_cycles.sql
--
-- Make the re-invite cycle visible to hosts.
--
-- Background: `expire_stale_invites` from 20260502100000_sole_candidate_reinvite.sql
-- silently cycles expired joiners back to `invited` when no fresh candidate exists
-- (Step C). The host UI shows the same joiner as "Invited" indefinitely with no
-- indication that the invite timer has expired one or more times. This migration:
--
--   1. Increments `invite_attempts` on every expire revert (Step 1), so the
--      counter truthfully reflects how many 60s windows have elapsed without
--      the joiner confirming.
--   2. Resets `invite_attempts` to 0 when a FRESH candidate is promoted from
--      either the raid-level queue (Step A) or the boss queue (Step B).
--   3. Leaves `invite_attempts` as-is when Step C re-invites the same expired
--      joiner (the counter already reflects the real cycle count).
--   4. Exposes `invite_attempts` in `list_raid_queue` so the host UI can render
--      an "invite expired · re-inviting" badge when the counter is > 0.

-- ============================================================
-- A. Rewrite expire_stale_invites to track attempts
-- ============================================================

CREATE OR REPLACE FUNCTION public.expire_stale_invites(p_raid_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid_status   text;
  v_capacity      int;
  v_confirmed     int;
  v_reverted      int := 0;
  v_expired_ids   uuid[];
  v_boss_id       uuid;
  v_host_user_id  uuid;
  v_raid_promoted int := 0;
  v_boss_promoted int := 0;
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

  -- Revert ALL expired entries to queued at the TAIL (joined_at = now()),
  -- and INCREMENT invite_attempts so the host UI can show cycle count.
  UPDATE public.raid_queues
  SET status          = 'queued',
      invited_at      = NULL,
      joined_at       = now(),
      invite_attempts = invite_attempts + 1,
      updated_at      = now()
  WHERE id = ANY(v_expired_ids);
  GET DIAGNOSTICS v_reverted = ROW_COUNT;

  -- Position recompute (trg_recompute_positions does NOT fire on invited -> queued)
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
      -- Step A: inline promote from raid-level queue, skipping just-expired entries.
      -- Fresh candidate → reset invite_attempts to 0.
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
      WHERE q.id = c.id;
      GET DIAGNOSTICS v_raid_promoted = ROW_COUNT;

      -- Step B: fall back to boss queue if no raid-level candidate was found.
      -- Fresh candidate → reset invite_attempts to 0.
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
        WHERE q.id = c.id;
        GET DIAGNOSTICS v_boss_promoted = ROW_COUNT;

        -- Recompute positions now that the promoted boss-queue row has raid_id set
        IF v_boss_promoted > 0 THEN
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
      END IF;

      -- Step C: expired-joiner fallback.
      -- Only fires when both Step A and Step B produced zero rows.
      -- Allows the lobby to self-heal when all remaining candidates are
      -- expired joiners. Re-invites indefinitely with no attempt cap.
      -- invite_attempts is NOT reset — the counter already reflects the
      -- real cycle count (incremented above in the revert step).
      IF v_raid_promoted = 0 AND v_boss_promoted = 0 THEN
        WITH expired_fallback AS (
          SELECT q.id
          FROM public.raid_queues q
          WHERE q.raid_id = p_raid_id
            AND q.status  = 'queued'
            AND q.id      = ANY(v_expired_ids)
          ORDER BY q.is_vip DESC, q.joined_at ASC
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE public.raid_queues q
        SET status     = 'invited',
            invited_at = now(),
            updated_at = now()
        FROM expired_fallback c
        WHERE q.id = c.id;
      END IF;
    END IF;
  END IF;

  RETURN v_reverted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_invites(uuid) TO authenticated;

-- ============================================================
-- B. Expose invite_attempts in list_raid_queue for host UI
-- ============================================================

DROP FUNCTION IF EXISTS public.list_raid_queue(uuid);

CREATE OR REPLACE FUNCTION public.list_raid_queue(p_raid_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
  "position" int,
  is_vip boolean,
  note text,
  joined_at timestamptz,
  invited_at timestamptz,
  invite_attempts int,
  display_name text,
  in_game_name text,
  friend_code text,
  trainer_level smallint,
  team text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.raids
    WHERE raids.id = p_raid_id AND host_user_id = v_uid AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or inactive'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    rq.id,
    rq.user_id,
    rq.status,
    rq.position,
    rq.is_vip,
    rq.note,
    rq.joined_at,
    rq.invited_at,
    rq.invite_attempts,
    up.display_name,
    up.in_game_name,
    up.friend_code,
    up.trainer_level,
    up.team
  FROM public.raid_queues rq
  LEFT JOIN public.user_profiles up ON up.auth_id = rq.user_id
  WHERE rq.raid_id = p_raid_id
    AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ORDER BY rq.is_vip DESC, rq.joined_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_raid_queue(uuid) TO authenticated;
