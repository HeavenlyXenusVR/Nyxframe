-- Adds telemetry_events, the durable store backing lua/src/telemetry.lua's
-- M.record()/M.job_result() and the GET /api/admin/telemetry admin panel.
--
-- Deliberately NOT written per-request/per-like/per-segment -- see
-- telemetry.lua's header comment on write-volume design. Rows only get
-- inserted for: completed uploads, auth attempts, background-job runs that
-- failed or did something notable, and client-reported media-load/playback
-- diagnostics (already deduped client-side). A background pruner
-- (telemetry.lua's M.start_pruner, primary-worker only) deletes rows older
-- than GALLERY_TELEMETRY_RETENTION_DAYS (default 14) every 6h.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS telemetry_events (
  id BIGSERIAL PRIMARY KEY,
  event_type TEXT NOT NULL,   -- 'job' | 'upload' | 'auth' | 'media_load' | 'media_playback'
  subject TEXT,               -- job name / media_id / route, meaning depends on event_type
  outcome TEXT,               -- 'success' | 'error' | free-form outcome string
  duration_ms INTEGER,
  meta JSONB,
  created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_telemetry_events_type_time ON telemetry_events(event_type, created_at);
