-- ──────────────────────────────────────────────────────────────────────────
-- State machine audit fixes (#10, #11, #12, #19, #20)
-- ──────────────────────────────────────────────────────────────────────────
--
-- Background: a frontend/backend state-machine audit identified five gaps
-- where illegal status transitions could land in the database without being
-- rejected. Today the frontend FSM is the only thing keeping the data
-- consistent for raid_queues — the database has no equivalent guard. This
-- migration closes those gaps:
--
--   #10  validate_raid_status_on_insert     — block raids INSERTs with
--                                              non-initial status values
--   #11  validate_raid_queue_status         — BEFORE UPDATE trigger that
--                                              mirrors VALID_QUEUE_TRANSITIONS
--                                              (queueStateMachine.js)
--   #12  check_host_inactivity              — early-exit when raid status is
--                                              not in ('open','lobby')
--   #19  leave_queue_and_promote            — reject from non-leaveable
--                                              statuses (raiding/cancelled)
--   #20  start_raid                         — early-exit when raid status is
--                                              not in ('open','lobby') so the
--                                              error is meaningful (instead of
--                                              the trigger's generic "invalid
--                                              transition" rollback)
--
-- All changes are additive: they tighten guards but do not relax any existing
-- restriction. Existing legitimate flows (host_finish, hatch, cancel, etc.)
-- still go through their own RPCs which set legal status values.
-- ──────────────────────────────────────────────────────────────────────────

-- ============================================================
-- #10. validate_raid_status_on_insert: block illegal initial statuses
-- ============================================================
CREATE OR REPLACE FUNCTION public.validate_raid_status_on_insert()
RETURNS trigger AS $$
BEGIN
  -- Only 'open' and 'egg' are valid initial states for a new raid.
  -- 'lobby', 'raiding', 'completed', 'cancelled' must be reached via UPDATE.
  IF NEW.status NOT IN ('open', 'egg') THEN
    RAISE EXCEPTION 'Invalid initial raid status: % (allowed: open, egg)', NEW.status
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_raid_status_on_insert ON public.raids;
CREATE TRIGGER trg_validate_raid_status_on_insert
  BEFORE INSERT ON public.raids
  FOR EACH ROW EXECUTE FUNCTION public.validate_raid_status_on_insert();


-- ============================================================
-- #11. validate_raid_queue_status: BEFORE UPDATE guard mirroring
--      VALID_QUEUE_TRANSITIONS in src/state-machines/queueStateMachine.js
-- ============================================================
-- Allowed transitions (must match the frontend enum exactly):
--   queued    → invited, left, cancelled
--   invited   → confirmed, queued, left, cancelled
--   confirmed → raiding, left, cancelled, queued
--   raiding   → done, cancelled
--   done      → (terminal)
--   left      → (terminal)
--   cancelled → (terminal)
--   Same-value updates always allowed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_raid_queue_status()
RETURNS trigger AS $$
BEGIN
  -- Allow no-op updates (status field not changed)
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'queued'    AND NEW.status IN ('invited', 'left', 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'invited'   AND NEW.status IN ('confirmed', 'queued', 'left', 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'confirmed' AND NEW.status IN ('raiding', 'left', 'cancelled', 'queued') THEN
    RETURN NEW;
  ELSIF OLD.status = 'raiding'   AND NEW.status IN ('done', 'cancelled') THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Invalid raid_queues status transition: % -> %', OLD.status, NEW.status
    USING ERRCODE = '23514';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_raid_queue_status ON public.raid_queues;
CREATE TRIGGER trg_validate_raid_queue_status
  BEFORE UPDATE ON public.raid_queues
  FOR EACH ROW EXECUTE FUNCTION public.validate_raid_queue_status();


-- ============================================================
-- #12. check_host_inactivity: short-circuit for non-active raid statuses.
--      Existing version already short-circuits on status = 'egg'; tighten
--      to only proceed when status is in ('open','lobby'). is_active alone
--      is not enough (raiding raids are also active but should not be
--      cancelled by an inactivity check).
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

  -- Only run inactivity sweep for open/lobby raids. Egg, raiding, completed
  -- and cancelled all have well-defined lifecycle owners (hatch sweep,
  -- host_finish, etc.) and must not be reaped by this generic guard.
  IF v_raid.status NOT IN ('open', 'lobby') THEN
    RETURN false;
  END IF;

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
-- #19. leave_queue_and_promote: reject from non-leaveable statuses.
--      Today only 'left' and 'done' are blocked; 'raiding' and 'cancelled'
--      should also be rejected. The frontend FSM enforces this but the RPC
--      should not rely on the client.
-- ============================================================
CREATE OR REPLACE FUNCTION public.leave_queue_and_promote(
  p_queue_id uuid,
  p_note text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.raid_queues%ROWTYPE;
  v_left public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_row
  FROM public.raid_queues
  WHERE id = p_queue_id
    AND user_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue entry not found'
      USING ERRCODE = '42501';
  END IF;

  -- Idempotent: leaving an already-left entry is a no-op
  IF v_row.status = 'left' THEN
    RETURN v_row;
  END IF;

  -- Only queued/invited/confirmed entries may be left.
  -- 'raiding' is in-flight (player is mid-raid in the game). 'done'/'cancelled'
  -- are terminal — leaving them is meaningless.
  IF v_row.status NOT IN ('queued', 'invited', 'confirmed') THEN
    RAISE EXCEPTION 'Cannot leave queue from status: %', v_row.status
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.raid_queues
  SET status = 'left',
      note = COALESCE(p_note, note),
      updated_at = now()
  WHERE id = p_queue_id
  RETURNING * INTO v_left;

  -- Skip promotion and raid-status updates for boss-level entries (no raid)
  IF v_left.raid_id IS NOT NULL THEN
    IF v_row.status IN ('invited', 'confirmed') THEN
      PERFORM public.promote_next_queued_user(v_left.raid_id);
    END IF;

    -- If the departing entry was 'confirmed' and no confirmed entries
    -- remain for this raid, revert raid status from 'lobby' to 'open'.
    IF v_row.status = 'confirmed' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.raid_queues
        WHERE raid_id = v_left.raid_id AND status = 'confirmed'
      ) THEN
        UPDATE public.raids
        SET status = 'open'::raid_status_enum
        WHERE id = v_left.raid_id
          AND status = 'lobby'::raid_status_enum;
      END IF;
    END IF;
  END IF;

  RETURN v_left;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_queue_and_promote(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_queue_and_promote(uuid, text) TO authenticated;


-- ============================================================
-- #20. start_raid: explicit status guard so the error message is meaningful
--      when called against an egg/raiding/completed/cancelled raid. Today
--      the validate_raid_status trigger would reject the eventual status
--      update with a generic "invalid transition" message, after
--      raid_queues had already been mutated (rolled back via transaction).
-- ============================================================
CREATE OR REPLACE FUNCTION public.start_raid(p_raid_id uuid)
RETURNS public.raids
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_raid public.raids%ROWTYPE;
  v_confirmed int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_raid FROM public.raids
  WHERE id = p_raid_id AND host_user_id = v_uid AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or already inactive'
      USING ERRCODE = '42501';
  END IF;

  -- Explicit status check — surfaces a clear error before any side effects.
  -- validate_raid_status trigger would also block the update, but with a
  -- generic message and only after partial work has been done.
  IF v_raid.status NOT IN ('open', 'lobby') THEN
    RAISE EXCEPTION 'Cannot start raid from status: %', v_raid.status
      USING ERRCODE = '42501';
  END IF;

  -- Must have at least one confirmed participant
  SELECT COUNT(*) INTO v_confirmed
  FROM public.raid_queues
  WHERE raid_id = p_raid_id AND status = 'confirmed';
  IF v_confirmed = 0 THEN
    RAISE EXCEPTION 'No confirmed participants to start with';
  END IF;

  -- Transition confirmed → raiding
  UPDATE public.raid_queues SET status = 'raiding'
  WHERE raid_id = p_raid_id AND status = 'confirmed';

  -- Cancel users who hadn't confirmed yet
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited');

  -- Raid stays is_active = true (raiding in progress)
  UPDATE public.raids
  SET host_finished_at = NULL,
      status = 'raiding'::raid_status_enum
  WHERE id = p_raid_id
  RETURNING * INTO v_raid;

  RETURN v_raid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_raid(uuid) TO authenticated;
