-- Adds media_items.expires_at, backing ephemeral/"stories"-style posts
-- (lua/src/routes.lua's upload-time `expires_in_hours` option + the
-- expired-post filter every browsing query applies). NULL means "never
-- expires" -- the existing, unchanged behavior for every post today --
-- so this is purely additive.
--
-- Partial index (WHERE expires_at IS NOT NULL) rather than a plain one:
-- almost every row will have a NULL expires_at indefinitely (ephemeral
-- posts are the exception, not the rule), and Postgres partial indexes
-- skip NULL rows entirely, keeping this tiny regardless of library size.
--
-- Idempotent: safe to re-run.

ALTER TABLE media_items ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP;

CREATE INDEX IF NOT EXISTS idx_media_items_expires_at
  ON media_items(expires_at)
  WHERE expires_at IS NOT NULL;
