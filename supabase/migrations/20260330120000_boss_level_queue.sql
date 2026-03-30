-- Boss-level queue: allow players to queue for a boss before any host creates a raid.
-- When a host creates a raid, auto-assign waiting boss-level entries.

--------------------------------------------------------------------------------
-- 1. Add boss_id column to raid_queues
--------------------------------------------------------------------------------
ALTER TABLE public.raid_queues
  ADD COLUMN IF NOT EXISTS boss_id uuid REFERENCES public.raid_bosses(id) ON DELETE SET NULL;

-- Backfill boss_id for existing entries
UPDATE public.raid_queues q
SET boss_id = r.raid_boss_id
FROM public.raids r
WHERE q.raid_id = r.id AND q.boss_id IS NULL;

-- Allow raid_id to be NULL (boss-level entries have no raid yet)
ALTER TABLE public.raid_queues ALTER COLUMN raid_id DROP NOT NULL;

-- Index for lookups by boss_id
CREATE INDEX IF NOT EXISTS idx_raid_queues_boss_id ON public.raid_queues(boss_id);

-- Unique index: one boss-level entry per user per boss
CREATE UNIQUE INDEX IF NOT EXISTS ux_raid_queues_boss_user_waiting
  ON public.raid_queues(boss_id, user_id)
  WHERE raid_id IS NULL AND status = 'queued';

--------------------------------------------------------------------------------
-- 2. Trigger: auto-populate boss_id on INSERT when raid_id is set
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_queue_boss_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.raid_id IS NOT NULL AND NEW.boss_id IS NULL THEN
    SELECT raid_boss_id INTO NEW.boss_id
    FROM public.raids
    WHERE id = NEW.raid_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_set_queue_boss_id
  BEFORE INSERT ON public.raid_queues
  FOR EACH ROW
  EXECUTE FUNCTION public.set_queue_boss_id();

--------------------------------------------------------------------------------
-- 3. Modify join_boss_queue to allow queuing without a raid
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_boss_queue(
  p_boss_id uuid,
  p_note    text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_raid_id  uuid;
  v_existing public.raid_queues%ROWTYPE;
  v_result   public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Idempotent: check if user already has an active entry for this boss
  -- (either boss-level or raid-level)
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

  IF FOUND THEN
    RETURN v_existing;
  END IF;

  -- Try to find an eligible raid (open/lobby, not hosted by user, under capacity)
  SELECT r.id INTO v_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = p_boss_id
    AND r.status IN ('open', 'lobby')
    AND r.host_user_id <> v_uid
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

  IF v_raid_id IS NOT NULL THEN
    -- Found a raid, use existing join_raid_queue
    SELECT * INTO v_result FROM public.join_raid_queue(v_raid_id, p_note);
    RETURN v_result;
  END IF;

  -- No eligible raid — create a boss-level queue entry.
  -- Serialize per boss to prevent duplicate entries under concurrency.
  PERFORM pg_advisory_xact_lock(hashtext('boss_queue_' || p_boss_id::text));

  -- Re-check after acquiring lock (another concurrent call may have inserted)
  SELECT rq.* INTO v_existing
  FROM public.raid_queues rq
  WHERE rq.user_id = v_uid
    AND rq.boss_id = p_boss_id
    AND rq.raid_id IS NULL
    AND rq.status = 'queued';

  IF FOUND THEN
    RETURN v_existing;
  END IF;

  -- Clean up terminal boss-level entries for this user + boss
  DELETE FROM public.raid_queues
  WHERE boss_id = p_boss_id
    AND user_id = v_uid
    AND raid_id IS NULL
    AND status IN ('left', 'cancelled', 'done');

  INSERT INTO public.raid_queues (boss_id, user_id, note, status)
  VALUES (p_boss_id, v_uid, COALESCE(p_note, 'Waiting for host'), 'queued')
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.join_boss_queue(uuid, text) TO authenticated;

--------------------------------------------------------------------------------
-- 4. Trigger: auto-assign boss-level entries when a raid is created
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_boss_queue_on_raid_create()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.raid_boss_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Auto-assign waiting boss-level entries to the new raid.
  -- VIP first, then by earliest join time, up to raid capacity.
  WITH candidates AS (
    SELECT id,
           ROW_NUMBER() OVER (ORDER BY is_vip DESC, joined_at ASC) AS rn
    FROM public.raid_queues
    WHERE boss_id = NEW.raid_boss_id
      AND raid_id IS NULL
      AND status = 'queued'
      AND user_id <> NEW.host_user_id
    ORDER BY is_vip DESC, joined_at ASC
    LIMIT NEW.capacity
    FOR UPDATE
  )
  UPDATE public.raid_queues q
  SET raid_id    = NEW.id,
      status     = 'invited',
      invited_at = now(),
      position   = c.rn
  FROM candidates c
  WHERE q.id = c.id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_assign_boss_queue
  AFTER INSERT ON public.raids
  FOR EACH ROW
  EXECUTE FUNCTION public.assign_boss_queue_on_raid_create();

--------------------------------------------------------------------------------
-- 5. Update leave_queue_and_promote to handle boss-level entries (NULL raid_id)
--------------------------------------------------------------------------------
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

  IF v_row.status = 'left' THEN
    RETURN v_row;
  END IF;

  IF v_row.status = 'done' THEN
    RAISE EXCEPTION 'Cannot leave a completed queue entry'
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

--------------------------------------------------------------------------------
-- 6. Update boss_queue_stats to include boss-level entries in queue_length
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.boss_queue_stats AS
SELECT
  rb.id,
  rb.name,
  rb.tier,
  rb.cp,
  rb.image_url,
  rb.types,
  rb.pokemon_id,
  COALESCE((
    SELECT COUNT(*)::int
    FROM public.raids r
    WHERE r.raid_boss_id = rb.id
      AND r.status NOT IN ('completed', 'cancelled')
  ), 0) AS active_hosts,
  COALESCE((
    SELECT COUNT(*)::int
    FROM public.raid_queues q
    LEFT JOIN public.raids r ON r.id = q.raid_id
    WHERE q.status IN ('queued', 'invited')
      AND (
        -- Raid-level entries: boss matched via raids table
        (r.raid_boss_id = rb.id AND r.status NOT IN ('completed', 'cancelled'))
        OR
        -- Boss-level entries: directly linked by boss_id, no raid assigned
        (q.boss_id = rb.id AND q.raid_id IS NULL)
      )
  ), 0) AS queue_length
FROM public.raid_bosses rb
WHERE rb.is_visible = true
  AND (rb.available_from IS NULL OR rb.available_from <= now())
  AND (rb.available_until IS NULL OR rb.available_until > now());

GRANT SELECT ON public.boss_queue_stats TO anon, authenticated;
