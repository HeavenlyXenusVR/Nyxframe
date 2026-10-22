-- YouTube source-link thumbnail override. When an uploader's "original
-- source" link is a YouTube video, that video's own thumbnail is a better
-- default than whatever this backend would otherwise derive (a frame grab
-- for a video upload, or the uploaded image itself) -- it's the thumbnail
-- the uploader already chose/was shown on YouTube. Detection only; the
-- actual fetch+render happens in routes.lua's M.serve_media_thumb, which
-- already owns the cache/placeholder/concurrency-slot machinery every other
-- thumbnail source goes through.

local http_retry = require("http_retry")

local M = {}

-- Returns the 11-ish-char video id for any of the common URL shapes, or nil
-- if `url` isn't recognizably a YouTube link at all. Deliberately permissive
-- on id length/characters (YouTube ids are base64url-ish but not a fixed
-- length is guaranteed to stay true forever) -- anything %w/_/- between the
-- expected delimiters is accepted and just fails harmlessly later if it
-- turns out not to be a real video.
function M.extract_video_id(url)
  if type(url) ~= "string" or url == "" then return nil end
  local host = url:match("^https?://([^/?#]+)")
  if not host then return nil end
  host = host:lower():gsub("^www%.", ""):gsub("^m%.", "")

  if host == "youtu.be" then
    return url:match("^https?://[^/]+/([%w_%-]+)")
  end

  if host == "youtube.com" or host == "music.youtube.com" then
    local v = url:match("[?&]v=([%w_%-]+)")
    if v then return v end
    local shorts = url:match("/shorts/([%w_%-]+)")
    if shorts then return shorts end
    local embed = url:match("/embed/([%w_%-]+)")
    if embed then return embed end
  end

  return nil
end

-- maxresdefault doesn't exist for every video (older/low-res uploads) --
-- YouTube's img.youtube.com serves a 120x90 gray placeholder WITH an HTTP
-- 200 for the missing case rather than a 404, so a status check alone can't
-- tell real-thumbnail-missing apart from actually-missing. That placeholder
-- is always exactly 120x90; hqdefault.jpg (480x360) always exists for any
-- video that exists at all, so a minimum byte-size floor well below a real
-- 480x360 JPEG but well above the placeholder's few hundred bytes is enough
-- to distinguish them without needing to decode the image just to check its
-- dimensions.
local MIN_PLAUSIBLE_THUMBNAIL_BYTES = 2000

-- Returns (bytes, nil) on success, (nil, message) otherwise. Tries
-- maxresdefault first, falls back to hqdefault -- never fails the upload
-- itself (callers must pcall-wrap, same contract as every other best-effort
-- background job in routes.lua).
function M.fetch_best_thumbnail_bytes(video_id, timeout_seconds)
  for _, variant in ipairs({ "maxresdefault", "hqdefault" }) do
    local url = string.format("https://img.youtube.com/vi/%s/%s.jpg", video_id, variant)
    local ok, status, raw = http_retry.get(url, timeout_seconds or 10)
    if ok and status == 200 and raw and #raw >= MIN_PLAUSIBLE_THUMBNAIL_BYTES then
      return raw, nil
    end
  end
  return nil, "No usable YouTube thumbnail found for video " .. tostring(video_id)
end

return M
