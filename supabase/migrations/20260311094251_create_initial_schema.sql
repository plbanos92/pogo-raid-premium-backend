-- pokemon-go-raid-queue-schema.sql

-- Enable pgcrypto for gen_random_uuid
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- user_profiles table
CREATE TABLE IF NOT EXISTS "user_profiles" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "auth_id" uuid UNIQUE,
  "display_name" text,
  "avatar_url" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_profiles_auth_id ON "user_profiles" ("auth_id");

-- raid_bosses table
CREATE TABLE IF NOT EXISTS "raid_bosses" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "name" text NOT NULL,
  "tier" int,
  "pokemon_id" int,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

-- raids table
CREATE TABLE IF NOT EXISTS "raids" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "host_user_id" uuid NOT NULL,
  "raid_boss_id" uuid REFERENCES "raid_bosses" ("id") ON DELETE SET NULL,
  "location_name" text,
  "lat" double precision,
  "lng" double precision,
  "start_time" timestamptz NOT NULL,
  "end_time" timestamptz,
  "capacity" int DEFAULT 20,
  "is_active" boolean NOT NULL DEFAULT true,
  "notes" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_raids_host_user_id ON "raids" ("host_user_id");
CREATE INDEX IF NOT EXISTS idx_raids_start_time ON "raids" ("start_time");
CREATE INDEX IF NOT EXISTS idx_raids_raid_boss_id ON "raids" ("raid_boss_id");

-- raid_queues table
CREATE TABLE IF NOT EXISTS "raid_queues" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "raid_id" uuid NOT NULL REFERENCES "raids" ("id") ON DELETE CASCADE,
  "user_id" uuid NOT NULL,
  "joined_at" timestamptz NOT NULL DEFAULT now(),
  "status" text NOT NULL DEFAULT 'queued',
  "is_vip" boolean NOT NULL DEFAULT false,
  "note" text,
  "position" int,
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_raid_queues_raid_user ON "raid_queues" ("raid_id", "user_id");
CREATE INDEX IF NOT EXISTS idx_raid_queues_raid_id ON "raid_queues" ("raid_id");
CREATE INDEX IF NOT EXISTS idx_raid_queues_user_id ON "raid_queues" ("user_id");
CREATE INDEX IF NOT EXISTS idx_raid_queues_status ON "raid_queues" ("status");

-- subscriptions table
CREATE TABLE IF NOT EXISTS "subscriptions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid NOT NULL,
  "provider" text,
  "provider_subscription_id" text,
  "status" text NOT NULL DEFAULT 'active',
  "is_vip" boolean NOT NULL DEFAULT false,
  "starts_at" timestamptz,
  "ends_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON "subscriptions" ("user_id");
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON "subscriptions" ("status");

-- raid_confirmations table
CREATE TABLE IF NOT EXISTS "raid_confirmations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "raid_queue_id" uuid NOT NULL REFERENCES "raid_queues" ("id") ON DELETE CASCADE,
  "confirmed_by" uuid,
  "confirmed_at" timestamptz NOT NULL DEFAULT now()
);

-- activity_logs table
CREATE TABLE IF NOT EXISTS "activity_logs" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid,
  "action" text NOT NULL,
  "meta" jsonb,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_activity_logs_user_id ON "activity_logs" ("user_id");
CREATE INDEX IF NOT EXISTS idx_activity_logs_action ON "activity_logs" ("action");

-- Trigger function to set is_vip on raid_queues insert based on active subscription
CREATE OR REPLACE FUNCTION set_queue_vip_flag()
RETURNS TRIGGER AS $$
BEGIN
  IF (NEW.is_vip IS NULL OR NEW.is_vip = false) THEN
    NEW.is_vip := EXISTS (
      SELECT 1 FROM subscriptions s
      WHERE s.user_id = NEW.user_id
      AND s.is_vip = true
      AND s.status = 'active'
      AND (s.ends_at IS NULL OR s.ends_at > now())
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_set_queue_vip_flag
BEFORE INSERT ON "raid_queues"
FOR EACH ROW
EXECUTE FUNCTION set_queue_vip_flag();

-- Recommended: RLS policies (enable RLS and create policies)
-- Note: run these after reviewing and adjusting to your auth setup.

ALTER TABLE IF EXISTS "user_profiles" ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users can manage own profile' AND tablename = 'user_profiles'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users can manage own profile" ON "user_profiles"
      FOR ALL
      TO authenticated
      USING (auth.uid() = auth_id)
      WITH CHECK (auth.uid() = auth_id);
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE IF EXISTS "raids" ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Public read raids' AND tablename = 'raids'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Public read raids" ON "raids"
      FOR SELECT
      TO authenticated
      USING (is_active = true);
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Hosts manage own raids' AND tablename = 'raids'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Hosts manage own raids" ON "raids"
      FOR ALL
      TO authenticated
      USING (host_user_id = auth.uid())
      WITH CHECK (host_user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE IF EXISTS "raid_queues" ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users manage own queue' AND tablename = 'raid_queues'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users manage own queue" ON "raid_queues"
      FOR ALL
      TO authenticated
      USING (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Hosts view queues for their raids' AND tablename = 'raid_queues'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Hosts view queues for their raids" ON "raid_queues"
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM raids WHERE raids.id = raid_queues.raid_id AND raids.host_user_id = auth.uid()
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
    WHERE policyname = 'Hosts update queue status' AND tablename = 'raid_queues'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Hosts update queue status" ON "raid_queues"
      FOR UPDATE
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM raids WHERE raids.id = raid_queues.raid_id AND raids.host_user_id = auth.uid()
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM raids WHERE raids.id = raid_queues.raid_id AND raids.host_user_id = auth.uid()
        )
      );
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE IF EXISTS "subscriptions" ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users manage own subscriptions' AND tablename = 'subscriptions'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users manage own subscriptions" ON "subscriptions"
      FOR ALL
      TO authenticated
      USING (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;
