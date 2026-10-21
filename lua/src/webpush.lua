-- Web Push notifications: RFC 8030 (delivery) + RFC 8291 (message
-- encryption) + RFC 8292 (VAPID). A leaf module -- no `require("routes")`
-- anywhere in this file, deliberately: routes.lua requires THIS module (to
-- trigger a push on follow/like/comment/DM/new-upload events), so this file
-- staying dependency-free in that direction avoids the same load-order
-- cycle video_extras.lua's own header comment works around for a similar
-- two-module relationship. `M.uploads_dir` is set directly by main.lua
-- after require (same plain-field wiring main.lua already does for
-- httpd.trusted_proxy_cidrs etc.), not read back through routes.lua.
--
-- Crypto is split across two tools, each used for what it's actually good
-- at -- NOT guessed, every primitive below was verified directly against
-- known-good references before this file was written:
--   - luaossl (openssl.pkey/digest/kdf/cipher): EC keygen, PEM export,
--     ECDSA signing, HKDF, AES-128-GCM. Confirmed correct via: HKDF output
--     cross-checked byte-for-byte against the `openssl kdf` CLI; the DER<->
--     raw ECDSA conversion below round-tripped (sign -> convert -> rebuild
--     DER -> verify) across 200 real signatures with random r/s to exercise
--     both the "leading zero byte needs stripping/adding" and "doesn't"
--     cases; and a full RFC 8291 encrypt-then-independently-decrypt interop
--     test (this file's sender side against a from-scratch receiver
--     implementation simulating what a real browser's push service does)
--     passed across 9 runs with fresh random keys/salts each time.
--   - the `openssl` CLI, shelled out to for exactly one step: P-256 ECDH
--     key agreement. This build of luaossl's Lua binding exposes EC key
--     generation/signing/verification but NOT key derivation -- `derive`,
--     `computeSecret`, `agree`, `dh`, `ecdh`, `computeKey` all come back
--     nil on a real EC key object, checked exhaustively, not assumed from
--     docs. Same "no good Lua binding, shell out to a trusted CLI instead"
--     choice already made for ffmpeg elsewhere in this codebase. Needs
--     `openssl` reachable on this service's PATH (added to the shared
--     `servicePath` list in migration-services.nix, alongside the
--     already-fixed ffmpeg entry).
--
-- Blocking: the ECDH shell-out blocks copas' event loop for its duration,
-- same tradeoff media_files.lua's ffmpeg calls already accept -- but this
-- is a tiny, fast computation (single-digit milliseconds, nothing like a
-- multi-second transcode), and push sends are a rare event, not a
-- per-request hot path. The actual HTTP delivery to the push service runs
-- through copas.http inside a detached copas.addthread (see
-- M.send_to_subscription_async), the same fire-and-forget pattern
-- discord_webhook.lua already uses, so a slow or down push service can
-- never block or fail whatever action (follow/like/comment/...) triggered
-- the notification.

local pkey = require("openssl.pkey")
local digest = require("openssl.digest")
local kdf = require("openssl.kdf")
local cipher = require("openssl.cipher")
local sodium = require("luasodium")
local cjson = require("cjson.safe")

local M = {}

-- Set by main.lua right after require -- see this file's header comment.
M.uploads_dir = nil
M.vapid_subject = nil

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function openssl_bin()
  return os.getenv("GALLERY_OPENSSL_BIN") or "openssl"
end

-- Same base64url convention (no padding) auth.lua already uses for this
-- backend's own session tokens -- reused here rather than a second
-- implementation, and it's what both VAPID and the Push API spec require.
local B64URL = sodium.sodium_base64_VARIANT_URLSAFE_NO_PADDING
local function b64url_encode(bin) return sodium.sodium_bin2base64(bin, B64URL) end
local function b64url_decode(text)
  local ok, bin = pcall(sodium.sodium_base642bin, text, B64URL)
  if not ok then return nil end
  return bin
end
M.b64url_encode = b64url_encode
M.b64url_decode = b64url_decode

-- The fixed, spec-defined 26-byte SubjectPublicKeyInfo DER prefix for ANY
-- P-256/prime256v1 EC public key -- confirmed by decoding a real openssl-
-- generated public key and diffing: the prefix never varies, only the
-- trailing 65-byte uncompressed point does. Lets a raw point (what the
-- Push API and our own ephemeral keys both deal in) be turned back into
-- something `openssl ec -pubin` can load, with no bignum/ASN.1 encoding
-- logic of our own needed for the part that actually varies per key.
local EC_P256_DER_PREFIX = string.char(
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
  0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
)

