-- Adds user_year_recap_cache, backing the year-in-review recap
-- (lua/src/routes.lua's M.year_recap). The underlying query aggregates a
-- full year of uploads/likes/views, which is only worth paying for once
-- per user per year rather than on every page view -- same
-- "cache the expensive aggregate, not the request" idea as
-- creator_stats_for's own caching, just durable instead of in-memory since
-- a recap for a past year never changes once computed.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS user_year_recap_cache (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  year INT NOT NULL,
  payload TEXT NOT NULL,
  computed_at TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, year)
);
