-- Migration: 20260502100000_sole_candidate_reinvite.sql
--
-- Extends expire_stale_invites with a final expired-joiner fallback:
-- if the raid-level queue (Step A) and boss-level queue (Step B) both
-- produce zero fresh candidates, re-invite the highest-priority just-expired
-- queued entry so the lobby does not stall when only expired joiners remain.

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

  -- Revert ALL expired entries to queued at the TAIL (joined_at = now())
  UPDATE public.raid_queues
  SET status     = 'queued',
      invited_at = NULL,
      joined_at  = now(),
      updated_at = now()
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
      -- Step A: inline promote from raid-level queue, skipping just-expired entries
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

      -- Step B: fall back to boss queue if no raid-level candidate was found
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
