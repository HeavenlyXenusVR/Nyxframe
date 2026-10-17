-- Adds media_watch_progress, backing resume/continue-watching for video
-- (lua/src/routes.lua's M.save_watch_progress/M.watch_progress). One row
-- per (user_id, media_id) -- upserted on every heartbeat from the player,
-- same bounded-growth convention as media_active_viewers, not one row per
-- tick. duration_seconds is recorded alongside position so a resume lookup
-- can tell "nearly finished, don't bother resuming" from "25% in" without
-- a second round trip to probe the file itself.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS media_watch_progress (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_id BIGINT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  position_seconds REAL NOT NULL,
  duration_seconds REAL,
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, media_id)
);

CREATE INDEX IF NOT EXISTS idx_watch_progress_user_updated ON media_watch_progress(user_id, updated_at DESC);
