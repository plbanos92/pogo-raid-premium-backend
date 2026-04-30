-- Migration: 20260506200000_relay_trigger_fires_on_raid_id_change.sql
--
-- Bug: trg_notify_boss_queue_change fires on AFTER INSERT OR UPDATE OF status OR DELETE.
-- Recent migrations introduced raid_queues mutations that change raid_id without
-- changing status:
--
--   1. 20260506180000_check_host_inactivity_boss_pool_fallback.sql — Step "ELSE"
--      converts dropped joiners to boss-pool entries (raid_id=NULL, status stays 'queued').
--   2. 20260506190000_expire_kicks_to_boss_pool.sql — Step D kicks expired joiners
--      out to the boss pool (raid_id=NULL, status stays 'queued').
--
-- Without this fix, those mutations do NOT bump raid_bosses.updated_at, so
-- Channel 5 (boss-meta-changes) never fires for non-owner observers — most
-- importantly the HOST watching their lobby card. The host only sees the
-- joiner disappear at their next poll tick (up to 10 s in HOT, 60 s in IDLE).
--
-- Adding `raid_id` to the trigger's UPDATE OF clause ensures any move to or
-- from the boss pool, or between raids, fires the relay and reaches every
-- subscribed client instantly.

DROP TRIGGER IF EXISTS trg_notify_boss_queue_change ON public.raid_queues;
CREATE TRIGGER trg_notify_boss_queue_change
  AFTER INSERT OR UPDATE OF status, raid_id OR DELETE ON public.raid_queues
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_boss_queue_change();