-- Generates a fresh P-256 keypair. Returns (priv_pem, raw_pub_65bytes), or
-- (nil, nil, error) on failure.
local function generate_ec_keypair()
  local key = pkey.new{ type = "EC", curve = "prime256v1" }
  local priv_pem = key:toPEM("private")
  local tmp_priv = os.tmpname()
  local fpriv = io.open(tmp_priv, "wb")
  if not fpriv then return nil, nil, "could not write temp key file" end
  fpriv:write(priv_pem)
  fpriv:close()
  local tmp_der = os.tmpname()
  os.execute(string.format(
    "%s ec -in %s -pubout -outform DER -out %s 2>/dev/null",
    openssl_bin(), shell_quote(tmp_priv), shell_quote(tmp_der)
  ))
  local fder = io.open(tmp_der, "rb")
  local der = fder and fder:read("*a")
  if fder then fder:close() end
  os.remove(tmp_priv)
  os.remove(tmp_der)
  if not der or #der < 65 then return nil, nil, "EC public key export failed" end
  return priv_pem, der:sub(-65)
end
M.generate_ec_keypair = generate_ec_keypair

-- Raw 65-byte uncompressed point -> PEM public key, via the fixed prefix above.
local function raw_pub_to_pem(raw_pub)
  if #raw_pub ~= 65 or raw_pub:byte(1) ~= 0x04 then return nil end
  local der = EC_P256_DER_PREFIX .. raw_pub
  local tmp_der = os.tmpname()
  local f = io.open(tmp_der, "wb")
  if not f then return nil end
  f:write(der)
  f:close()
  local handle = io.popen(string.format(
    "%s ec -pubin -inform DER -in %s -pubout 2>/dev/null",
    openssl_bin(), shell_quote(tmp_der)
  ))
  local pem = handle and handle:read("*a")
  if handle then handle:close() end
  os.remove(tmp_der)
  if not pem or #pem == 0 then return nil end
  return pem
end

