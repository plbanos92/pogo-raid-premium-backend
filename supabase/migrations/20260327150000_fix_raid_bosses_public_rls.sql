-- Ensure raid_bosses remains readable to anon/authenticated clients.
-- This fixes queue/raid embeds returning null boss records when RLS is
-- enabled on public.raid_bosses without a corresponding read policy.

ALTER TABLE public.raid_bosses ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'raid_bosses'
      AND policyname = 'Public read raid bosses'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY "Public read raid bosses" ON public.raid_bosses
      FOR SELECT
      TO anon, authenticated
      USING (true)
    $policy$;
  END IF;
END;
$$ LANGUAGE plpgsql;

GRANT SELECT ON TABLE public.raid_bosses TO anon, authenticated;