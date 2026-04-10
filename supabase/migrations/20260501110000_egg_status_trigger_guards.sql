-- Phase 2: Egg-lobby state machine guard + hatch assignment trigger
--
-- Part A: Extend validate_raid_status() — add egg→open and egg→cancelled transitions.
--         Body reproduced verbatim from 20260329230000_add_raid_status_transition_guard.sql
--         with ONE addition to the ELSIF chain. No INSERT arm added (trigger is UPDATE-only).
--
-- Part B: Guard assign_boss_queue_on_raid_create() against egg INSERTs.
--         Body reproduced verbatim from 20260330150000_fix_assign_boss_queue_window_lock.sql
--         with ONE addition at the top of BEGIN: early-return when status = 'egg'.
--
-- Part C: New assign_boss_queue_on_raid_hatch() AFTER UPDATE trigger for egg→open hatch.
--         Uses FOR UPDATE SKIP LOCKED (safer for concurrent hatch calls).
--         Adds AND user_id <> NEW.host_user_id host-guard.

--------------------------------------------------------------------------------
-- Part A — validate_raid_status(): add egg→open and egg→cancelled transitions
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_raid_status()
RETURNS trigger AS $$
BEGIN
  -- Allow no-op updates
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- Allowed transitions
  IF OLD.status = 'open' AND (NEW.status = 'lobby' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'lobby' AND (NEW.status = 'open' OR NEW.status = 'raiding' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'raiding' AND (NEW.status = 'completed' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'egg' AND (NEW.status = 'open' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  END IF;

  -- Block all other transitions
  RAISE EXCEPTION 'Invalid raid status transition: % -> %', OLD.status, NEW.status
    USING ERRCODE = '23514';
END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------------------------------
-- Part B — assign_boss_queue_on_raid_create(): guard against egg INSERT
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_boss_queue_on_raid_create()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'egg' THEN
    RETURN NEW;
  END IF;

  IF NEW.raid_boss_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Auto-assign waiting boss-level entries to the new raid.
  -- VIP first, then by earliest join time, up to raid capacity.
  -- Step 1: lock candidate rows (no window function here).
  -- Step 2: assign position via ROW_NUMBER in the UPDATE.
  WITH locked AS (
    SELECT id
    FROM public.raid_queues
    WHERE boss_id = NEW.raid_boss_id
      AND raid_id IS NULL
      AND status = 'queued'
      AND user_id <> NEW.host_user_id
    ORDER BY is_vip DESC, joined_at ASC
    LIMIT NEW.capacity
    FOR UPDATE
  ),
  ranked AS (
    SELECT l.id,
           ROW_NUMBER() OVER (ORDER BY q.is_vip DESC, q.joined_at ASC) AS rn
    FROM locked l
    JOIN public.raid_queues q ON q.id = l.id
  )
  UPDATE public.raid_queues upd
  SET raid_id    = NEW.id,
      status     = 'invited',
      invited_at = now(),
      position   = r.rn
  FROM ranked r
  WHERE upd.id = r.id;

  RETURN NEW;
END;
$$;

--------------------------------------------------------------------------------
-- Part C — assign_boss_queue_on_raid_hatch(): new AFTER UPDATE trigger
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_boss_queue_on_raid_hatch()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_entry RECORD;
  v_assigned_count INT := 0;
BEGIN
  FOR v_entry IN
    SELECT id
    FROM public.raid_queues
    WHERE boss_id = NEW.raid_boss_id
      AND raid_id IS NULL
      AND status = 'queued'
      AND user_id <> NEW.host_user_id
    ORDER BY is_vip DESC, joined_at ASC
    LIMIT NEW.capacity
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.raid_queues
    SET raid_id    = NEW.id,
        status     = 'invited',
        updated_at = now()
    WHERE id = v_entry.id;
    v_assigned_count := v_assigned_count + 1;
  END LOOP;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_assign_boss_queue_on_hatch
  AFTER UPDATE ON public.raids
  FOR EACH ROW
  WHEN (OLD.status = 'egg' AND NEW.status = 'open')
  EXECUTE FUNCTION public.assign_boss_queue_on_raid_hatch();
