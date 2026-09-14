-- In-depth backend telemetry: in-process request latency/error counters,
-- background-job last-run status, cheap high-frequency action counters, and
-- durable event rows (Postgres `telemetry_events`, see
-- scripts/pg_add_telemetry.sql) for uploads, auth, and client-reported
-- media-load/playback diagnostics. Surfaced at GET /api/admin/telemetry
-- (routes.lua) and the /admin dashboard's Telemetry panel (pages_admin.lua).
--
-- WRITE-VOLUME DESIGN: this deliberately does NOT insert a database row per
-- request/like/comment/HLS-segment -- on a public gallery that would just
-- be a second, slower access log competing with real traffic for the same
-- DB pool this app's own requests depend on (see db.lua's header comment on
-- why a single shared connection was already a bottleneck once). Anything
-- that fires on every request (M.record_request, M.count) is in-memory
-- only. M.record()/M.job_result() -- the only paths that touch Postgres --
-- are called only for real operations: completed uploads, auth attempts,
-- background-job runs that did something or failed, and already
-- client-deduped media diagnostics beacons.
--
-- Not a top-level `require("telemetry")` local in routes.lua (that file's
-- main chunk is already at LuaJIT's 200-local ceiling) -- see routes.lua's
-- `M.telemetry = require("telemetry")` assignment, a field on the
-- already-declared M table rather than a new local, same workaround already
-- documented there for range_io/transcode.

local socket = require("socket")
local db = require("db")
local cjson = require("cjson.safe")

local M = {}

local enabled = true
local retention_days = 14

function M.init(settings)
  enabled = settings.telemetry_enabled ~= false
  retention_days = math.max(1, tonumber(settings.telemetry_retention_days) or 14)
end

function M.now()
  return socket.gettime()
end

function M.ms_since(t0)
  return math.floor((socket.gettime() - t0) * 1000 + 0.5)
end

-- Durable event row. Fire-and-forget: pcall'd so a telemetry failure (e.g. a
-- momentary pool exhaustion) never raises into the caller's own request/job
-- -- same convention as routes.lua's write_audit_log.
function M.record(event_type, subject, outcome, duration_ms, meta)
  if not enabled then return end
  local ok, err = pcall(
    db.execute,
    "INSERT INTO telemetry_events (event_type, subject, outcome, duration_ms, meta) VALUES (%s, %s, %s, %s, %s)",
    tostring(event_type):sub(1, 40),
    subject ~= nil and tostring(subject):sub(1, 200) or nil,
    outcome ~= nil and tostring(outcome):sub(1, 40) or nil,
    duration_ms ~= nil and math.floor(duration_ms) or nil,
    meta ~= nil and cjson.encode(meta) or nil
  )
  if not ok then
    print("[nyxframe] telemetry.record failed: " .. tostring(err))
  end
end

function M.recent_events(event_type, limit)
  limit = math.max(1, math.min(tonumber(limit) or 50, 200))
  if event_type and event_type ~= "" then
    return db.fetchall(
      "SELECT id, event_type, subject, outcome, duration_ms, meta, created_at FROM telemetry_events WHERE event_type=%s ORDER BY id DESC LIMIT %s",
      event_type, tostring(limit)
    )
  end
  return db.fetchall(
    "SELECT id, event_type, subject, outcome, duration_ms, meta, created_at FROM telemetry_events ORDER BY id DESC LIMIT %s",
    tostring(limit)
  )
end

-- ---------------------------------------------------------------------------
-- In-memory request stats, bucketed by the ROUTE PATTERN httpd.lua matched
-- (e.g. "GET /api/media/:media_id"), never the raw path -- a raw path would
-- put every distinct media_id/job_id in its own bucket forever. Reset
-- hourly so the admin panel reflects recent traffic, not a since-boot
-- average that dilutes toward meaninglessness on a long-running process.
-- ---------------------------------------------------------------------------

local request_stats = {}
local request_stats_since = os.time()
local REQUEST_STATS_RESET_SECONDS = 3600
local REQUEST_STATS_SAMPLE_CAP = 50

local function maybe_reset_request_stats()
  if os.time() - request_stats_since > REQUEST_STATS_RESET_SECONDS then
    request_stats = {}
    request_stats_since = os.time()
  end
