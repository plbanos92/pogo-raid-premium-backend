-- Fix host_cancel_raid auth resolution.
-- The first version used current_setting('request.jwt.claim.sub', true), which can be brittle in RPC paths.
-- Use auth.uid() like the rest of the backend and return false cleanly when unauthenticated.

CREATE OR REPLACE FUNCTION public.host_cancel_raid(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid := auth.uid();
  v_raid        public.raids%ROWTYPE;
  v_new_raid_id uuid;
  v_entry       record;
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
