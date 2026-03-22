-- Hardening migration: constraints, indexes, updated_at triggers, and RLS coverage.

-- 1) Data integrity constraints
ALTER TABLE IF EXISTS "raids"
  ADD CONSTRAINT raids_capacity_positive_chk CHECK ("capacity" > 0) NOT VALID;

ALTER TABLE IF EXISTS "raids"
  ADD CONSTRAINT raids_time_window_chk CHECK ("end_time" IS NULL OR "end_time" >= "start_time") NOT VALID;

ALTER TABLE IF EXISTS "raids"
  ADD CONSTRAINT raids_lat_range_chk CHECK ("lat" IS NULL OR ("lat" >= -90 AND "lat" <= 90)) NOT VALID;

ALTER TABLE IF EXISTS "raids"
  ADD CONSTRAINT raids_lng_range_chk CHECK ("lng" IS NULL OR ("lng" >= -180 AND "lng" <= 180)) NOT VALID;

ALTER TABLE IF EXISTS "raid_queues"
  ADD CONSTRAINT raid_queues_position_positive_chk CHECK ("position" IS NULL OR "position" >= 1) NOT VALID;

ALTER TABLE IF EXISTS "raid_queues"
  ADD CONSTRAINT raid_queues_status_chk CHECK ("status" IN ('queued', 'invited', 'confirmed', 'declined', 'cancelled', 'left')) NOT VALID;

ALTER TABLE IF EXISTS "subscriptions"
  ADD CONSTRAINT subscriptions_status_chk CHECK ("status" IN ('active', 'trialing', 'past_due', 'cancelled', 'expired')) NOT VALID;

-- Validate constraints after definition.
ALTER TABLE IF EXISTS "raids" VALIDATE CONSTRAINT raids_capacity_positive_chk;
ALTER TABLE IF EXISTS "raids" VALIDATE CONSTRAINT raids_time_window_chk;
ALTER TABLE IF EXISTS "raids" VALIDATE CONSTRAINT raids_lat_range_chk;
ALTER TABLE IF EXISTS "raids" VALIDATE CONSTRAINT raids_lng_range_chk;
ALTER TABLE IF EXISTS "raid_queues" VALIDATE CONSTRAINT raid_queues_position_positive_chk;
ALTER TABLE IF EXISTS "raid_queues" VALIDATE CONSTRAINT raid_queues_status_chk;
ALTER TABLE IF EXISTS "subscriptions" VALIDATE CONSTRAINT subscriptions_status_chk;

-- 2) Query efficiency indexes
CREATE INDEX IF NOT EXISTS idx_raid_queues_raid_status_joined
ON "raid_queues" ("raid_id", "status", "joined_at");

CREATE INDEX IF NOT EXISTS idx_subscriptions_active_vip_user
ON "subscriptions" ("user_id")
WHERE "is_vip" = true AND "status" = 'active';

-- 3) Keep updated_at accurate
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_user_profiles_set_updated_at ON "user_profiles";
CREATE TRIGGER trg_user_profiles_set_updated_at
BEFORE UPDATE ON "user_profiles"
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_raids_set_updated_at ON "raids";
CREATE TRIGGER trg_raids_set_updated_at
BEFORE UPDATE ON "raids"
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_raid_queues_set_updated_at ON "raid_queues";
CREATE TRIGGER trg_raid_queues_set_updated_at
BEFORE UPDATE ON "raid_queues"
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_subscriptions_set_updated_at ON "subscriptions";
CREATE TRIGGER trg_subscriptions_set_updated_at
BEFORE UPDATE ON "subscriptions"
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- 4) RLS completion for remaining tables
ALTER TABLE IF EXISTS "raid_confirmations" ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users view own confirmations' AND tablename = 'raid_confirmations'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users view own confirmations" ON "raid_confirmations"
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM raid_queues rq
          WHERE rq.id = raid_confirmations.raid_queue_id
            AND rq.user_id = auth.uid()
        )
      );
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Hosts view confirmations for own raids' AND tablename = 'raid_confirmations'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Hosts view confirmations for own raids" ON "raid_confirmations"
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM raid_queues rq
          JOIN raids r ON r.id = rq.raid_id
          WHERE rq.id = raid_confirmations.raid_queue_id
            AND r.host_user_id = auth.uid()
        )
      );
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Hosts insert confirmations for own raids' AND tablename = 'raid_confirmations'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Hosts insert confirmations for own raids" ON "raid_confirmations"
      FOR INSERT
      TO authenticated
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM raid_queues rq
          JOIN raids r ON r.id = rq.raid_id
          WHERE rq.id = raid_confirmations.raid_queue_id
            AND r.host_user_id = auth.uid()
        )
      );
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE IF EXISTS "activity_logs" ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users view own activity logs' AND tablename = 'activity_logs'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users view own activity logs" ON "activity_logs"
      FOR SELECT
      TO authenticated
      USING (user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users insert own activity logs' AND tablename = 'activity_logs'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users insert own activity logs" ON "activity_logs"
      FOR INSERT
      TO authenticated
      WITH CHECK (user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;
