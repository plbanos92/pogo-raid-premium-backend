-- Migration: 20260402190000_expire_promotes_from_boss_queue.sql
--
-- Extends expire_stale_invites so that when a slot opens (an invite expires and
-- no raid-queue candidate is available), it also falls back to the boss queue:
-- rows with raid_id IS NULL, boss_id = <raid's boss>, status = 'queued'.
--
-- Note: this supersedes 20260402150000_fix_expire_cycle_exclusion.sql.
-- The timestamp was chosen to be lexicographically after all 20260402* siblings
-- so that db reset --local produces the correct final function body.
--
-- Key invariants preserved:
--   - Infinite-cycle prevention: v_expired_ids excluded from raid-queue candidate.
--   - Position recompute after reverting expired entries.
--   - Guard: only promote when no 'invited' row exists, raid is open/lobby,
--     and confirmed < capacity.
--   - Boss-queue path is only attempted when raid-queue CTE updated 0 rows.
--   - boss_id is NOT changed on the promoted row (preserved for audit trail).
--   - Host-guard: boss-queue candidates whose user_id = host are skipped.

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
      WHERE q.id = c.id;
      GET DIAGNOSTICS v_raid_promoted = ROW_COUNT;

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
        WHERE q.id = c.id;

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
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN v_reverted;
END;
$$;
