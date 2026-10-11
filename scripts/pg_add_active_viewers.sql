-- Adds media_active_viewers, backing the "N people viewing this now"
-- indicator (lua/src/routes.lua's M.media_viewing_heartbeat). One row per
-- (media_id, viewer_key) ever seen -- same viewer_key convention as
-- media_views ("user:<id>" logged in, "ip:<address>" anonymous) -- upserted
-- on every heartbeat so this stays bounded per viewer-per-post rather than
-- growing per heartbeat tick. "Active" is a read-time filter
-- (last_seen_at within the last ~25s), not a separate status column, so a
-- viewer who closes the tab without a clean disconnect just ages out on
-- the next read instead of needing an explicit "leaving" signal.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS media_active_viewers (
  media_id BIGINT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  viewer_key TEXT NOT NULL,
  last_seen_at TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (media_id, viewer_key)
);

CREATE INDEX IF NOT EXISTS idx_active_viewers_media_seen ON media_active_viewers(media_id, last_seen_at);
