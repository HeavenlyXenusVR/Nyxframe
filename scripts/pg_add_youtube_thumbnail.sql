-- Adds media_items.youtube_video_id, backing the YouTube source-link
-- thumbnail override (lua/src/routes.lua's finalize_upload detection +
-- M.serve_media_thumb's fetch/render branch): when an uploader's original
-- source link is a YouTube video, that video's id is captured here so the
-- thumbnail serve path can fetch+render YouTube's own thumbnail instead of
-- deriving one from the uploaded media itself.
--
-- Idempotent: safe to re-run.

ALTER TABLE media_items ADD COLUMN IF NOT EXISTS youtube_video_id TEXT;
