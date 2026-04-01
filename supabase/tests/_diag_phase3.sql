SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

-- Check raids for boss 302
SELECT id, status, is_active FROM public.raids WHERE raid_boss_id = '00000000-0000-0000-0000-000000000302';

-- Probe join_boss_queue behavior
DO $$
DECLARE v_result public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_result FROM public.join_boss_queue('00000000-0000-0000-0000-000000000302');
  RAISE NOTICE 'join_boss_queue SUCCEEDED: status=%, raid_id=%', v_result.status, v_result.raid_id;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'join_boss_queue RAISED: SQLSTATE=%, MSG=%', SQLSTATE, SQLERRM;
END;
$$ LANGUAGE plpgsql;
