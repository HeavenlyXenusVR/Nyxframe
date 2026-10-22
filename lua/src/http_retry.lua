-- Thin retry wrapper around copas.http.request for this backend's outbound
-- calls (Gemini vision analysis, Discord webhooks, YouTube thumbnail
-- fetches) -- all of them currently give up on the first timeout/connection
-- failure and either degrade silently (AI analysis) or just log and move on
-- (Discord webhooks), even though a second attempt a moment later often
-- succeeds. Only retries the "never got a response at all" case (connect
-- refused, DNS failure, read/write timeout -- copas_http.request's own `ok`
-- comes back false for all of these); a real HTTP response, even a 4xx/5xx
-- one, is NOT retried here, since the far end already answered and trying
-- again would just reproduce the same answer.
--
-- opts_factory must build and return a BRAND NEW request table (and the
-- response chunks table its sink writes into) on every call, not reuse one
-- across attempts: ltn12.source.string(payload) is single-use, so handing
-- the same already-consumed source to a second copas_http.request would
-- send an empty body.

local copas_http = require("copas.http")
local copas = require("copas")

local M = {}

-- Returns (ok, status, raw_body, attempts_used) -- same (ok, status) shape
-- copas_http.request itself returns, plus the concatenated response body
-- and how many attempts it took, for callers that want to log retries.
function M.request(opts_factory, max_attempts, backoff_seconds)
  max_attempts = max_attempts or 3
  backoff_seconds = backoff_seconds or { 1, 3 }
  local ok, status, raw
  for attempt = 1, max_attempts do
    local opts, chunks = opts_factory()
    ok, status = copas_http.request(opts)
    raw = table.concat(chunks)
    if ok then return ok, status, raw, attempt end
    if attempt < max_attempts then
      copas.sleep(backoff_seconds[attempt] or backoff_seconds[#backoff_seconds] or 2)
    end
  end
  return ok, status, raw, max_attempts
end

-- Convenience for the common "GET a URL, I just want the bytes" case (e.g.
-- fetching a YouTube thumbnail) -- same retry semantics as M.request.
function M.get(url, timeout_seconds, max_attempts, backoff_seconds)
  local ltn12 = require("ltn12")
  return M.request(function()
    local chunks = {}
    return { url = url, method = "GET", sink = ltn12.sink.table(chunks), timeout = timeout_seconds }, chunks
  end, max_attempts, backoff_seconds)
end

return M
