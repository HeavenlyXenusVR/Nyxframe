-- Postgres connection helper (pgmoon-backed), auto-reconnecting.
--
-- One Pg instance is ONE physical connection. Callers that run inside copas
-- coroutines must not share an instance between concurrent coroutines --
-- db.lua's pool hands each query its own idle instance -- but a busy flag
-- below still serializes access as a backstop, so a misuse queues instead
-- of interleaving two queries' bytes on one socket.
local pgmoon = require("pgmoon")
local copas_ok, copas = pcall(require, "copas")
local unpack = table.unpack or unpack

local Pg = {}
Pg.__index = Pg

-- Upper bound on a single query's network wait. Without one, a copas-wrapped
-- socket waits forever, so a wedged connection would hold its pool slot
-- (and every caller queued behind it) indefinitely. Generous on purpose:
-- this guards against a dead peer, not a slow-but-working query.
local QUERY_TIMEOUT_MS = (tonumber(os.getenv("PG_QUERY_TIMEOUT_SECONDS")) or 60) * 1000
local BUSY_WAIT_TIMEOUT_SECONDS = 15

local function in_coroutine()
  return copas_ok and coroutine.isyieldable ~= nil and coroutine.isyieldable()
end

-- opts.on_connect(conn), if given, runs on every fresh pgmoon connection
-- (including auto-reconnects) -- the place for per-app type deserializers.
function Pg.new(opts)
  local self = setmetatable({}, Pg)
  self.opts = {
    host = opts.host or "127.0.0.1",
    port = tonumber(opts.port or 5432),
    user = opts.user,
    password = opts.password,
    database = opts.database,
  }
  self.on_connect = opts.on_connect
  self.conn = nil
  self.conn_wrapped = false
  self.busy = false
  self.last_used = 0
  return self
end

-- Closes the socket (best-effort: on a dead socket the terminate message
-- failing is expected) so a dropped connection frees its fd and Postgres
-- backend instead of lingering until the server notices.
function Pg:close()
  local conn = self.conn
  self.conn = nil
  if conn then pcall(function() conn:disconnect() end) end
end

function Pg:ensure()
  local yieldable = in_coroutine()
  if self.conn and self.conn.sock then
    if yieldable and not self.conn_wrapped then
      -- Opened outside the event loop (a startup query before copas.loop()),
      -- so it is a plain blocking socket. Reconnect once through copas now
      -- that we are in a coroutine.
      self:close()
    else
      return true
    end
  end
  local conn = pgmoon.new(self.opts)
  -- pgmoon's "luasocket" transport is a plain blocking LuaSocket TCP object:
  -- every query would stall the whole single-threaded copas loop (every
  -- other request, static file and WebSocket) for its full round trip.
  -- copas.wrap() gives the raw socket cooperative send/receive/connect/
  -- settimeout/close methods with the names pgmoon's luasocket proxy already
  -- forwards to, so swapping it in before connect() is a drop-in change.
  -- Outside a coroutine (startup) copas can't yield, so stay blocking there.
  if yieldable and conn.sock and conn.sock.sock then
    conn.sock.sock = copas.wrap(conn.sock.sock)
    self.conn_wrapped = true
  else
    self.conn_wrapped = false
  end
  local ok, err = conn:connect()
  if not ok then
    pcall(function() conn:disconnect() end)
    return nil, "postgres connect failed: " .. tostring(err)
  end
  pcall(conn.settimeout, conn, QUERY_TIMEOUT_MS)
  -- Discord snowflake IDs (guild/user/channel/role) live in BIGINT columns and routinely
  -- exceed 2^53, the largest integer a Lua double can represent exactly. pgmoon's default
  -- OID 20 (int8) deserializer runs every bigint value through tonumber(), which silently
  -- corrupts them, e.g. 1304564041863266347 comes back as 1.3045640418633e+18. Force bigint
  -- columns to come back as the raw wire-format string instead, which preserves full
  -- precision; safe to hand straight back into another bigint column or WHERE clause since
  -- Postgres implicitly casts untyped string literals to the target numeric type.
  conn:set_type_deserializer(20, "string")
  if self.on_connect then self.on_connect(conn) end
  self.conn = conn
  return true
end

-- pgmoon's receive_message() returns `nil, "receive_message: failed to get
-- type: " .. err` when the socket read itself fails (peer closed, idle-
-- killed, reset) but does NOT clear self.sock on that path, so the
-- connection looks alive forever unless we drop it here. A genuine Postgres
-- error always comes back as "SEVERITY: message" instead, so matching the
-- internal tag never mistakes a real SQL error for a dead socket.
local function is_dead_connection_error(err)
  return type(err) == "string" and err:find("^receive_message: failed to get type:") ~= nil
end

local function is_timeout_error(err)
  return type(err) == "string" and err:find("timeout", 1, true) ~= nil
end

local function wait_until_idle(self)
  if not self.busy then return true end
  if not in_coroutine() then return true end -- nothing else can be running
  local waited = 0
  while self.busy do
    copas.pause(0.01)
    waited = waited + 0.01
    if waited >= BUSY_WAIT_TIMEOUT_SECONDS then return false end
  end
  return true
end

local function run_query(self, sql, args, n)
  local ok, err = self:ensure()
  if not ok then return nil, err end

  if n > 0 then
    local escaped = {}
    for i = 1, n do
      local v = args[i]
      escaped[i] = (v == nil) and "NULL" or self.conn:escape_literal(v)
    end
    sql = sql:format(unpack(escaped, 1, n))
  end

  local res, err2 = self.conn:query(sql)
  if res ~= nil then return res end

  -- A nil result with the socket still live is a real Postgres error (bad
  -- SQL, constraint violation): hand it back and keep the connection.
  -- Reconnecting on those used to open (and leak) a fresh backend per error.
  if self.conn.sock and not is_dead_connection_error(err2) and not is_timeout_error(err2) then
    return nil, err2
  end
  self:close()
  -- A timed-out query may still have run server-side, so never re-send it.
  if is_timeout_error(err2) then return nil, err2 end
  -- The connection had died while idle; the query never reached Postgres.
  local ok2 = self:ensure()
  if not ok2 then return nil, err2 end
  res, err2 = self.conn:query(sql)
  if res == nil and (not self.conn.sock or is_dead_connection_error(err2) or is_timeout_error(err2)) then
    self:close()
  end
  return res, err2
end

-- query(sql, ...) -> rows, err. Params are escaped via pgmoon's built-in escaping.
function Pg:query(sql, ...)
  local n = select("#", ...)
  local args = { ... }
  if not wait_until_idle(self) then
    return nil, "postgres connection busy (timed out waiting)"
  end
  self.busy = true
  local success, res, err = pcall(run_query, self, sql, args, n)
  self.busy = false
  self.last_used = os.time()
  if not success then
    -- An error thrown mid-protocol leaves the wire state unknown.
    self:close()
    error(res, 0)
  end
  return res, err
end

return Pg
