-- Migration: 20260506190000_expire_kicks_to_boss_pool.sql
--
-- Bug: when a joiner's 60s invite timer expires, expire_stale_invites reverts
-- the row to status='queued' but leaves it attached to the raid (raid_id
-- unchanged). The host's list_raid_queue still returns it (only filters by
-- raid_id and excludes terminal statuses), so the host UI keeps the
-- expired joiner on the lobby card with an "IN LOBBY" badge. The user
-- expects an expired invite to *kick the joiner out of the lobby* — they
-- should fall back to the boss-level queue pool (raid_id = NULL) and remain
-- findable for the next raid for that boss.
--
-- Behavior change:
--   1. Steps 1, A, B, C are unchanged in semantics.
--   2. After everything else has run, any row in v_expired_ids that is
--      still status='queued' AND raid_id=p_raid_id is moved to the boss
--      pool: raid_id = NULL, position = NULL, joined_at preserved (so they
--      keep their FIFO/VIP priority for the next raid hatch). status stays
--      'queued', boss_id and is_vip are unchanged.
--   3. Step C still keeps the highest-priority expired joiner attached to
--      the raid as 'invited' when there are no other candidates, so the
--      sole-candidate self-heal path continues to work. That row is not
--      'queued' so it is not eligible for the kick-out step.
--   4. If a user already has a boss-pool row queued for this boss
--      (ux_raid_queues_boss_user_waiting partial unique index), the kick
--      conversion would violate the unique index — fall back to cancelling
--      the dead row in that case (the existing boss-pool row keeps them
--      in the pool).
--
-- Net effect: the host's lobby card no longer shows joiners whose invite
-- timer has expired (unless they are the sole candidate, in which case
-- they cycle queued ↔ invited as before).

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
  v_kick_id       uuid;
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

      -- Step C: expired-joiner fallback (sole-candidate self-heal).
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

  -- ============================================================
  -- Step D (NEW): kick remaining expired joiners out to the boss pool.
  --
  -- Any v_expired_ids row still status='queued' AND raid_id=p_raid_id
  -- after Steps A/B/C is one that:
  --   - was just reverted from invited to queued, AND
  --   - was NOT picked as the sole-candidate re-invite, AND
  --   - is no longer the active invitee.
  -- Move it to the boss-level pool so the host's lobby card no longer
  -- shows it, while keeping the user findable for future raids.
  -- ============================================================
  FOR v_kick_id IN
    SELECT id FROM public.raid_queues
    WHERE id = ANY(v_expired_ids)
      AND raid_id = p_raid_id
      AND status  = 'queued'
  LOOP
    BEGIN
      UPDATE public.raid_queues
      SET raid_id    = NULL,
          position   = NULL,
          updated_at = now()
      WHERE id = v_kick_id;
    EXCEPTION WHEN unique_violation THEN
      -- User already has an active boss-pool row for this boss;
      -- cancel the dead-raid entry instead.
      UPDATE public.raid_queues
      SET status = 'cancelled', updated_at = now()
      WHERE id = v_kick_id;
    END;
  END LOOP;

  -- Recompute positions in the raid one final time so any gaps left by
  -- kicked rows are closed.
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

  RETURN v_reverted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_invites(uuid) TO authenticated;
