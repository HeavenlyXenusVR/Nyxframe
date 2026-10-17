-- Adds per-saved-search and per-follow notification muting
-- (lua/src/routes.lua's notify_matching_saved_searches/notify_discord_upload
-- callers check these before creating a notification). Both default false
-- so every existing saved search/follow keeps notifying exactly as it does
-- today -- purely additive, opt-in silence rather than opt-in noise.
--
-- Idempotent: safe to re-run.

ALTER TABLE saved_searches ADD COLUMN IF NOT EXISTS notifications_muted BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE user_follows ADD COLUMN IF NOT EXISTS notifications_muted BOOLEAN NOT NULL DEFAULT false;
