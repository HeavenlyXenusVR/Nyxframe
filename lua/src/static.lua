-- Serves the built React SPA directly from the Lua backend so that
-- gallery.xenusanimations.studio is a fully working site on its own, not
-- just a JSON API -- mirrors SwarmPanel's src/static.lua pattern (see
-- SwarmPanel-strictly-Lua rewrite), adapted for a Vite-built SPA with
-- content-hashed asset filenames (SwarmPanel's static assets are two fixed
-- hand-written files, so it doesn't need the wildcard route below).
--
-- static/react/index.html is Vite's own build output with base:
-- "/static/react/" -- its asset paths are already root-relative
-- (/static/react/assets/...), so serving it unmodified at this backend's
-- own root is correct with zero rewriting, unlike the GitHub Pages shell
-- (index.html at repo root) which needs the extra /Image-Gallery/ prefix
-- injected by scripts/write-root-shell.mjs for that separate deployment.
local httpd = require("httpd")
local pages_og = require("pages_og")

local M = {}

local CONTENT_TYPES = {
  js = "application/javascript; charset=utf-8",
  css = "text/css; charset=utf-8",
  png = "image/png",
  ico = "image/vnd.microsoft.icon",
  webmanifest = "application/manifest+json",
  json = "application/json",
  map = "application/json",
  html = "text/html; charset=utf-8",
}

local function ext_of(filename)
  return filename:match("%.([%w]+)$")
end

local function read_file(relpath)
  local f = io.open(relpath, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local EXACT_ASSETS = {
  { path = "/favicon.ico", file = "../static/react/favicon.ico" },
  { path = "/service-worker.js", file = "../static/react/service-worker.js" },
  { path = "/static/react/favicon.ico", file = "../static/react/favicon.ico" },
  { path = "/static/react/apple-touch-icon.png", file = "../static/react/apple-touch-icon.png" },
  { path = "/static/react/manifest.webmanifest", file = "../static/react/manifest.webmanifest" },
  { path = "/static/react/pwa-192.png", file = "../static/react/pwa-192.png" },
  { path = "/static/react/pwa-512.png", file = "../static/react/pwa-512.png" },
  { path = "/static/react/service-worker.js", file = "../static/react/service-worker.js" },
}

-- Content-hashed build files never change under a given name, so they are
-- kept in memory after the first read (bounded, in case many builds'
-- worth of names get requested over a long uptime) and sent with a
-- year-long immutable cache header -- the browser never re-requests them.
-- Everything else (index.html, the service worker, icons) keeps a short or
-- no-cache policy so a new deploy is picked up right away: a stale
-- index.html pointing at chunk names the new build deleted is exactly how
-- lazy-loaded pages break after a deploy.
local HASHED_CACHE_LIMIT = 64
local hashed_cache = {}
local hashed_cache_count = 0

local function is_hashed_asset(relpath)
  return relpath:find("/static/react/assets/", 1, true) ~= nil
    and relpath:match("%-[%w_%-]+%.%w+$") ~= nil
end

local function cache_control_for(relpath)
  if is_hashed_asset(relpath) then return "public, max-age=31536000, immutable" end
  local name = relpath:match("([^/]+)$") or ""
  if name == "index.html" or name == "service-worker.js" then return "no-cache" end
  return "public, max-age=300"
end

local function serve_file(relpath)
  local hashed = is_hashed_asset(relpath)
  local data = hashed and hashed_cache[relpath] or nil
  if not data then
    data = read_file(relpath)
    if not data then return 404, "Not found", { ["Content-Type"] = "text/plain" } end
    if hashed and not relpath:match("%.map$") then
      if hashed_cache_count >= HASHED_CACHE_LIMIT then
        hashed_cache = {}
        hashed_cache_count = 0
      end
      hashed_cache[relpath] = data
      hashed_cache_count = hashed_cache_count + 1
    end
  end
  local content_type = CONTENT_TYPES[ext_of(relpath)] or "application/octet-stream"
  return 200, data, {
    ["Content-Type"] = content_type,
    ["Cache-Control"] = cache_control_for(relpath),
  }
end

function M.register()
  for _, asset in ipairs(EXACT_ASSETS) do
    httpd.route("GET", asset.path, function() return serve_file(asset.file) end)
  end

  -- Content-hashed build output (index-XXXXXXXX.js/.css, plus .map files
  -- when sourcemaps are enabled) -- filenames change per build, so a single
  -- parametric route beats hardcoding today's hashes.
  httpd.route("GET", "/static/react/assets/:file", function(req)
    local file = req.params.file or ""
    -- Build output is flat (no subdirectories); refuse anything that could
    -- walk out of the assets directory.
    if file == "" or file:find("..", 1, true) or file:find("/", 1, true) or file:find("\\", 1, true) then
      return 404, "Not found", { ["Content-Type"] = "text/plain" }
    end
    return serve_file("../static/react/assets/" .. file)
  end)
end

-- Mirrors routes.lua's own request_origin() (not exported/shared -- it's
-- a one-line computation, not worth adding a cross-module dependency for).
local function request_origin(headers)
  headers = headers or {}
  local proto = (headers["x-forwarded-proto"] or "http"):match("^[^,%s]+") or "http"
  local host = (headers["x-forwarded-host"] or headers["host"] or "localhost"):match("^[^,%s]+") or "localhost"
  return proto .. "://" .. host
end

-- SPA fallback: any GET that isn't an API route and isn't a known static
-- asset above falls through to httpd's "no route matched" path, which
-- calls this. Serves the same index.html for "/", "/media/123",
-- "/users/alice", etc. -- client-side react-router then takes over,
-- exactly like the GitHub Pages 404.html trick this backend previously
-- relied on, except here it's a real 200 instead of a 404-that-looks-fine.
--
-- Exception: a known link-unfurling crawler hitting /media/:id gets a
-- real Open Graph preview page instead (see pages_og.lua) -- crawlers
-- never execute the SPA's JS, so without this every shared link preview
-- was just the generic app-shell title/icon, not the actual post.
function M.fallback(method, path, headers)
  if method ~= "GET" then return nil end
  if path:match("^/api/") then return nil end
  local media_id = path:match("^/media/(%d+)$")
  if media_id and pages_og.is_crawler(headers and headers["user-agent"]) then
    local preview = pages_og.render_media_preview(request_origin(headers), media_id)
    if preview then
      return 200, preview, { ["Content-Type"] = "text/html; charset=utf-8" }
    end
  end
  return serve_file("../static/react/index.html")
end

return M
