-- Raise the per-post subcategory cap from 3 to 20.
--
-- MAX_MEDIA_SUBCATEGORIES in routes.lua is the cap the API enforces (it trims
-- anything beyond it), but this CHECK is what the INSERT actually hits: with
-- the old 1..3 bound the fourth subcategory failed as a raw Postgres
-- constraint error rather than anything the UI could explain.
ALTER TABLE media_item_subcategories DROP CONSTRAINT IF EXISTS chk_media_item_subcategories_position;
ALTER TABLE media_item_subcategories ADD CONSTRAINT chk_media_item_subcategories_position
  CHECK ("position" >= 1 AND "position" <= 20);