end

function M.record_request(method, route_pattern, status, duration_ms)
  if not enabled then return end
  maybe_reset_request_stats()
  local key = tostring(method or "?") .. " " .. tostring(route_pattern or "?")
  local bucket = request_stats[key]
  if not bucket then
    bucket = { count = 0, error_count = 0, total_ms = 0, max_ms = 0, samples = {} }
    request_stats[key] = bucket
  end
  bucket.count = bucket.count + 1
  bucket.total_ms = bucket.total_ms + duration_ms
  if duration_ms > bucket.max_ms then bucket.max_ms = duration_ms end
  if status and status >= 400 then bucket.error_count = bucket.error_count + 1 end
  -- Small fixed-size reservoir (most recent N) approximates p95 for an
  -- admin panel without retaining every sample for the process lifetime.
  bucket.samples[#bucket.samples + 1] = duration_ms
  if #bucket.samples > REQUEST_STATS_SAMPLE_CAP then table.remove(bucket.samples, 1) end
end

local function percentile(samples, p)
  if #samples == 0 then return 0 end
  local sorted = {}
  for i, v in ipairs(samples) do sorted[i] = v end
  table.sort(sorted)
  local idx = math.max(1, math.ceil(p * #sorted))
  return math.floor(sorted[idx])
end

function M.request_stats_snapshot()
  local out = {}
  for key, bucket in pairs(request_stats) do
    out[#out + 1] = {
      route = key,
      count = bucket.count,
      error_count = bucket.error_count,
      avg_ms = bucket.count > 0 and math.floor(bucket.total_ms / bucket.count) or 0,
      p95_ms = percentile(bucket.samples, 0.95),
      max_ms = math.floor(bucket.max_ms),
    }
  end
  table.sort(out, function(a, b) return a.count > b.count end)
  return out, request_stats_since
end

-- ---------------------------------------------------------------------------
-- Background-job last-run snapshots (always in-memory) + cheap high-
-- frequency action counters (always in-memory, never persisted).
-- ---------------------------------------------------------------------------

local job_last_run = {}

-- Always updates the in-memory "last run" snapshot the admin panel reads.
-- Only persists a durable row when the run failed OR the caller passed a
-- non-nil `summary` -- summary presence is the caller's own signal that
-- this particular run did something worth keeping, mirroring the
-- print-only-when-something-happened convention the warmer/cleanup/reaper
-- loops already use for their stdout logging. Keeps a job that wakes every
-- 10-30s but usually has nothing to do from writing a DB row every wakeup.
function M.job_result(name, ok, duration_ms, summary)
  job_last_run[name] = {
    ok = ok and true or false,
    duration_ms = duration_ms,
    summary = summary,
    at = os.time(),
  }
  if not ok or summary ~= nil then
    M.record("job", name, ok and "success" or "error", duration_ms, summary)
  end
end

function M.job_snapshot()
  return job_last_run
end

local counters = {}

function M.count(name, n)
  counters[name] = (counters[name] or 0) + (n or 1)
end

function M.counters_snapshot()
  return counters
end

function M.snapshot()
  local stats, since = M.request_stats_snapshot()
  return {
    request_stats = stats,
    request_stats_since = since,
    jobs = job_last_run,
    counters = counters,
  }
end

-- ---------------------------------------------------------------------------
-- Retention pruner -- copas background coroutine, same pcall-per-iteration/
-- long-sleep shape as digest.lua's digest_loop. Caller (main.lua) is
-- responsible for only starting this on the primary worker, same gate as
-- every other background loop in this app.
-- ---------------------------------------------------------------------------

function M.start_pruner()
  if not enabled then return end
  local copas = require("copas")
  local retain_clause = "interval '" .. tostring(math.floor(retention_days)) .. " days'"
  copas.addthread(function()
    while true do
      local ok, err = pcall(db.execute, "DELETE FROM telemetry_events WHERE created_at < now() - " .. retain_clause)
      if not ok then
        print("[nyxframe] telemetry pruner error: " .. tostring(err))
      end
      copas.pause(21600)
    end
  end)
end

return M
