ALTER TABLE public.app_config
  ADD COLUMN IF NOT EXISTS realtime_slots int NOT NULL DEFAULT 150;
COMMENT ON COLUMN public.app_config.realtime_slots IS
  'Soft capacity ceiling for concurrent realtime WebSocket sessions for free-tier users. '
  'VIP users are always granted a slot when realtime_slots > 0; if the pool is at capacity, '
  'the oldest free-tier session is evicted to make room for a VIP. If no free-tier session '
  'exists, the VIP is still granted (pool may temporarily exceed the ceiling for VIPs). '
  'Set to 0 to disable realtime globally, including VIPs.';
UPDATE public.app_config
SET vip_features = vip_features || '[{"icon":"zap","text":"Real-time queue updates"}]'::jsonb,
    updated_at = now()
WHERE id = 1
  AND NOT (vip_features @> '[{"icon":"zap","text":"Real-time queue updates"}]'::jsonb);
