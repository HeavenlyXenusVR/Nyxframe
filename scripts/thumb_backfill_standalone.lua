-- Standalone, out-of-process video-thumbnail backfill. NOT run by any
-- systemd unit -- invoke manually: from lua/, with GALLERY_UPLOADS_DIR
-- exported to match the live service's real value (check
-- `systemctl --user show nyxframe-lua@8790.service -p Environment` --
-- it's /mnt/fastssd/image-gallery-uploads on this box, NOT the lua/../uploads
-- checked into the repo, which is a stale leftover directory with none of
-- the real files):
--   ionice -c3 nice -n19 luajit ../scripts/thumb_backfill_standalone.lua
--
-- Why this exists instead of routes.lua's M.start_thumb_backfill_sweep (now
-- permanently disabled via GALLERY_ENABLE_THUMB_BACKFILL_SWEEP=false in
-- .env): that in-process version ran inside the live nyxframe-lua@8790
-- worker and caused two real outages on 2026-10-11. Its path through
-- resolve_media_bytes -> media_files.legacy_upload_path reads the WHOLE
-- original file (tens to hundreds of MB on this gallery) into a Lua string
-- with plain blocking io.open/read, then (for the DB-blob fallback branch)
-- writes it back out again -- none of it copas-aware or niced. Under this
-- box's disk-queue contention (14 bot containers + 3 Lavalink JVMs + this
-- worker's own traffic all hitting the same physical disk at once) that
-- blocked on the kernel's blk_mq_get_tag for 9+ minutes straight (confirmed
-- via /proc/<pid>/wchan), and because it's the SAME OS process that answers
-- HTTP requests, the entire worker went unresponsive -- curl timed out
-- against both the worker directly and the public proxy.
--
-- This version avoids the read-into-memory step entirely for the common
-- case: when media_files.legacy_upload_path resolves (true for every
-- current row -- media_items.media_file_id is NULL across the board, so
-- the media_files/bytea path below is dead code for this dataset, kept only
-- as a fallback in case that ever changes), ffmpeg reads the source file
-- directly off disk -- no Lua string copy, no redundant write. Also run as
-- a genuinely separate OS process under `ionice -c3` (idle class, so the
-- kernel only services its disk requests when nothing else wants the
-- device) with a sleep between items, so even a slow render can't starve
-- the live workers' own I/O.
package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local db = require("db")
local media_files = require("media_files")

local uploads_dir = os.getenv("GALLERY_UPLOADS_DIR")
if not uploads_dir or uploads_dir == "" then
  print("[thumb_backfill] GALLERY_UPLOADS_DIR is not set -- refusing to guess, see header comment")
  os.exit(1)
end
uploads_dir = uploads_dir:gsub("/+$", "")

db.init({
  db_host = os.getenv("GALLERY_DB_HOST") or "127.0.0.1",
  db_port = tonumber(os.getenv("GALLERY_DB_PORT")) or 5432,
  db_user = os.getenv("GALLERY_DB_USER"),
  db_password = os.getenv("GALLERY_DB_PASSWORD"),
  db_name = os.getenv("GALLERY_DB_SCHEMA"),
  db_pool_size = 1,
})

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function thumb_cache_path(media_id, width)
  local shard = string.format("%02x", media_id % 256)
  return uploads_dir .. "/_thumb_cache/" .. shard .. "/" .. media_id .. "_" .. width .. ".webp", shard
end

local rows, err = db.fetchall([[
  SELECT id, storage_path FROM media_items WHERE media_kind = 'video' AND deleted_at IS NULL ORDER BY id
]])
if err then
  print("[thumb_backfill] could not list videos: " .. tostring(err))
  os.exit(1)
end

local function render_from_path(src_path, tmp_dst, width)
  local cmd = string.format(
    "ionice -c3 nice -n19 ffmpeg -y -hide_banner -loglevel error -ss 0.35 -i %s " ..
    "-frames:v 1 -vf %s -c:v libwebp -compression_level 5 -quality 84 -f webp %s </dev/null >/dev/null 2>&1",
    shell_quote(src_path),
    shell_quote(string.format("scale='min(%d,iw)':-2:flags=lanczos", width)),
    shell_quote(tmp_dst)
  )
  os.execute(cmd)
  local out = io.open(tmp_dst, "rb")
  if out then out:close() return true end
  return false
end

local width = 520
local rendered, already_cached, no_source, failed = 0, 0, 0, 0

for _, row in ipairs(rows) do
  local media_id = db.toint(row.id, row.id)
  local dst, shard = thumb_cache_path(media_id, width)

  local existing = io.open(dst, "rb")
  if existing then
    existing:close()
    already_cached = already_cached + 1
  else
    os.execute("mkdir -p " .. shell_quote(uploads_dir .. "/_thumb_cache/" .. shard))
    local tmp_dst = dst .. ".tmp.webp"
    local ok = false

    local legacy_path = media_files.legacy_upload_path(uploads_dir, row.storage_path)
    if legacy_path then
      ok = render_from_path(legacy_path, tmp_dst, width)
    else
      -- Dead for this dataset today (every row's media_file_id is NULL --
      -- see header comment) but kept as a fallback: an actual DB-blob row
      -- still needs its content written to a scratch file first, same as
      -- before.
      local file = media_files.get_media_file(media_id)
      if file and file.content and #file.content > 0 then
        local tmp_src = os.tmpname()
        local f = io.open(tmp_src, "wb")
        f:write(file.content)
        f:close()
        file.content = nil
        ok = render_from_path(tmp_src, tmp_dst, width)
        os.remove(tmp_src)
      end
    end

    if ok then
      os.execute("mv -f " .. shell_quote(tmp_dst) .. " " .. shell_quote(dst))
      rendered = rendered + 1
      print(string.format("[thumb_backfill] media %d: rendered (%d done so far)", media_id, rendered))
    else
      os.execute("rm -f " .. shell_quote(tmp_dst))
      if legacy_path then
        failed = failed + 1
        print(string.format("[thumb_backfill] media %d: ffmpeg produced no output", media_id))
      else
        no_source = no_source + 1
        print(string.format("[thumb_backfill] media %d: no on-disk file and no blob content, skipping (leave to lazy path)", media_id))
      end
    end
    os.execute("sleep 3") -- deliberate gap between items, see header comment
  end
end

print(string.format(
  "[thumb_backfill] done -- rendered %d, already cached %d, no source %d, failed %d, total %d",
  rendered, already_cached, no_source, failed, #rows
))
