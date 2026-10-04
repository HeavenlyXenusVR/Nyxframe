-- Postgres access layer built on the vendored lib/swarmlua/pg.lua.
--
-- Unlike SwarmPanel's db.lua, this backend only ever talks to one database
-- (image_gallery), so there's no per-dbname pool table -- just a flat pool
-- of Pg instances, all against that one database.
--
-- Previously this held exactly one Pg instance and every query in the app
-- serialized behind it. It is now a swarmlua/pgpool.lua pool: each query
-- borrows an idle connection for its own round trip, a copas semaphore
-- queues callers FIFO when all db_pool_size connections are busy (no
-- polling, and nobody waits behind one specific slow query while another
-- connection is free), connections open lazily and extras close after a
-- minute idle, and a failed SQL statement no longer throws away (and
-- leaks) its connection.
--
-- NUMERIC precision note: unlike SwarmPanel's image_gallery access (which
-- kept the columns as NUMERIC(20,0) and patched pgmoon's oid-1700
-- deserializer), THIS schema had every such id/counter column converted to
-- BIGINT during the Phase 1 schema fixups (see
-- ../../scripts/pg_numeric_to_bigint.sql) specifically so it wouldn't need
-- that patch and so FKs could reference the (already-bigint) primary keys.
-- pg.lua's existing oid-20 (int8) string-deserializer, used as-is, already
-- covers full precision for every wide-integer column in this schema. Do not
-- add a NUMERIC/oid-1700 patch here unless a future migration reintroduces
-- NUMERIC id columns.
local Pool = require("swarmlua.pgpool")

local M = {}
local pool = nil
local cfg = nil

-- All app tables use "timestamp without time zone" (oid 1114) columns.
-- pgmoon has no built-in deserializer for it, so it falls through to
-- "string" and comes back verbatim in Postgres's text-output format
-- ("2026-07-26 18:48:07.797921" -- space separator, no zone). Python's
-- asyncpg driver returns a naive datetime for the same column, and
-- app/routers/_shared.py's _jsonable() renders it via .isoformat(), which
-- uses a "T" separator and (for a naive datetime) no zone suffix. Convert
-- to match so both backends emit byte-identical timestamps for the same
-- row. Runs on every fresh connection, reconnects included.
local function on_connect(conn)
  conn:set_type_deserializer(1114, "timestamp", function(_, val)
    return (val:gsub(" ", "T", 1))
  end)
end

function M.init(settings)
  cfg = settings
  pool = Pool.new({
    host = cfg.db_host,
    port = cfg.db_port,
    user = cfg.db_user,
    password = cfg.db_password,
    database = cfg.db_name,
    size = cfg.db_pool_size or 1,
    on_connect = on_connect,
  })
end

-- Runs `sql` (with %s-style placeholders, pgmoon-escaped) against the db.
-- Returns rows (array of column->value tables) or nil, err.
function M.query(sql, ...)
  local rows, err = pool:query(sql, ...)
  -- pg.lua's own query() can legitimately return `nil, nil` for a
  -- connection-level failure it has no formatted message for (e.g. a
  -- socket reset mid-query after this connection sat unused through a long
  -- upload's remux/AI/hash work) -- without this fallback that surfaced as
  -- a bare "Could not save media: nil" with no way to tell a real DB error
  -- from a dropped connection.
  if rows == nil then return nil, err or "database connection error (no detail available)" end
  if rows == true then return {} end -- DDL/DML with no result set
  return rows
end

function M.fetchall(sql, ...)
  local rows, err = M.query(sql, ...)
  return rows or {}, err
end

function M.fetchone(sql, ...)
  local rows, err = M.query(sql, ...)
  if not rows or not rows[1] then return nil, err end
  return rows[1], nil
end

function M.execute(sql, ...)
  local rows, err = M.query(sql, ...)
  if rows == nil then return nil, err end
  return true
end

-- Coerces a value that may have come back as a Lua string (bigint columns
-- are forced to string by pg.lua to preserve snowflake-scale precision) into
-- a Lua number. Safe to call on values that are already numbers.
function M.toint(v, default)
  if v == nil then return default end
  if type(v) == "number" then return math.floor(v) end
  local n = tonumber(v)
  if n == nil then return default end
  return math.floor(n)
end

function M.tobool(v)
  if type(v) == "boolean" then return v end
  if v == nil then return false end
  if v == "t" or v == "true" or v == "1" or v == 1 then return true end
  return false
end

-- pg.lua returns SQL NULL as Lua's cjson.null sentinel in some pgmoon
-- versions (or plain nil); normalize both to nil so `value or default`
-- fallback patterns (which cjson.null defeats, since it's a non-nil,
-- non-false userdata/table) are actually safe throughout this codebase.
local cjson = require("cjson.safe")
function M.norm(v)
  if v == nil or v == cjson.null then return nil end
  return v
end

function M.ping()
  local row, err = M.fetchone("SELECT now() AS now")
  if not row then return false, err end
  return true, row.now
end

return M
