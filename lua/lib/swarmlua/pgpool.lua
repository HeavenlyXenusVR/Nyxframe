-- A small pool of swarmlua.pg connections to ONE database, for a copas
-- server.
--
-- Each query borrows an idle connection for exactly its own round trip, so
-- up to `size` queries run in parallel and nobody queues behind a slow one
-- on a shared socket. A copas semaphore with `size` permits does the
-- queueing: a coroutine that holds a permit is guaranteed an idle
-- connection, and waiters are woken in FIFO order the moment one frees up
-- (no polling). Connections open lazily and extras close after IDLE_SECONDS
-- unused, so a quiet process holds one connection per database.
--
-- Transactions: BEGIN/COMMIT must run on one connection. pool:transaction(fn)
-- pins a connection to the calling coroutine for the duration of fn, and
-- every pool:query() made by that coroutine meanwhile (including from helper
-- functions that know nothing about the transaction) uses it.
local Pg = require("swarmlua.pg")
local copas_ok, copas = pcall(require, "copas")
local semaphore_ok, semaphore = false, nil
if copas_ok then semaphore_ok, semaphore = pcall(require, "copas.semaphore") end

local Pool = {}
Pool.__index = Pool

local IDLE_SECONDS = 60
local ACQUIRE_TIMEOUT_SECONDS = tonumber(os.getenv("PG_POOL_ACQUIRE_TIMEOUT_SECONDS")) or 15
local MAIN_THREAD = {}

local function in_coroutine()
  return copas_ok and coroutine.isyieldable ~= nil and coroutine.isyieldable()
end

local function current_thread()
  return coroutine.running() or MAIN_THREAD
end

-- opts: Pg.new options plus `size` (max connections).
function Pool.new(opts)
  local self = setmetatable({}, Pool)
  self.opts = opts
  self.size = math.max(1, math.floor(tonumber(opts.size) or 1))
  self.conns = {}
  self.pinned = setmetatable({}, { __mode = "k" }) -- thread -> Pg
  if semaphore_ok then
    self.sem = semaphore.new(self.size, self.size, ACQUIRE_TIMEOUT_SECONDS)
  end
  return self
end

local function close_idle_extras(self)
  local now = os.time()
  for i = #self.conns, 2, -1 do
    local c = self.conns[i]
    if not c.busy and not c.checked_out and now - c.last_used >= IDLE_SECONDS then
      c:close()
      table.remove(self.conns, i)
    end
  end
end

local function checkout(self)
  local permit = false
  if self.sem and in_coroutine() then
    local ok, err = self.sem:take(1)
    if not ok then
      return nil, "database busy: no free connection after " .. ACQUIRE_TIMEOUT_SECONDS .. "s (" .. tostring(err) .. ")"
    end
    permit = true
  end
  close_idle_extras(self)
  local conn
  for _, c in ipairs(self.conns) do
    if not c.checked_out then conn = c break end
  end
  if not conn then
    if #self.conns < self.size then
      conn = Pg.new(self.opts)
      self.conns[#self.conns + 1] = conn
    else
      -- Only reachable outside the event loop (startup), where nothing
      -- else can be using a connection concurrently anyway.
      conn = self.conns[1]
    end
  end
  conn.checked_out = true
  return conn, nil, permit
end

local function checkin(self, conn, permit)
  conn.checked_out = false
  conn.last_used = os.time()
  if permit then self.sem:give(1) end
end

function Pool:query(sql, ...)
  local pinned = self.pinned[current_thread()]
  if pinned then return pinned:query(sql, ...) end
  local conn, err, permit = checkout(self)
  if not conn then return nil, err end
  local ok, res, qerr = pcall(conn.query, conn, sql, ...)
  checkin(self, conn, permit)
  if not ok then error(res, 0) end
  return res, qerr
end

-- Runs fn() between BEGIN and COMMIT on one pinned connection; ROLLBACK and
-- re-raise if fn (or COMMIT) errors. Returns fn's results.
function Pool:transaction(fn)
  local thread = current_thread()
  if self.pinned[thread] then return fn() end -- already inside one: join it
  local conn, err, permit = checkout(self)
  if not conn then error(err, 0) end
  self.pinned[thread] = conn
  local results = { pcall(function()
    local ok, berr = conn:query("BEGIN")
    if not ok then error(berr or "BEGIN failed", 0) end
    local out = { fn() }
    local cok, cerr = conn:query("COMMIT")
    if not cok then error(cerr or "COMMIT failed", 0) end
    return unpack(out)
  end) }
  if not results[1] then pcall(conn.query, conn, "ROLLBACK") end
  self.pinned[thread] = nil
  checkin(self, conn, permit)
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, table.maxn(results))
end

return Pool
