-- Original source attribution for uploads.
--
-- Posts imported from elsewhere (booru posts, artist pages, wallpaper
-- sites) had nowhere to record where they came from, so credit lived only
-- in a description if the uploader happened to write it there. This adds a
-- first-class column the API and the UI both understand.
--
-- Plain text, not a constrained type: the scheme/shape check lives in
-- routes.lua (normalize_source_url) so a bad value is a 400 with a readable
-- message rather than a Postgres constraint error, and so existing rows are
-- never retro-invalidated by a later tightening of the rule.
ALTER TABLE media_items ADD COLUMN IF NOT EXISTS source_url text;

COMMENT ON COLUMN media_items.source_url IS
  'Canonical URL the media was obtained from (http/https). NULL when unknown or original work.';