-- ECDH shared secret between our private key (PEM) and a peer's raw public
-- point. The one step luaossl's Lua binding doesn't expose -- see this
-- file's header comment.
local function ecdh_shared_secret(priv_pem, peer_raw_pub)
  local peer_pem = raw_pub_to_pem(peer_raw_pub)
  if not peer_pem then return nil, "invalid peer public key" end
  local tmp_priv, tmp_peer, tmp_out = os.tmpname(), os.tmpname(), os.tmpname()
  local f1 = io.open(tmp_priv, "wb")
  local f2 = io.open(tmp_peer, "wb")
  if not f1 or not f2 then
    if f1 then f1:close() end
    if f2 then f2:close() end
    return nil, "could not write temp key files"
  end
  f1:write(priv_pem); f1:close()
  f2:write(peer_pem); f2:close()
  local ok = os.execute(string.format(
    "%s pkeyutl -derive -inkey %s -peerkey %s -out %s 2>/dev/null",
    openssl_bin(), shell_quote(tmp_priv), shell_quote(tmp_peer), shell_quote(tmp_out)
  ))
  local f3 = io.open(tmp_out, "rb")
  local secret = f3 and f3:read("*a")
  if f3 then f3:close() end
  os.remove(tmp_priv)
  os.remove(tmp_peer)
  os.remove(tmp_out)
  if not ((ok == 0 or ok == true) and secret and #secret == 32) then
    return nil, "ECDH derive failed (is `openssl` on this service's PATH?)"
  end
  return secret
end

local function hkdf(key, salt, info, outlen)
  local ok, out = pcall(kdf.derive, { type = "HKDF", outlen = outlen, md = "sha256", key = key, salt = salt, info = info })
  if not ok then return nil, out end
  return out
end

-- DER ECDSA signature (SEQUENCE of two INTEGERs) -> raw r||s (64 bytes),
-- the format JWS ES256 requires. See this file's header comment for how
-- this was verified before shipping.
local function der_ecdsa_to_raw(der)
  if not der or #der < 8 or der:byte(1) ~= 0x30 then return nil end
  local pos = 3
  local function read_integer()
    if der:byte(pos) ~= 0x02 then return nil end
    local len = der:byte(pos + 1)
    if not len or pos + 1 + len > #der then return nil end
    local bytes = der:sub(pos + 2, pos + 1 + len)
    pos = pos + 2 + len
    if #bytes == 33 and bytes:byte(1) == 0x00 then bytes = bytes:sub(2) end
    if #bytes < 32 then bytes = string.rep("\0", 32 - #bytes) .. bytes end
    if #bytes ~= 32 then return nil end
    return bytes
  end
  local r = read_integer()
  if not r then return nil end
  local s = read_integer()
  if not s then return nil end
  return r .. s
end

-- ---------------------------------------------------------------------------
-- VAPID keys: generated once, then persisted to disk under uploads_dir
-- (a generated artifact, same convention as the transcode slot files/thumb
-- cache -- not a secret someone configures in .env). Deliberately never
-- auto-rotated: every already-stored push subscription is cryptographically
-- tied to the public key it was created with (the browser signs nothing
-- itself, but the push SERVICE validates our VAPID signature against the
-- key the subscription negotiated with), so silently regenerating this
-- would quietly break delivery to every existing subscriber.
-- ---------------------------------------------------------------------------

local vapid_cache = { priv_pem = nil, pub_raw = nil }

local function vapid_paths()
  local dir = M.uploads_dir .. "/_vapid"
  return dir, dir .. "/private.pem", dir .. "/public.raw"
end

local function load_or_create_vapid_keys()
  if vapid_cache.priv_pem and vapid_cache.pub_raw then
    return vapid_cache.priv_pem, vapid_cache.pub_raw
  end
  local dir, priv_path, pub_path = vapid_paths()
  local pf = io.open(priv_path, "rb")
  local qf = io.open(pub_path, "rb")
  if pf and qf then
    local priv_pem = pf:read("*a")
    local pub_raw = qf:read("*a")
    pf:close()
    qf:close()
    if priv_pem and #priv_pem > 0 and pub_raw and #pub_raw == 65 then
      vapid_cache.priv_pem, vapid_cache.pub_raw = priv_pem, pub_raw
      return priv_pem, pub_raw
    end
  else
    if pf then pf:close() end
    if qf then qf:close() end
  end
  local priv_pem, pub_raw, err = generate_ec_keypair()
  if not priv_pem then return nil, nil, err end
  os.execute("mkdir -p " .. shell_quote(dir))
  local out1 = io.open(priv_path, "wb")
  local out2 = io.open(pub_path, "wb")
  if not out1 or not out2 then
    if out1 then out1:close() end
    if out2 then out2:close() end
    return nil, nil, "could not persist VAPID keys to " .. dir
  end
  out1:write(priv_pem); out1:close()
  out2:write(pub_raw); out2:close()
  vapid_cache.priv_pem, vapid_cache.pub_raw = priv_pem, pub_raw
  return priv_pem, pub_raw
end

-- GET /api/push/vapid-public-key's payload: base64url raw point, exactly
-- the shape PushManager.subscribe({applicationServerKey}) expects.
function M.vapid_public_key_b64url()
  local _, pub_raw, err = load_or_create_vapid_keys()
  if not pub_raw then return nil, err end
  return b64url_encode(pub_raw)
end

local function vapid_jwt(audience_origin)
  local priv_pem, pub_raw, err = load_or_create_vapid_keys()
  if not priv_pem then return nil, nil, err end
  local header = b64url_encode(cjson.encode({ typ = "JWT", alg = "ES256" }))
  local payload = b64url_encode(cjson.encode({
    aud = audience_origin,
    exp = os.time() + 12 * 3600,
    sub = M.vapid_subject or "mailto:admin@localhost",
  }))
  local signing_input = header .. "." .. payload
  local ok, key = pcall(pkey.new, priv_pem)
  if not ok then return nil, nil, "bad VAPID private key" end
  local d = digest.new("sha256")
  d:update(signing_input)
  local sign_ok, der_sig = pcall(function() return key:sign(d) end)
  if not sign_ok then return nil, nil, "VAPID signing failed: " .. tostring(der_sig) end
  local raw_sig = der_ecdsa_to_raw(der_sig)
  if not raw_sig then return nil, nil, "VAPID signature conversion failed" end
  return signing_input .. "." .. b64url_encode(raw_sig), b64url_encode(pub_raw)
end

-- ---------------------------------------------------------------------------
-- Message encryption (RFC 8291) + delivery (RFC 8030)
-- ---------------------------------------------------------------------------

-- Encrypts `payload_json` (already-encoded JSON string) for one
-- subscription's keys. Returns the full aes128gcm wire body, or nil+error.
local function encrypt_payload(payload_json, subscriber_pub_raw, auth_secret)
  local as_priv_pem, as_pub_raw, err = generate_ec_keypair()
  if not as_priv_pem then return nil, err end
  local ecdh_secret, err2 = ecdh_shared_secret(as_priv_pem, subscriber_pub_raw)
  if not ecdh_secret then return nil, err2 end

  local key_info = "WebPush: info\0" .. subscriber_pub_raw .. as_pub_raw
  local ikm, err3 = hkdf(ecdh_secret, auth_secret, key_info, 32)
  if not ikm then return nil, err3 end

  local salt = sodium.randombytes_buf(16)
  local cek, err4 = hkdf(ikm, salt, "Content-Encoding: aes128gcm\0", 16)
  if not cek then return nil, err4 end
  local nonce, err5 = hkdf(ikm, salt, "Content-Encoding: nonce\0", 12)
  if not nonce then return nil, err5 end

  -- Single record: payload + a 0x02 delimiter byte (RFC 8188 "this is the
  -- last/only record"), no extra padding -- these payloads are small JSON
  -- blobs (title/body/url), nowhere near the 4096-byte record size picked
  -- below, so padding-for-traffic-analysis-resistance isn't worth the
  -- complexity of a real padding scheme for this deployment.
  local enc = cipher.new("aes-128-gcm")
  enc:encrypt(cek, nonce)
  local ok, ct = pcall(function() return enc:update(payload_json .. "\2") .. enc:final() end)
  if not ok then return nil, "encryption failed: " .. tostring(ct) end
  local tag = enc:getTag(16)

  local rs = 4096
  local rs_bytes = string.char(
    math.floor(rs / 16777216) % 256, math.floor(rs / 65536) % 256,
    math.floor(rs / 256) % 256, rs % 256
  )
  local header = salt .. rs_bytes .. string.char(#as_pub_raw) .. as_pub_raw
  return header .. ct .. tag
end

-- Sends one push message to one subscription, synchronously (the caller
-- -- M.send_to_subscription_async below -- is what actually detaches this
-- from the request path). `subscription` is {endpoint, p256dh, auth}
-- (base64url strings, exactly as stored from push_subscriptions).
-- `payload_table` is a plain Lua table, JSON-encoded here.
--
-- Returns (true, http_status) on a request that reached the push service
-- (even a non-2xx one -- the caller decides what e.g. 404/410 "gone,
-- delete this subscription" means), or (false, nil, error_message) if the
-- request never went out at all (encryption/signing failure, network
-- error).
function M.send_to_subscription(subscription, payload_table)
  local p256dh = b64url_decode(subscription.p256dh)
  local auth_secret = b64url_decode(subscription.auth)
  if not p256dh or #p256dh ~= 65 or not auth_secret or #auth_secret ~= 16 then
    return false, nil, "malformed subscription keys"
  end
  local payload_json = cjson.encode(payload_table)
  local body, err = encrypt_payload(payload_json, p256dh, auth_secret)
  if not body then return false, nil, err end

  local origin = subscription.endpoint:match("^(https?://[^/]+)")
  if not origin then return false, nil, "invalid endpoint URL" end
  local jwt, vapid_pub, err2 = vapid_jwt(origin)
  if not jwt then return false, nil, err2 end

  -- copas.http, not a blocking HTTP client -- same reasoning as
  -- discord_webhook.lua/ai_metadata.lua's identical choice.
  local copas_http = require("copas.http")
  local ltn12 = require("ltn12")
  local response_chunks = {}
  local ok, result, status = pcall(function()
    return copas_http.request({
      url = subscription.endpoint,
      method = "POST",
      headers = {
        ["Content-Type"] = "application/octet-stream",
        ["Content-Encoding"] = "aes128gcm",
        ["Content-Length"] = tostring(#body),
        ["TTL"] = "86400",
        ["Urgency"] = "normal",
        ["Authorization"] = string.format("vapid t=%s, k=%s", jwt, vapid_pub),
      },
      source = ltn12.source.string(body),
      sink = ltn12.sink.table(response_chunks),
    })
  end)
  if not ok then return false, nil, tostring(result) end
  return true, status
end

-- Fire-and-forget wrapper -- the actual thing callers (routes.lua, on
-- follow/like/comment/DM/new-upload) should use. Runs on its own copas
-- coroutine so a slow or unreachable push service can never block or fail
-- the request that triggered the notification; `on_result(ok, status,
-- err)` (optional) is called back on that same coroutine once the send
-- finishes, e.g. to delete a subscription that came back 404/410.
function M.send_to_subscription_async(subscription, payload_table, on_result)
  local function run()
    local ok, status, err = M.send_to_subscription(subscription, payload_table)
    if on_result then
      local callback_ok, callback_err = pcall(on_result, ok, status, err)
      if not callback_ok then
        print("[nyxframe] web push on_result callback failed: " .. tostring(callback_err))
      end
    end
    if not ok then
      print("[nyxframe] web push send failed: " .. tostring(err))
    end
  end
  local copas_ok, copas = pcall(require, "copas")
  if copas_ok and copas.addthread then
    copas.addthread(run)
  else
    run()
  end
end

return M
